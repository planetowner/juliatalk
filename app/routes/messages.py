import logging
from datetime import datetime, timedelta, timezone
from typing import Annotated, Any

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    HTTPException,
    Query,
    Response,
    status,
)
from sqlalchemy import and_, desc, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import SessionLocal, get_session
from app.dependencies import get_current_user
from app.models import Message, User
from app.schemas import (
    MessageCreate,
    MessageReplyReferenceRead,
    MessageRead,
    MessageUpdate,
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

CALL_OUTCOMES = {
    "started",
    "ended",
    "cancelled",
    "missed",
    "no_answer",
}

CALL_KINDS = {
    "voice",
    "video",
}

UNSEND_WINDOW = timedelta(minutes=5)


def message_belongs_to_conversation(
    message: Message,
    first_user_id: int,
    second_user_id: int,
) -> bool:
    return (
        message.sender_id == first_user_id
        and message.recipient_id == second_user_id
    ) or (
        message.sender_id == second_user_id
        and message.recipient_id == first_user_id
    )


def require_metadata_dict(
    message_type: str,
    metadata: dict[str, Any] | None,
) -> dict[str, Any]:
    if metadata is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{message_type} messages require metadata",
        )

    return metadata


def require_non_empty_string(
    metadata: dict[str, Any],
    key: str,
) -> str:
    value = metadata.get(key)

    if not isinstance(value, str) or not value.strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"metadata.{key} must be a non-empty string",
        )

    return value


def require_non_negative_int(
    metadata: dict[str, Any],
    key: str,
) -> int:
    value = metadata.get(key)

    if not isinstance(value, int) or value < 0:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"metadata.{key} must be a non-negative integer",
        )

    return value


def validate_message_metadata(
    message_type: str,
    metadata: dict[str, Any] | None,
) -> None:
    if message_type == "text":
        return

    metadata = require_metadata_dict(
        message_type,
        metadata,
    )

    if message_type == "photo":
        photos = metadata.get("photos")

        if not isinstance(photos, list) or not photos:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="metadata.photos must be a non-empty list",
            )

        for photo in photos:
            if not isinstance(photo, dict):
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail="metadata.photos must contain objects",
                )

            require_non_empty_string(photo, "asset_id")
            require_non_negative_int(photo, "width")
            require_non_negative_int(photo, "height")

        return

    if message_type == "file":
        file_metadata = metadata.get("file")

        if not isinstance(file_metadata, dict):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="metadata.file must be an object",
            )

        require_non_empty_string(file_metadata, "name")
        require_non_negative_int(file_metadata, "size_bytes")
        return

    if message_type == "voice_memo":
        require_non_negative_int(metadata, "duration_ms")
        return

    if message_type == "call":
        call_kind = metadata.get("kind")
        call_outcome = metadata.get("outcome")

        if call_kind not in CALL_KINDS:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="metadata.kind must be voice or video",
            )

        if call_outcome not in CALL_OUTCOMES:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="metadata.outcome is not supported",
            )

        require_non_negative_int(metadata, "duration_ms")


def build_reply_reference(
    message: Message | None,
) -> MessageReplyReferenceRead | None:
    if message is None:
        return None

    return MessageReplyReferenceRead(
        message_id=message.id,
        sender_id=message.sender_id,
        content=message.content,
    )


def build_message_read(
    message: Message,
    *,
    reply_to: Message | None = None,
) -> MessageRead:
    metadata = message.metadata_json

    if metadata is not None and not isinstance(metadata, dict):
        metadata = None

    return MessageRead(
        id=message.id,
        sender_id=message.sender_id,
        recipient_id=message.recipient_id,
        content=message.content,
        message_type=message.message_type,
        metadata=metadata,
        reply_to_message_id=message.reply_to_message_id,
        reply_to=build_reply_reference(reply_to),
        created_at=message.created_at,
        edited_at=message.edited_at,
        read_at=message.read_at,
        source_language=message.source_language,
        translated_content=message.translated_content,
        translated_language=message.translated_language,
        translation_status=message.translation_status,
        translation_provider=message.translation_provider,
        translation_model=message.translation_model,
    )


def normalize_utc(
    value: datetime,
) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)

    return value.astimezone(timezone.utc)


async def build_message_reads(
    session: AsyncSession,
    messages: list[Message],
) -> list[MessageRead]:
    reply_ids = {
        message.reply_to_message_id
        for message in messages
        if message.reply_to_message_id is not None
    }

    reply_messages: dict[int, Message] = {}

    if reply_ids:
        reply_result = await session.scalars(
            select(Message).where(Message.id.in_(reply_ids))
        )

        reply_messages = {
            message.id: message
            for message in reply_result
        }

    return [
        build_message_read(
            message,
            reply_to=reply_messages.get(message.reply_to_message_id),
        )
        for message in messages
    ]


async def publish_translation_update(
    message: Message,
    *,
    reply_to: Message | None = None,
) -> None:
    websocket_event = {
        "type": "message.translation.updated",
        "message": build_message_read(
            message,
            reply_to=reply_to,
        ).model_dump(mode="json"),
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

        if message.message_type != "text":
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
                Message.message_type == "text",
                Message.deleted_at.is_(None),
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

        reply_to = None

        if message.reply_to_message_id is not None:
            reply_to = await session.get(
                Message,
                message.reply_to_message_id,
            )

        await publish_translation_update(
            message,
            reply_to=reply_to,
        )


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
) -> MessageRead:
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

    content = message_data.content

    if message_data.message_type == "text" and not content.strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Message content cannot be blank",
        )

    validate_message_metadata(
        message_data.message_type,
        message_data.metadata,
    )

    reply_to_message = None

    if message_data.reply_to_message_id is not None:
        reply_to_message = await session.get(
            Message,
            message_data.reply_to_message_id,
        )

        if (
            reply_to_message is None
            or reply_to_message.deleted_at is not None
            or not message_belongs_to_conversation(
                reply_to_message,
                current_user.id,
                recipient.id,
            )
        ):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Reply target not found",
            )

    translation_status = "pending"

    if message_data.message_type != "text":
        translation_status = "completed"

    message = Message(
        sender_id=current_user.id,
        recipient_id=recipient.id,
        content=content,
        message_type=message_data.message_type,
        metadata_json=message_data.metadata,
        reply_to_message_id=message_data.reply_to_message_id,
        source_language=current_user.preferred_language,
        translated_language=recipient.preferred_language,
        translated_content=None,
        translation_status=translation_status,
        translation_provider=None,
        translation_model=None,
    )

    session.add(message)
    await session.commit()
    await session.refresh(message)

    message_read = build_message_read(
        message,
        reply_to=reply_to_message,
    )

    message_created_event = {
        "type": "message.created",
        "message": message_read.model_dump(mode="json"),
    }

    await connection_manager.send_to_user(
        user_id=recipient.id,
        data=message_created_event,
    )

    await connection_manager.send_to_user(
        user_id=current_user.id,
        data=message_created_event,
    )

    if message.message_type == "text":
        background_tasks.add_task(
            translate_and_publish_message,
            message.id,
        )

    return message_read


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
) -> list[MessageRead]:
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
            Message.deleted_at.is_(None),
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

    return await build_message_reads(
        session,
        messages,
    )


@router.get(
    "/conversation/{other_user_id}/search",
    response_model=list[MessageRead],
)
async def search_conversation(
    other_user_id: int,
    current_user: CurrentUserDependency,
    session: SessionDependency,
    query: Annotated[
        str,
        Query(min_length=1, max_length=100),
    ],
    limit: Annotated[
        int,
        Query(ge=1, le=100),
    ] = 50,
) -> list[MessageRead]:
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
            detail="You cannot search your own conversation",
        )

    normalized_query = query.strip()

    if not normalized_query:
        return []

    search_pattern = f"%{normalized_query.lower()}%"

    result = await session.scalars(
        select(Message)
        .where(
            Message.deleted_at.is_(None),
            or_(
                and_(
                    Message.sender_id == current_user.id,
                    Message.recipient_id == other_user.id,
                ),
                and_(
                    Message.sender_id == other_user.id,
                    Message.recipient_id == current_user.id,
                ),
            ),
            or_(
                func.lower(Message.content).like(search_pattern),
                func.lower(Message.translated_content).like(
                    search_pattern
                ),
            ),
        )
        .order_by(
            Message.created_at,
            Message.id,
        )
        .limit(limit)
    )

    return await build_message_reads(
        session,
        list(result),
    )


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
            Message.deleted_at.is_(None),
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


@router.patch(
    "/{message_id}",
    response_model=MessageRead,
)
async def update_message(
    message_id: int,
    message_data: MessageUpdate,
    background_tasks: BackgroundTasks,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> MessageRead:
    message = await session.get(
        Message,
        message_id,
    )

    if message is None or message.deleted_at is not None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Message not found",
        )

    if message.sender_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only edit your own messages",
        )

    if message.message_type != "text":
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only text messages can be edited",
        )

    content = message_data.content

    if not content.strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Message content cannot be blank",
        )

    message.content = content
    message.edited_at = datetime.now(timezone.utc)
    message.translated_content = None
    message.translation_status = "pending"
    message.translation_provider = None
    message.translation_model = None

    await session.commit()
    await session.refresh(message)

    reply_to = None

    if message.reply_to_message_id is not None:
        reply_to = await session.get(
            Message,
            message.reply_to_message_id,
        )

    message_read = build_message_read(
        message,
        reply_to=reply_to,
    )

    websocket_event = {
        "type": "message.updated",
        "message": message_read.model_dump(mode="json"),
    }

    await connection_manager.send_to_user(
        user_id=message.sender_id,
        data=websocket_event,
    )

    await connection_manager.send_to_user(
        user_id=message.recipient_id,
        data=websocket_event,
    )

    background_tasks.add_task(
        translate_and_publish_message,
        message.id,
    )

    return message_read


@router.delete(
    "/{message_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_message(
    message_id: int,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> Response:
    message = await session.get(
        Message,
        message_id,
    )

    if message is None or message.deleted_at is not None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Message not found",
        )

    if message.sender_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only delete your own messages",
        )

    now = datetime.now(timezone.utc)
    created_at = normalize_utc(message.created_at)

    if now - created_at > UNSEND_WINDOW:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="The unsend window has expired",
        )

    message.deleted_at = now

    await session.commit()

    websocket_event = {
        "type": "message.deleted",
        "message_id": message.id,
    }

    await connection_manager.send_to_user(
        user_id=message.sender_id,
        data=websocket_event,
    )

    await connection_manager.send_to_user(
        user_id=message.recipient_id,
        data=websocket_event,
    )

    return Response(status_code=status.HTTP_204_NO_CONTENT)
