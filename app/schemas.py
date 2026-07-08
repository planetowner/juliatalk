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
    "photo",
    "file",
    "voice_memo",
    "call",
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
