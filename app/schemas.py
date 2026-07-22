from __future__ import annotations

from datetime import datetime
from typing import Any, Literal, Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, model_validator


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
    profile_image_url: Optional[str] = None
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


class DeviceRegistrationUpdate(BaseModel):
    installation_id: str = Field(min_length=1, max_length=128)
    platform: Literal["ios"] = "ios"
    push_token: Optional[str] = Field(default=None, min_length=1, max_length=512)
    voip_push_token: Optional[str] = Field(
        default=None,
        min_length=1,
        max_length=512,
    )
    app_bundle_id: str = Field(min_length=1, max_length=255)
    apns_environment: Literal["development", "production"]
    device_name: Optional[str] = Field(default=None, max_length=255)

    @model_validator(mode="after")
    def require_push_token(self) -> "DeviceRegistrationUpdate":
        token_fields = {"push_token", "voip_push_token"}
        if (
            self.push_token is None
            and self.voip_push_token is None
            and not token_fields.intersection(self.model_fields_set)
        ):
            raise ValueError("At least one push token is required")

        return self


class DeviceRegistrationRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    installation_id: str
    platform: Literal["ios"]
    push_token: Optional[str]
    voip_push_token: Optional[str]
    app_bundle_id: str
    apns_environment: Literal["development", "production"]
    device_name: Optional[str]
    last_seen_at: Optional[datetime]


class MessageCreate(BaseModel):
    recipient_id: UUID

    content: str = Field(
        default="",
        max_length=10000,
    )

    message_type: MessageType = "text"

    metadata: Optional[dict[str, Any]] = None

    created_at: Optional[datetime] = None

    reply_to_message_id: Optional[UUID] = Field(
        default=None,
    )


class MediaAssetUploadCreate(BaseModel):
    kind: MediaType

    file_name: Optional[str] = Field(
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

    width: Optional[int] = Field(
        default=None,
        ge=0,
    )

    height: Optional[int] = Field(
        default=None,
        ge=0,
    )

    duration_ms: Optional[int] = Field(
        default=None,
        ge=0,
    )

    metadata: Optional[dict[str, Any]] = None


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
    mime_type: Optional[str]
    file_name: Optional[str]
    size_bytes: Optional[int]


class MessageUpdate(BaseModel):
    content: str = Field(
        min_length=1,
        max_length=10000,
    )


class CallOutcomeUpdate(BaseModel):
    outcome: Literal["ended", "cancelled", "missed", "no_answer"]
    duration_ms: int = Field(default=0, ge=0)


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
    metadata: Optional[dict[str, Any]]
    reply_to_message_id: Optional[UUID]
    reply_to: Optional[MessageReplyReferenceRead]
    created_at: datetime
    edited_at: Optional[datetime]
    read_at: Optional[datetime]

    source_language: LanguageCode
    translated_content: Optional[str]
    translated_language: LanguageCode
    translation_status: TranslationStatus
    translation_provider: Optional[str]
    translation_model: Optional[str]


class MessagesMarkedReadResponse(BaseModel):
    marked_read_count: int


class UnreadMessageCountRead(BaseModel):
    unread_count: int
