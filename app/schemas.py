from datetime import datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


LanguageCode = Literal[
    "ko",
    "zh-CN",
]

TranslationStatus = Literal[
    "pending",
    "completed",
    "failed",
]

MessageType = Literal[
    "text",
    "link",
    "photo",
    "video",
    "file",
    "voice_memo",
    "call",
]

MediaType = Literal[
    "photo",
    "video",
    "file",
    "voice_memo",
]


class UserRead(BaseModel):
    model_config = ConfigDict(
        from_attributes=True,
    )

    id: UUID
    username: str
    display_name: str
    preferred_language: LanguageCode


class DisplayNameUpdate(BaseModel):
    display_name: str = Field(
        min_length=1,
        max_length=100,
    )


class PasswordChangeRequest(BaseModel):
    current_password: str = Field(
        min_length=1,
    )

    new_password: str = Field(
        min_length=8,
        max_length=128,
    )


class LoginRequest(BaseModel):
    username: str = Field(
        min_length=1,
        max_length=50,
    )

    password: str = Field(
        min_length=1,
    )


class TokenResponse(BaseModel):
    access_token: str
    token_type: str
    user: UserRead


class MessageCreate(BaseModel):
    recipient_id: UUID

    content: str = Field(
        default="",
        max_length=10000,
    )

    message_type: MessageType = "text"

    metadata: dict[str, Any] | None = None

    created_at: datetime | None = None

    reply_to_message_id: UUID | None = Field(
        default=None,
    )


class MediaAssetUploadCreate(BaseModel):
    kind: MediaType

    file_name: str | None = Field(
        default=None,
        max_length=255,
    )

    mime_type: str = Field(
        min_length=1,
        max_length=255,
    )

    size_bytes: int = Field(
        ge=1,
    )

    width: int | None = Field(
        default=None,
        ge=0,
    )

    height: int | None = Field(
        default=None,
        ge=0,
    )

    duration_ms: int | None = Field(
        default=None,
        ge=0,
    )

    metadata: dict[str, Any] | None = None


class MediaAssetUploadRead(BaseModel):
    media_asset_id: UUID
    storage_key: str
    upload_url: str
    upload_headers: dict[str, str]
    expires_in_seconds: int


class MediaAssetCompleteRead(BaseModel):
    media_asset_id: UUID
    upload_status: str


class MediaAssetAccessRead(BaseModel):
    media_asset_id: UUID
    access_url: str
    expires_in_seconds: int
    mime_type: str | None
    file_name: str | None
    size_bytes: int | None


class MessageUpdate(BaseModel):
    content: str = Field(
        min_length=1,
        max_length=10000,
    )


class MessageReplyReferenceRead(BaseModel):
    message_id: UUID
    sender_id: UUID
    content: str


class MessageRead(BaseModel):
    model_config = ConfigDict(
        from_attributes=True,
    )

    id: UUID
    sender_id: UUID
    recipient_id: UUID

    content: str
    message_type: MessageType
    metadata: dict[str, Any] | None
    reply_to_message_id: UUID | None
    reply_to: MessageReplyReferenceRead | None
    created_at: datetime
    edited_at: datetime | None
    read_at: datetime | None

    source_language: LanguageCode
    translated_content: str | None
    translated_language: LanguageCode
    translation_status: TranslationStatus
    translation_provider: str | None
    translation_model: str | None


class MessagesMarkedReadResponse(BaseModel):
    marked_read_count: int


class UnreadMessageCountRead(BaseModel):
    unread_count: int
