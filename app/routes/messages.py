import asyncio
import base64
import html
import logging
import math
import re
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from typing import Annotated, Any
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen
from uuid import UUID

from fastapi import (
    APIRouter,
    BackgroundTasks,
    Depends,
    HTTPException,
    Query,
    Response,
    status,
)
from sqlalchemy import desc, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import SessionLocal, get_session
from app.dependencies import get_current_user
from app.models import (
    CallKind,
    CallOutcome,
    Conversation,
    ConversationKind,
    ConversationMember,
    DirectConversation,
    MediaAsset,
    MediaKind,
    Message,
    MessageAttachment,
    MessageCallEvent,
    MessageDeletion,
    MessageEdit,
    MessageKind,
    MessageReadReceipt,
    MessageTranslation,
    TranslationStatus,
    User,
)
from app.schemas import (
    MessageCreate,
    MessageReplyReferenceRead,
    MessageRead,
    MessageUpdate,
    MessagesMarkedReadResponse,
    UnreadMessageCountRead,
)
from app.translation import (
    DEEPSEEK_MODEL,
    TRANSLATION_PROVIDER_NAME,
    should_translate_text,
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
LINK_PREVIEW_FETCH_TIMEOUT_SECONDS = 4
LINK_PREVIEW_MAX_BYTES = 256 * 1024
URL_PATTERN = re.compile(r"(?i)\b(?:https?://|www\.)[^\s<>'\"]+")
TRAILING_URL_PUNCTUATION = ".,!?;:)]}…"


def normalize_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)

    return value.astimezone(timezone.utc)


def sorted_direct_user_ids(
    first_user_id: UUID,
    second_user_id: UUID,
) -> tuple[UUID, UUID]:
    if str(first_user_id) < str(second_user_id):
        return first_user_id, second_user_id

    return second_user_id, first_user_id


def direct_participant_ids(
    direct_conversation: DirectConversation,
) -> tuple[UUID, UUID]:
    return (
        direct_conversation.user_one_id,
        direct_conversation.user_two_id,
    )


def direct_recipient_id(
    direct_conversation: DirectConversation,
    sender_id: UUID,
) -> UUID:
    if sender_id == direct_conversation.user_one_id:
        return direct_conversation.user_two_id

    return direct_conversation.user_one_id


class LinkPreviewHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.meta: dict[str, str] = {}
        self._title_parts: list[str] = []
        self._in_title = False

    @property
    def title(self) -> str | None:
        value = clean_preview_text(" ".join(self._title_parts))
        return value or None

    def handle_starttag(
        self,
        tag: str,
        attrs: list[tuple[str, str | None]],
    ) -> None:
        normalized_tag = tag.lower()

        if normalized_tag == "title":
            self._in_title = True
            return

        if normalized_tag != "meta":
            return

        attr_map = {
            key.lower(): value
            for key, value in attrs
            if value is not None
        }
        key = attr_map.get("property") or attr_map.get("name")
        content = attr_map.get("content")

        if key is None or content is None:
            return

        self.meta[key.lower()] = content.strip()

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "title":
            self._in_title = False

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self._title_parts.append(data)


def clean_preview_text(value: str | None, *, max_length: int = 280) -> str | None:
    if value is None:
        return None

    normalized = html.unescape(value)
    normalized = re.sub(r"\s+", " ", normalized).strip()

    if not normalized:
        return None

    if len(normalized) <= max_length:
        return normalized

    return normalized[: max_length - 1].rstrip() + "…"


def first_url_in_text(content: str) -> str | None:
    match = URL_PATTERN.search(content)

    if match is None:
        return None

    url = match.group(0).rstrip(TRAILING_URL_PUNCTUATION)

    if url.lower().startswith("www."):
        return f"https://{url}"

    return url


def domain_for_url(url: str) -> str:
    parsed_url = urlparse(url)
    domain = parsed_url.netloc.lower()

    if domain.startswith("www."):
        return domain[4:]

    return domain


def build_fallback_link_preview(
    url: str,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    preview = dict(metadata or {})
    preview_url = clean_preview_text(
        str(preview.get("url") or preview.get("canonical_url") or url),
        max_length=1000,
    )
    preview["url"] = preview_url or url
    preview["canonical_url"] = clean_preview_text(
        str(preview.get("canonical_url") or preview["url"]),
        max_length=1000,
    )
    preview["domain"] = clean_preview_text(
        str(preview.get("domain") or domain_for_url(preview["canonical_url"])),
        max_length=255,
    )

    for key in ("title", "description", "site_name", "image_url"):
        value = preview.get(key)

        if isinstance(value, str):
            preview[key] = clean_preview_text(value, max_length=1000)
        elif value is not None:
            preview.pop(key, None)

    return {key: value for key, value in preview.items() if value}


def build_link_preview_metadata(
    content: str,
    metadata: dict[str, Any] | None,
) -> dict[str, Any] | None:
    url = first_url_in_text(content)

    if url is None:
        return metadata if metadata else None

    fallback = build_fallback_link_preview(url, metadata)
    parsed_url = urlparse(url)

    if parsed_url.scheme not in {"http", "https"} or not parsed_url.netloc:
        return fallback

    try:
        request = Request(
            url,
            headers={
                "User-Agent": (
                    "Mozilla/5.0 (compatible; JuliaTalkLinkPreview/1.0)"
                ),
                "Accept": "text/html,application/xhtml+xml",
            },
        )

        with urlopen(
            request,
            timeout=LINK_PREVIEW_FETCH_TIMEOUT_SECONDS,
        ) as response:
            content_type = response.headers.get("Content-Type", "")

            if (
                "html" not in content_type.lower()
                and "text" not in content_type.lower()
            ):
                return fallback

            charset = response.headers.get_content_charset() or "utf-8"
            raw_body = response.read(LINK_PREVIEW_MAX_BYTES)
    except (HTTPError, URLError, TimeoutError, OSError, ValueError) as error:
        logger.info("Link preview fetch failed for %s: %s", url, error)
        return fallback

    parser = LinkPreviewHTMLParser()

    try:
        parser.feed(raw_body.decode(charset, errors="replace"))
    except (LookupError, UnicodeDecodeError):
        parser.feed(raw_body.decode("utf-8", errors="replace"))

    meta = parser.meta
    canonical_url = clean_preview_text(
        meta.get("og:url") or fallback.get("canonical_url") or url,
        max_length=1000,
    )
    title = clean_preview_text(
        meta.get("og:title") or meta.get("twitter:title") or parser.title,
        max_length=180,
    )
    description = clean_preview_text(
        meta.get("og:description")
        or meta.get("twitter:description")
        or meta.get("description"),
        max_length=260,
    )
    site_name = clean_preview_text(
        meta.get("og:site_name") or fallback.get("site_name"),
        max_length=120,
    )
    image_url = clean_preview_text(
        meta.get("og:image")
        or meta.get("og:image:url")
        or meta.get("twitter:image"),
        max_length=1000,
    )

    if image_url is not None:
        image_url = urljoin(url, image_url)

    preview = {
        **fallback,
        "url": url,
        "canonical_url": canonical_url or url,
        "domain": domain_for_url(canonical_url or url),
    }

    if title is not None:
        preview["title"] = title

    if description is not None:
        preview["description"] = description

    if site_name is not None:
        preview["site_name"] = site_name

    if image_url is not None:
        preview["image_url"] = image_url

    return preview


async def send_to_direct_participants(
    direct_conversation: DirectConversation,
    data: dict[str, Any],
) -> None:
    for user_id in direct_participant_ids(direct_conversation):
        await connection_manager.send_to_user(
            user_id=user_id,
            data=data,
        )


async def get_direct_conversation(
    session: AsyncSession,
    first_user_id: UUID,
    second_user_id: UUID,
    *,
    create: bool = False,
    created_by_user_id: UUID | None = None,
) -> DirectConversation | None:
    user_one_id, user_two_id = sorted_direct_user_ids(
        first_user_id,
        second_user_id,
    )

    direct_conversation = await session.scalar(
        select(DirectConversation).where(
            DirectConversation.user_one_id == user_one_id,
            DirectConversation.user_two_id == user_two_id,
        )
    )

    if direct_conversation is not None or not create:
        return direct_conversation

    conversation = Conversation(
        kind=ConversationKind.DIRECT,
        created_by_user_id=created_by_user_id,
    )
    session.add(conversation)
    await session.flush()

    direct_conversation = DirectConversation(
        conversation_id=conversation.id,
        user_one_id=user_one_id,
        user_two_id=user_two_id,
    )

    session.add_all(
        [
            direct_conversation,
            ConversationMember(
                conversation_id=conversation.id,
                user_id=user_one_id,
            ),
            ConversationMember(
                conversation_id=conversation.id,
                user_id=user_two_id,
            ),
        ]
    )
    await session.flush()

    return direct_conversation


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


def require_media_asset_ids(
    metadata: dict[str, Any],
) -> list[UUID]:
    value = metadata.get("media_asset_ids")

    if not isinstance(value, list) or not value:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="metadata.media_asset_ids must be a non-empty list",
        )

    media_asset_ids: list[UUID] = []

    for item in value:
        try:
            media_asset_ids.append(UUID(str(item)))
        except (TypeError, ValueError) as error:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="metadata.media_asset_ids must contain UUIDs",
            ) from error

    return media_asset_ids


def normalized_waveform_samples(metadata: dict[str, Any] | None) -> list[float]:
    if metadata is None:
        return []

    value = metadata.get("waveform_samples")

    if not isinstance(value, list):
        return []

    samples: list[float] = []

    for item in value[:80]:
        if isinstance(item, bool) or not isinstance(item, (int, float)):
            continue

        sample = float(item)

        if not math.isfinite(sample):
            continue

        samples.append(max(0.0, min(1.0, sample)))

    return samples


def message_metadata_for_storage(
    message_type: str,
    metadata: dict[str, Any] | None,
) -> dict[str, Any]:
    if message_type == "link" and metadata is not None:
        return metadata

    if message_type == "voice_memo":
        waveform_samples = normalized_waveform_samples(metadata)

        if waveform_samples:
            return {"waveform_samples": waveform_samples}

    return {}


def validate_message_metadata(
    message_type: str,
    metadata: dict[str, Any] | None,
) -> None:
    if message_type == "text":
        return

    if message_type == "link":
        return

    metadata = require_metadata_dict(message_type, metadata)

    if message_type in {"photo", "video", "file", "voice_memo"}:
        require_media_asset_ids(metadata)
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


async def add_message_payload_records(
    session: AsyncSession,
    *,
    message: Message,
    sender_id: UUID,
    message_type: str,
    metadata: dict[str, Any] | None,
) -> None:
    if message_type in {"photo", "video", "file", "voice_memo"}:
        assert metadata is not None
        expected_kind = MediaKind(message_type)
        media_asset_ids = require_media_asset_ids(metadata)

        for position, media_asset_id in enumerate(media_asset_ids):
            media_asset = await session.get(MediaAsset, media_asset_id)

            if (
                media_asset is None
                or media_asset.owner_user_id != sender_id
                or media_asset.kind != expected_kind
                or media_asset.upload_status != "complete"
                or media_asset.storage_key is None
            ):
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail=(
                        "metadata.media_asset_ids must reference completed "
                        f"{message_type} uploads owned by the sender"
                    ),
                )

            session.add(
                MessageAttachment(
                    message_id=message.id,
                    media_asset_id=media_asset.id,
                    position=position,
                )
            )

        return

    if message_type == "call":
        assert metadata is not None

        session.add(
            MessageCallEvent(
                message_id=message.id,
                kind=CallKind(metadata["kind"]),
                outcome=CallOutcome(metadata["outcome"]),
                duration_ms=metadata["duration_ms"],
            )
        )


def build_metadata(
    message: Message,
    attachments: list[tuple[MessageAttachment, MediaAsset]],
    call_event: MessageCallEvent | None,
) -> dict[str, Any] | None:
    def media_asset_metadata(media_asset: MediaAsset) -> dict[str, Any]:
        return {
            "media_asset_id": str(media_asset.id),
            "kind": media_asset.kind.value,
            "file_name": media_asset.file_name,
            "mime_type": media_asset.mime_type,
            "size_bytes": media_asset.size_bytes or 0,
            "width": media_asset.width or 0,
            "height": media_asset.height or 0,
            "duration_ms": media_asset.duration_ms or 0,
            "has_thumbnail": media_asset.thumbnail_storage_key is not None,
            "available": (
                media_asset.upload_status == "complete"
                and media_asset.storage_key is not None
            ),
        }

    if message.kind == MessageKind.PHOTO:
        photos = []

        for _, media_asset in attachments:
            photo = media_asset_metadata(media_asset)
            photo["asset_id"] = (
                media_asset.original_asset_id or str(media_asset.id)
            )

            if (
                media_asset.storage_key is None
                and media_asset.preview_bytes is not None
            ):
                photo["preview_base64"] = base64.b64encode(
                    media_asset.preview_bytes
                ).decode("ascii")

            photos.append(photo)

        return {"photos": photos}

    if message.kind == MessageKind.VIDEO:
        if not attachments:
            return None

        _, media_asset = attachments[0]
        return {"video": media_asset_metadata(media_asset)}

    if message.kind == MessageKind.FILE:
        if not attachments:
            return None

        _, media_asset = attachments[0]
        file_metadata = media_asset_metadata(media_asset)
        file_metadata["name"] = media_asset.file_name or ""
        return {"file": file_metadata}

    if message.kind == MessageKind.VOICE_MEMO:
        if not attachments:
            return None

        _, media_asset = attachments[0]
        metadata = media_asset_metadata(media_asset)
        waveform_samples = normalized_waveform_samples(message.metadata_json)

        if not waveform_samples:
            waveform_samples = normalized_waveform_samples(media_asset.metadata_json)

        if waveform_samples:
            metadata["waveform_samples"] = waveform_samples

        if (
            media_asset.storage_key is None
            and media_asset.preview_bytes is not None
        ):
            metadata["audio_base64"] = base64.b64encode(
                media_asset.preview_bytes
            ).decode("ascii")

        return metadata

    if message.kind == MessageKind.LINK:
        return message.metadata_json or None

    if message.kind == MessageKind.CALL:
        if call_event is None:
            return None

        return {
            "kind": call_event.kind.value,
            "outcome": call_event.outcome.value,
            "duration_ms": call_event.duration_ms,
        }

    return None


def build_reply_reference(
    message: Message | None,
) -> MessageReplyReferenceRead | None:
    if message is None:
        return None

    return MessageReplyReferenceRead(
        message_id=message.id,
        sender_id=message.sender_id,
        content=message.body,
    )


async def load_direct_users(
    session: AsyncSession,
    direct_conversation: DirectConversation,
) -> dict[UUID, User]:
    result = await session.scalars(
        select(User).where(
            User.id.in_(direct_participant_ids(direct_conversation))
        )
    )

    return {user.id: user for user in result}


async def build_message_reads(
    session: AsyncSession,
    messages: list[Message],
    *,
    direct_conversation: DirectConversation,
) -> list[MessageRead]:
    if not messages:
        return []

    message_ids = [message.id for message in messages]
    users_by_id = await load_direct_users(session, direct_conversation)

    reply_ids = {
        message.reply_to_message_id
        for message in messages
        if message.reply_to_message_id is not None
    }
    reply_messages: dict[UUID, Message] = {}

    if reply_ids:
        reply_result = await session.scalars(
            select(Message).where(Message.id.in_(reply_ids))
        )
        reply_messages = {message.id: message for message in reply_result}

    attachment_rows = await session.execute(
        select(MessageAttachment, MediaAsset)
        .join(
            MediaAsset,
            MessageAttachment.media_asset_id == MediaAsset.id,
        )
        .where(MessageAttachment.message_id.in_(message_ids))
        .order_by(
            MessageAttachment.message_id,
            MessageAttachment.position,
        )
    )

    attachments_by_message: dict[
        UUID,
        list[tuple[MessageAttachment, MediaAsset]],
    ] = defaultdict(list)

    for attachment, media_asset in attachment_rows:
        attachments_by_message[attachment.message_id].append(
            (attachment, media_asset)
        )

    call_result = await session.scalars(
        select(MessageCallEvent).where(
            MessageCallEvent.message_id.in_(message_ids)
        )
    )
    call_events = {
        call_event.message_id: call_event
        for call_event in call_result
    }

    translation_result = await session.scalars(
        select(MessageTranslation).where(
            MessageTranslation.message_id.in_(message_ids)
        )
    )
    translations: dict[tuple[UUID, str], MessageTranslation] = {}

    for translation in translation_result:
        translations[
            (
                translation.message_id,
                translation.target_language,
            )
        ] = translation

    read_result = await session.scalars(
        select(MessageReadReceipt).where(
            MessageReadReceipt.message_id.in_(message_ids)
        )
    )
    reads = {
        (read.message_id, read.user_id): read
        for read in read_result
    }

    response_messages: list[MessageRead] = []

    for message in messages:
        recipient_id = direct_recipient_id(
            direct_conversation,
            message.sender_id,
        )
        sender = users_by_id[message.sender_id]
        recipient = users_by_id[recipient_id]
        translation = translations.get(
            (message.id, recipient.preferred_language)
        )
        read_receipt = reads.get((message.id, recipient_id))
        source_language = (
            message.source_language or sender.preferred_language
        )
        needs_translation = (
            message.kind == MessageKind.TEXT
            and should_translate_text(
                message.body,
                source_language=source_language,
                target_language=recipient.preferred_language,
            )
        )

        if message.kind == MessageKind.TEXT and needs_translation:
            translation_status = (
                translation.status.value
                if translation is not None
                else TranslationStatus.PENDING.value
            )
            translated_content = (
                translation.translated_body
                if translation is not None
                else None
            )
            translation_provider = (
                translation.provider
                if translation is not None
                else None
            )
            translation_model = (
                translation.model
                if translation is not None
                else None
            )
        elif message.kind == MessageKind.TEXT:
            translation_status = TranslationStatus.COMPLETED.value
            translated_content = None
            translation_provider = None
            translation_model = None
        else:
            translation_status = TranslationStatus.COMPLETED.value
            translated_content = None
            translation_provider = None
            translation_model = None

        response_messages.append(
            MessageRead(
                id=message.id,
                sender_id=message.sender_id,
                recipient_id=recipient_id,
                content=message.body,
                message_type=message.kind.value,
                metadata=build_metadata(
                    message,
                    attachments_by_message.get(message.id, []),
                    call_events.get(message.id),
                ),
                reply_to_message_id=message.reply_to_message_id,
                reply_to=build_reply_reference(
                    reply_messages.get(message.reply_to_message_id)
                ),
                created_at=message.created_at,
                edited_at=message.edited_at,
                read_at=(
                    read_receipt.read_at
                    if read_receipt is not None
                    else None
                ),
                source_language=source_language,
                translated_content=translated_content,
                translated_language=recipient.preferred_language,
                translation_status=translation_status,
                translation_provider=translation_provider,
                translation_model=translation_model,
            )
        )

    return response_messages


async def build_single_message_read(
    session: AsyncSession,
    message: Message,
    *,
    direct_conversation: DirectConversation,
) -> MessageRead:
    return (
        await build_message_reads(
            session,
            [message],
            direct_conversation=direct_conversation,
        )
    )[0]


async def execute_message_translation(
    session: AsyncSession,
    message: Message,
    *,
    direct_conversation: DirectConversation,
    force: bool = False,
) -> bool:
    users_by_id = await load_direct_users(session, direct_conversation)
    sender = users_by_id.get(message.sender_id)
    recipient_id = direct_recipient_id(
        direct_conversation,
        message.sender_id,
    )
    recipient = users_by_id.get(recipient_id)

    if sender is None or recipient is None:
        return False

    translation = await session.scalar(
        select(MessageTranslation).where(
            MessageTranslation.message_id == message.id,
            MessageTranslation.target_language == recipient.preferred_language,
        )
    )

    source_language = (
        translation.source_language
        if force and translation is not None
        else message.source_language or sender.preferred_language
    )

    should_run_translation = force or should_translate_text(
        message.body,
        source_language=source_language,
        target_language=recipient.preferred_language,
    )

    if not should_run_translation:
        if translation is None:
            return False

        translation.translated_body = message.body
        translation.status = TranslationStatus.COMPLETED
        translation.provider = None
        translation.model = None
        translation.error_message = None
        translation.updated_at = datetime.now(timezone.utc)
        return True

    if translation is None:
        translation = MessageTranslation(
            message_id=message.id,
            source_language=source_language,
            target_language=recipient.preferred_language,
            status=TranslationStatus.PENDING,
        )
        session.add(translation)
        await session.flush()
    elif force:
        translation.source_language = source_language
        translation.translated_body = None
        translation.status = TranslationStatus.PENDING
        translation.provider = None
        translation.model = None
        translation.error_message = None
        translation.updated_at = datetime.now(timezone.utc)

    if translation.status != TranslationStatus.PENDING:
        return False

    context_result = await session.scalars(
        select(Message)
        .where(
            Message.conversation_id == message.conversation_id,
            Message.id != message.id,
            Message.kind == MessageKind.TEXT,
            Message.deleted_at.is_(None),
            Message.created_at <= message.created_at,
        )
        .order_by(desc(Message.created_at), desc(Message.id))
        .limit(8)
    )

    previous_messages = list(context_result)
    previous_messages.reverse()

    context_messages = [
        (
            f"{users_by_id.get(previous.sender_id, sender).display_name}: "
            f"{previous.body}"
        )
        for previous in previous_messages
    ]

    try:
        translation_result = await translate_message(
            text=message.body,
            source_language=source_language,
            target_language=recipient.preferred_language,
            context_messages=context_messages,
        )
    except Exception as error:
        logger.exception(
            "Translation failed for message ID %s",
            message.id,
        )
        translation.translated_body = None
        translation.status = TranslationStatus.FAILED
        translation.provider = TRANSLATION_PROVIDER_NAME
        translation.model = DEEPSEEK_MODEL
        translation.error_message = str(error)
    else:
        translation.translated_body = translation_result.translated_text
        translation.status = TranslationStatus.COMPLETED
        translation.provider = translation_result.provider
        translation.model = translation_result.model
        translation.error_message = None

    translation.updated_at = datetime.now(timezone.utc)
    return True


async def translate_and_publish_message(message_id: UUID) -> None:
    async with SessionLocal() as session:
        message = await session.get(Message, message_id)

        if message is None:
            return

        if message.kind != MessageKind.TEXT or message.deleted_at is not None:
            return

        direct_conversation = await session.scalar(
            select(DirectConversation).where(
                DirectConversation.conversation_id
                == message.conversation_id
            )
        )

        if direct_conversation is None:
            return

        did_update_translation = await execute_message_translation(
            session,
            message,
            direct_conversation=direct_conversation,
        )

        if not did_update_translation:
            return

        await session.commit()
        await session.refresh(message)

        message_read = await build_single_message_read(
            session,
            message,
            direct_conversation=direct_conversation,
        )
        websocket_event = {
            "type": "message.translation.updated",
            "message": message_read.model_dump(mode="json"),
        }

    await send_to_direct_participants(
        direct_conversation,
        websocket_event,
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
    recipient = await session.get(User, message_data.recipient_id)

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
    message_type = message_data.message_type

    if message_type in {"text", "link"}:
        message_type = "link" if first_url_in_text(content) is not None else "text"

    if message_type in {"text", "link"} and not content.strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Message content cannot be blank",
        )

    validate_message_metadata(message_type, message_data.metadata)
    message_metadata = message_data.metadata

    if message_type == "link":
        message_metadata = await asyncio.to_thread(
            build_link_preview_metadata,
            content,
            message_data.metadata,
        )

    direct_conversation = await get_direct_conversation(
        session,
        current_user.id,
        recipient.id,
        create=True,
        created_by_user_id=current_user.id,
    )
    assert direct_conversation is not None

    reply_to_message = None

    if message_data.reply_to_message_id is not None:
        reply_to_message = await session.get(
            Message,
            message_data.reply_to_message_id,
        )

        if (
            reply_to_message is None
            or reply_to_message.deleted_at is not None
            or reply_to_message.conversation_id
            != direct_conversation.conversation_id
        ):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Reply target not found",
            )

    message = Message(
        conversation_id=direct_conversation.conversation_id,
        sender_id=current_user.id,
        kind=MessageKind(message_type),
        body=content,
        metadata_json=message_metadata_for_storage(
            message_type,
            message_metadata,
        ),
        reply_to_message_id=message_data.reply_to_message_id,
        source_language=current_user.preferred_language,
        client_created_at=(
            normalize_utc(message_data.created_at)
            if message_data.created_at is not None
            else None
        ),
    )

    if message_data.created_at is not None:
        message.created_at = normalize_utc(message_data.created_at)

    session.add(message)
    await session.flush()

    await add_message_payload_records(
        session,
        message=message,
        sender_id=current_user.id,
        message_type=message_type,
        metadata=message_metadata,
    )

    should_translate_created_message = (
        message.kind == MessageKind.TEXT
        and should_translate_text(
            content,
            source_language=current_user.preferred_language,
            target_language=recipient.preferred_language,
        )
    )

    if should_translate_created_message:
        session.add(
            MessageTranslation(
                message_id=message.id,
                source_language=current_user.preferred_language,
                target_language=recipient.preferred_language,
                status=TranslationStatus.PENDING,
            )
        )

    conversation = await session.get(
        Conversation,
        direct_conversation.conversation_id,
    )

    if conversation is not None:
        conversation.last_message_id = message.id
        conversation.last_message_at = message.created_at
        conversation.updated_at = datetime.now(timezone.utc)

    await session.commit()
    await session.refresh(message)

    message_read = await build_single_message_read(
        session,
        message,
        direct_conversation=direct_conversation,
    )
    message_created_event = {
        "type": "message.created",
        "message": message_read.model_dump(mode="json"),
    }

    await send_to_direct_participants(
        direct_conversation,
        message_created_event,
    )

    if should_translate_created_message:
        background_tasks.add_task(translate_and_publish_message, message.id)

    return message_read


@router.get(
    "/unread-count",
    response_model=UnreadMessageCountRead,
)
async def count_unread_messages(
    current_user: CurrentUserDependency,
    session: SessionDependency,
    exclude_user_id: Annotated[UUID | None, Query()] = None,
) -> UnreadMessageCountRead:
    member_conversation_ids = select(
        ConversationMember.conversation_id
    ).where(
        ConversationMember.user_id == current_user.id,
    )
    read_message_ids = select(
        MessageReadReceipt.message_id
    ).where(
        MessageReadReceipt.user_id == current_user.id,
    )
    hidden_message_ids = select(
        MessageDeletion.message_id
    ).where(
        MessageDeletion.user_id == current_user.id,
    )

    unread_count_query = (
        select(func.count())
        .select_from(Message)
        .where(
            Message.conversation_id.in_(member_conversation_ids),
            Message.sender_id != current_user.id,
            Message.deleted_at.is_(None),
            Message.id.not_in(read_message_ids),
            Message.id.not_in(hidden_message_ids),
        )
    )

    if exclude_user_id is not None:
        excluded_conversation = await get_direct_conversation(
            session,
            current_user.id,
            exclude_user_id,
        )

        if excluded_conversation is not None:
            unread_count_query = unread_count_query.where(
                Message.conversation_id
                != excluded_conversation.conversation_id,
            )

    unread_count = await session.scalar(unread_count_query)

    return UnreadMessageCountRead(unread_count=int(unread_count or 0))


@router.get(
    "/conversation/{other_user_id}",
    response_model=list[MessageRead],
)
async def list_conversation(
    other_user_id: UUID,
    current_user: CurrentUserDependency,
    session: SessionDependency,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> list[MessageRead]:
    other_user = await session.get(User, other_user_id)

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

    direct_conversation = await get_direct_conversation(
        session,
        current_user.id,
        other_user.id,
    )

    if direct_conversation is None:
        return []

    hidden_message_ids = select(MessageDeletion.message_id).where(
        MessageDeletion.conversation_id
        == direct_conversation.conversation_id,
        MessageDeletion.user_id == current_user.id,
    )

    result = await session.scalars(
        select(Message)
        .where(
            Message.conversation_id
            == direct_conversation.conversation_id,
            Message.deleted_at.is_(None),
            Message.id.not_in(hidden_message_ids),
        )
        .order_by(desc(Message.created_at), desc(Message.id))
        .limit(limit)
    )

    messages = list(result)
    messages.reverse()

    return await build_message_reads(
        session,
        messages,
        direct_conversation=direct_conversation,
    )


@router.get(
    "/conversation/{other_user_id}/search",
    response_model=list[MessageRead],
)
async def search_conversation(
    other_user_id: UUID,
    current_user: CurrentUserDependency,
    session: SessionDependency,
    query: Annotated[str, Query(min_length=1, max_length=100)],
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> list[MessageRead]:
    other_user = await session.get(User, other_user_id)

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

    direct_conversation = await get_direct_conversation(
        session,
        current_user.id,
        other_user.id,
    )

    if direct_conversation is None:
        return []

    normalized_query = query.strip()

    if not normalized_query:
        return []

    search_pattern = f"%{normalized_query.lower()}%"
    translated_match_ids = select(MessageTranslation.message_id).where(
        func.lower(MessageTranslation.translated_body).like(search_pattern)
    )
    hidden_message_ids = select(MessageDeletion.message_id).where(
        MessageDeletion.conversation_id
        == direct_conversation.conversation_id,
        MessageDeletion.user_id == current_user.id,
    )

    result = await session.scalars(
        select(Message)
        .where(
            Message.conversation_id
            == direct_conversation.conversation_id,
            Message.deleted_at.is_(None),
            Message.id.not_in(hidden_message_ids),
            or_(
                func.lower(Message.body).like(search_pattern),
                Message.id.in_(translated_match_ids),
            ),
        )
        .order_by(Message.created_at, Message.id)
        .limit(limit)
    )

    return await build_message_reads(
        session,
        list(result),
        direct_conversation=direct_conversation,
    )


@router.patch(
    "/conversation/{other_user_id}/read",
    response_model=MessagesMarkedReadResponse,
)
async def mark_conversation_as_read(
    other_user_id: UUID,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> MessagesMarkedReadResponse:
    other_user = await session.get(User, other_user_id)

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

    direct_conversation = await get_direct_conversation(
        session,
        current_user.id,
        other_user.id,
    )

    if direct_conversation is None:
        return MessagesMarkedReadResponse(marked_read_count=0)

    existing_read_ids = select(MessageReadReceipt.message_id).where(
        MessageReadReceipt.conversation_id
        == direct_conversation.conversation_id,
        MessageReadReceipt.user_id == current_user.id,
    )

    result = await session.scalars(
        select(Message).where(
            Message.conversation_id
            == direct_conversation.conversation_id,
            Message.sender_id == other_user.id,
            Message.deleted_at.is_(None),
            Message.id.not_in(existing_read_ids),
        )
    )
    unread_messages = list(result)

    if not unread_messages:
        return MessagesMarkedReadResponse(marked_read_count=0)

    read_time = datetime.now(timezone.utc)

    for message in unread_messages:
        session.add(
            MessageReadReceipt(
                message_id=message.id,
                conversation_id=message.conversation_id,
                user_id=current_user.id,
                read_at=read_time,
            )
        )

    member = await session.get(
        ConversationMember,
        (direct_conversation.conversation_id, current_user.id),
    )

    if member is not None:
        latest_message = max(
            unread_messages,
            key=lambda message: message.created_at,
        )
        member.last_read_message_id = latest_message.id
        member.last_read_at = read_time

    await session.commit()

    websocket_event = {
        "type": "messages.read",
        "reader_id": str(current_user.id),
        "sender_id": str(other_user.id),
        "message_ids": [str(message.id) for message in unread_messages],
        "read_at": read_time.isoformat(),
    }

    await send_to_direct_participants(direct_conversation, websocket_event)

    return MessagesMarkedReadResponse(
        marked_read_count=len(unread_messages),
    )


@router.post(
    "/{message_id}/translation/retry",
    response_model=MessageRead,
)
async def retry_message_translation(
    message_id: UUID,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> MessageRead:
    message = await session.get(Message, message_id)

    if (
        message is None
        or message.deleted_at is not None
        or message.kind != MessageKind.TEXT
    ):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Message not found",
        )

    direct_conversation = await session.scalar(
        select(DirectConversation).where(
            DirectConversation.conversation_id == message.conversation_id
        )
    )

    if direct_conversation is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Conversation not found",
        )

    participant_ids = direct_participant_ids(direct_conversation)

    if current_user.id not in participant_ids:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You are not a participant in this conversation",
        )

    recipient_id = direct_recipient_id(direct_conversation, message.sender_id)

    if current_user.id != recipient_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only the message recipient can retry translation",
        )

    await execute_message_translation(
        session,
        message,
        direct_conversation=direct_conversation,
        force=True,
    )
    await session.commit()
    await session.refresh(message)

    message_read = await build_single_message_read(
        session,
        message,
        direct_conversation=direct_conversation,
    )

    await send_to_direct_participants(
        direct_conversation,
        {
            "type": "message.translation.updated",
            "message": message_read.model_dump(mode="json"),
        },
    )

    return message_read


@router.patch(
    "/{message_id}",
    response_model=MessageRead,
)
async def update_message(
    message_id: UUID,
    message_data: MessageUpdate,
    background_tasks: BackgroundTasks,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> MessageRead:
    message = await session.get(Message, message_id)

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

    if message.kind not in {MessageKind.TEXT, MessageKind.LINK}:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only text and link messages can be edited",
        )

    content = message_data.content

    if not content.strip():
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Message content cannot be blank",
        )

    updated_message_type = (
        "link" if first_url_in_text(content) is not None else "text"
    )
    updated_metadata = (
        await asyncio.to_thread(build_link_preview_metadata, content, None)
        if updated_message_type == "link"
        else None
    )

    direct_conversation = await session.scalar(
        select(DirectConversation).where(
            DirectConversation.conversation_id == message.conversation_id
        )
    )

    if direct_conversation is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Conversation not found",
        )

    session.add(
        MessageEdit(
            message_id=message.id,
            editor_user_id=current_user.id,
            previous_body=message.body,
        )
    )

    now = datetime.now(timezone.utc)
    message.kind = MessageKind(updated_message_type)
    message.body = content
    message.metadata_json = message_metadata_for_storage(
        updated_message_type,
        updated_metadata,
    )
    message.edited_at = now
    message.updated_at = now
    message.version += 1

    recipient_id = direct_recipient_id(
        direct_conversation,
        message.sender_id,
    )
    recipient = await session.get(User, recipient_id)
    should_translate_updated_message = False

    if recipient is not None and message.kind == MessageKind.TEXT:
        source_language = (
            message.source_language
            or current_user.preferred_language
        )
        should_translate_updated_message = should_translate_text(
            content,
            source_language=source_language,
            target_language=recipient.preferred_language,
        )
        translation = await session.scalar(
            select(MessageTranslation).where(
                MessageTranslation.message_id == message.id,
                MessageTranslation.target_language
                == recipient.preferred_language,
            )
        )

        if translation is None and should_translate_updated_message:
            translation = MessageTranslation(
                message_id=message.id,
                source_language=source_language,
                target_language=recipient.preferred_language,
            )
            session.add(translation)

        if translation is not None:
            translation.translated_body = (
                None if should_translate_updated_message else content
            )
            translation.status = (
                TranslationStatus.PENDING
                if should_translate_updated_message
                else TranslationStatus.COMPLETED
            )
            translation.provider = None
            translation.model = None
            translation.error_message = None
            translation.updated_at = now

    await session.commit()
    await session.refresh(message)

    message_read = await build_single_message_read(
        session,
        message,
        direct_conversation=direct_conversation,
    )

    await send_to_direct_participants(
        direct_conversation,
        {
            "type": "message.updated",
            "message": message_read.model_dump(mode="json"),
        },
    )

    if should_translate_updated_message:
        background_tasks.add_task(translate_and_publish_message, message.id)

    return message_read


@router.delete(
    "/{message_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def delete_message(
    message_id: UUID,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> Response:
    message = await session.get(Message, message_id)

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

    direct_conversation = await session.scalar(
        select(DirectConversation).where(
            DirectConversation.conversation_id == message.conversation_id
        )
    )

    if direct_conversation is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Conversation not found",
        )

    now = datetime.now(timezone.utc)
    created_at = normalize_utc(message.created_at)

    if now - created_at > UNSEND_WINDOW:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="The unsend window has expired",
        )

    message.deleted_at = now
    message.deleted_by_user_id = current_user.id
    message.updated_at = now

    await session.commit()

    await send_to_direct_participants(
        direct_conversation,
        {
            "type": "message.deleted",
            "message_id": str(message.id),
        },
    )

    return Response(status_code=status.HTTP_204_NO_CONTENT)
