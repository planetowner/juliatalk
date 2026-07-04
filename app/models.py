from datetime import datetime

from sqlalchemy import (
    DateTime,
    ForeignKey,
    Integer,
    JSON,
    String,
    Text,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(
        primary_key=True,
    )

    username: Mapped[str] = mapped_column(
        String(50),
        unique=True,
        index=True,
    )

    display_name: Mapped[str] = mapped_column(
        String(100),
    )

    password_hash: Mapped[str] = mapped_column(
        String(255),
    )

    token_version: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
        server_default="0",
    )

    preferred_language: Mapped[str] = mapped_column(
        String(10),
        nullable=False,
        default="ko",
        server_default="ko",
    )


class Message(Base):
    __tablename__ = "messages"

    id: Mapped[int] = mapped_column(
        primary_key=True,
    )

    sender_id: Mapped[int] = mapped_column(
        ForeignKey("users.id"),
        index=True,
    )

    recipient_id: Mapped[int] = mapped_column(
        ForeignKey("users.id"),
        index=True,
    )

    content: Mapped[str] = mapped_column(
        Text,
    )

    message_type: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default="text",
        server_default="text",
        index=True,
    )

    metadata_json: Mapped[dict | None] = mapped_column(
        "metadata",
        JSON,
        nullable=True,
    )

    reply_to_message_id: Mapped[int | None] = mapped_column(
        ForeignKey("messages.id"),
        nullable=True,
        index=True,
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        server_default=func.now(),
    )

    edited_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )

    deleted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
        index=True,
    )

    read_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )

    source_language: Mapped[str] = mapped_column(
        String(10),
        nullable=False,
        default="ko",
        server_default="ko",
    )

    translated_content: Mapped[str | None] = mapped_column(
        Text,
        nullable=True,
    )

    translated_language: Mapped[str] = mapped_column(
        String(10),
        nullable=False,
        default="zh-CN",
        server_default="zh-CN",
    )

    translation_status: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default="pending",
        server_default="pending",
    )

    translation_provider: Mapped[str | None] = mapped_column(
        String(50),
        nullable=True,
    )

    translation_model: Mapped[str | None] = mapped_column(
        String(100),
        nullable=True,
    )
