from datetime import datetime
from typing import Literal

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


class UserRead(BaseModel):
    model_config = ConfigDict(
        from_attributes=True,
    )

    id: int
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
    recipient_id: int = Field(
        greater_than=0,
    )

    content: str = Field(
        min_length=1,
        max_length=10000,
    )


class MessageRead(BaseModel):
    model_config = ConfigDict(
        from_attributes=True,
    )

    id: int
    sender_id: int
    recipient_id: int

    content: str
    created_at: datetime
    read_at: datetime | None

    source_language: LanguageCode
    translated_content: str | None
    translated_language: LanguageCode
    translation_status: TranslationStatus
    translation_provider: str | None
    translation_model: str | None


class MessagesMarkedReadResponse(BaseModel):
    marked_read_count: int