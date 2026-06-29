import logging
from datetime import datetime, timezone
from typing import Annotated

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    HTTPException,
    Query,
    status,
)
from sqlalchemy import and_, desc, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import SessionLocal, get_session
from app.dependencies import get_current_user
from app.models import Message, User
from app.schemas import (
    MessageCreate,
    MessageRead,
    MessagesMarkedReadResponse,
)
from app.translation import (
    DEEPSEEK_MODEL,
    TRANSLATION_PROVIDER_NAME,
    translate_message,
)
from app.websocket_manager import connection_manager


logger = logging.getLogger(__name__)


router = APIRouter(
    prefix="/messages",
    tags=["messages"],
)

SessionDependency = Annotated[
    AsyncSession,
    Depends(get_session),
]

CurrentUserDependency = Annotated[
    User,
    Depends(get_current_user),
]


async def publish_translation_update(
    message: Message,
) -> None:
    websocket_event = {
        "type": "message.translation.updated",
        "message": (
            MessageRead.model_validate(message)
            .model_dump(mode="json")
        ),
    }

    await connection_manager.send_to_user(
        user_id=message.sender_id,
        data=websocket_event,
    )

    await connection_manager.send_to_user(
        user_id=message.recipient_id,
        data=websocket_event,
    )


async def translate_and_publish_message(
    message_id: int,
) -> None:
    async with SessionLocal() as session:
        message = await session.get(
            Message,
            message_id,
        )

        if message is None:
            return

        if message.translation_status != "pending":
            return

        sender = await session.get(
            User,
            message.sender_id,
        )

        recipient = await session.get(
            User,
            message.recipient_id,
        )

        if sender is None or recipient is None:
            message.translation_status = "failed"
            message.translation_provider = (
                TRANSLATION_PROVIDER_NAME
            )
            message.translation_model = DEEPSEEK_MODEL

            await session.commit()
            await session.refresh(message)

            await publish_translation_update(message)
            return

        context_result = await session.scalars(
            select(Message)
            .where(
                Message.id < message.id,
                or_(
                    and_(
                        Message.sender_id == sender.id,
                        Message.recipient_id == recipient.id,
                    ),
                    and_(
                        Message.sender_id == recipient.id,
                        Message.recipient_id == sender.id,
                    ),
                ),
            )
            .order_by(
                desc(Message.created_at),
                desc(Message.id),
            )
            .limit(8)
        )

        previous_messages = list(context_result)
        previous_messages.reverse()

        user_names = {
            sender.id: sender.display_name,
            recipient.id: recipient.display_name,
        }

        context_messages = [
            (
                f"{user_names.get(previous_message.sender_id, 'User')}: "
                f"{previous_message.content}"
            )
            for previous_message in previous_messages
        ]

        try:
            translation_result = await translate_message(
                text=message.content,
                source_language=message.source_language,
                target_language=message.translated_language,
                context_messages=context_messages,
            )

        except Exception:
            logger.exception(
                "Translation failed for message ID %s",
                message.id,
            )

            message.translated_content = None
            message.translation_status = "failed"
            message.translation_provider = (
                TRANSLATION_PROVIDER_NAME
            )
            message.translation_model = DEEPSEEK_MODEL

        else:
            message.translated_content = (
                translation_result.translated_text
            )
            message.translation_status = "completed"
            message.translation_provider = (
                translation_result.provider
            )
            message.translation_model = (
                translation_result.model
            )

        await session.commit()
        await session.refresh(message)

        await publish_translation_update(message)


@router.post(
    "",
    response_model=MessageRead,
    status_code=status.HTTP_201_CREATED,
)
async def create_message(
    message_data: MessageCreate,
    background_tasks: BackgroundTasks,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> Message:
    recipient = await session.get(
        User,
        message_data.recipient_id,
    )

    if recipient is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Recipient not found",
        )

    if recipient.id == current_user.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You cannot send a message to yourself",
        )

    content = message_data.content.strip()

    if not content:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Message content cannot be blank",
        )

    message = Message(
        sender_id=current_user.id,
        recipient_id=recipient.id,
        content=content,
        source_language=current_user.preferred_language,
        translated_language=recipient.preferred_language,
        translated_content=None,
        translation_status="pending",
        translation_provider=None,
        translation_model=None,
    )

    session.add(message)
    await session.commit()
    await session.refresh(message)

    message_created_event = {
        "type": "message.created",
        "message": (
            MessageRead.model_validate(message)
            .model_dump(mode="json")
        ),
    }

    await connection_manager.send_to_user(
        user_id=recipient.id,
        data=message_created_event,
    )

    await connection_manager.send_to_user(
        user_id=current_user.id,
        data=message_created_event,
    )

    background_tasks.add_task(
        translate_and_publish_message,
        message.id,
    )

    return message


@router.get(
    "/conversation/{other_user_id}",
    response_model=list[MessageRead],
)
async def list_conversation(
    other_user_id: int,
    current_user: CurrentUserDependency,
    session: SessionDependency,
    limit: Annotated[
        int,
        Query(ge=1, le=100),
    ] = 50,
) -> list[Message]:
    other_user = await session.get(
        User,
        other_user_id,
    )

    if other_user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    if other_user.id == current_user.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You cannot open a conversation with yourself",
        )

    result = await session.scalars(
        select(Message)
        .where(
            or_(
                and_(
                    Message.sender_id == current_user.id,
                    Message.recipient_id == other_user.id,
                ),
                and_(
                    Message.sender_id == other_user.id,
                    Message.recipient_id == current_user.id,
                ),
            )
        )
        .order_by(
            desc(Message.created_at),
            desc(Message.id),
        )
        .limit(limit)
    )

    messages = list(result)
    messages.reverse()

    return messages


@router.patch(
    "/conversation/{other_user_id}/read",
    response_model=MessagesMarkedReadResponse,
)
async def mark_conversation_as_read(
    other_user_id: int,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> MessagesMarkedReadResponse:
    other_user = await session.get(
        User,
        other_user_id,
    )

    if other_user is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="User not found",
        )

    if other_user.id == current_user.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You cannot mark your own conversation as read",
        )

    result = await session.scalars(
        select(Message).where(
            Message.sender_id == other_user.id,
            Message.recipient_id == current_user.id,
            Message.read_at.is_(None),
        )
    )

    unread_messages = list(result)

    if not unread_messages:
        return MessagesMarkedReadResponse(
            marked_read_count=0,
        )

    read_time = datetime.now(timezone.utc)

    for message in unread_messages:
        message.read_at = read_time

    await session.commit()

    message_ids = [
        message.id
        for message in unread_messages
    ]

    websocket_event = {
        "type": "messages.read",
        "reader_id": current_user.id,
        "sender_id": other_user.id,
        "message_ids": message_ids,
        "read_at": read_time.isoformat(),
    }

    await connection_manager.send_to_user(
        user_id=other_user.id,
        data=websocket_event,
    )

    await connection_manager.send_to_user(
        user_id=current_user.id,
        data=websocket_event,
    )

    return MessagesMarkedReadResponse(
        marked_read_count=len(unread_messages),
    )