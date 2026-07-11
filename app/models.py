from __future__ import annotations

import enum
from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    DateTime,
    Enum,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    LargeBinary,
    PrimaryKeyConstraint,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import CITEXT, JSONB, UUID as PG_UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


def enum_values(enum_class: type[enum.Enum]) -> list[str]:
    return [item.value for item in enum_class]


class ConversationKind(str, enum.Enum):
    DIRECT = "direct"
    GROUP = "group"


class ConversationMemberRole(str, enum.Enum):
    OWNER = "owner"
    ADMIN = "admin"
    MEMBER = "member"


class DevicePlatform(str, enum.Enum):
    IOS = "ios"
    ANDROID = "android"
    WEB = "web"


class MessageKind(str, enum.Enum):
    TEXT = "text"
    LINK = "link"
    PHOTO = "photo"
    VIDEO = "video"
    FILE = "file"
    VOICE_MEMO = "voice_memo"
    CALL = "call"
    SYSTEM = "system"


class MediaKind(str, enum.Enum):
    PHOTO = "photo"
    VIDEO = "video"
    FILE = "file"
    VOICE_MEMO = "voice_memo"


class CallKind(str, enum.Enum):
    VOICE = "voice"
    VIDEO = "video"


class CallOutcome(str, enum.Enum):
    STARTED = "started"
    ENDED = "ended"
    CANCELLED = "cancelled"
    MISSED = "missed"
    NO_ANSWER = "no_answer"


class TranslationStatus(str, enum.Enum):
    PENDING = "pending"
    COMPLETED = "completed"
    FAILED = "failed"


conversation_kind_enum = Enum(
    ConversationKind,
    name="conversation_kind",
    values_callable=enum_values,
)

conversation_member_role_enum = Enum(
    ConversationMemberRole,
    name="conversation_member_role",
    values_callable=enum_values,
)

device_platform_enum = Enum(
    DevicePlatform,
    name="device_platform",
    values_callable=enum_values,
)

message_kind_enum = Enum(
    MessageKind,
    name="message_kind",
    values_callable=enum_values,
)

media_kind_enum = Enum(
    MediaKind,
    name="media_kind",
    values_callable=enum_values,
)

call_kind_enum = Enum(
    CallKind,
    name="call_kind",
    values_callable=enum_values,
)

call_outcome_enum = Enum(
    CallOutcome,
    name="call_outcome",
    values_callable=enum_values,
)

translation_status_enum = Enum(
    TranslationStatus,
    name="translation_status",
    values_callable=enum_values,
)


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint(
            "length(btrim(username::text)) BETWEEN 1 AND 50",
            name="users_username_length_check",
        ),
        CheckConstraint(
            "length(btrim(display_name)) BETWEEN 1 AND 100",
            name="users_display_name_length_check",
        ),
        CheckConstraint(
            "token_version >= 0",
            name="users_token_version_check",
        ),
    )

    id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        server_default=text("gen_random_uuid()"),
    )

    username: Mapped[str] = mapped_column(
        CITEXT,
        nullable=False,
        unique=True,
    )

    display_name: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )

    profile_image_url: Mapped[str | None] = mapped_column(Text)

    password_hash: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )

    preferred_language: Mapped[str] = mapped_column(
        String(16),
        nullable=False,
        default="ko",
        server_default="ko",
    )

    token_version: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
        server_default="0",
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    disabled_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
    )


class UserDevice(Base):
    __tablename__ = "user_devices"
    __table_args__ = (
        Index(
            "user_devices_active_user_idx",
            "user_id",
            text("last_seen_at DESC"),
            postgresql_where=text("revoked_at IS NULL"),
        ),
        Index(
            "user_devices_active_push_token_idx",
            "push_token",
            unique=True,
            postgresql_where=text(
                "push_token IS NOT NULL AND revoked_at IS NULL"
            ),
        ),
    )

    id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        server_default=text("gen_random_uuid()"),
    )

    user_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    platform: Mapped[DevicePlatform] = mapped_column(
        device_platform_enum,
        nullable=False,
    )

    push_token: Mapped[str | None] = mapped_column(Text)

    device_name: Mapped[str | None] = mapped_column(Text)

    last_seen_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    revoked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )


class Conversation(Base):
    __tablename__ = "conversations"
    __table_args__ = (
        CheckConstraint(
            "kind = 'direct' OR title IS NOT NULL",
            name="conversations_title_required_for_groups_check",
        ),
        Index(
            "conversations_last_message_idx",
            text("last_message_at DESC NULLS LAST"),
        ),
    )

    id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        server_default=text("gen_random_uuid()"),
    )

    kind: Mapped[ConversationKind] = mapped_column(
        conversation_kind_enum,
        nullable=False,
    )

    title: Mapped[str | None] = mapped_column(Text)

    created_by_user_id: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    last_message_id: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey(
            "messages.id",
            ondelete="SET NULL",
            use_alter=True,
            name="conversations_last_message_fk",
        ),
    )

    last_message_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )

    archived_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )


class DirectConversation(Base):
    __tablename__ = "direct_conversations"
    __table_args__ = (
        CheckConstraint(
            "user_one_id < user_two_id",
            name="direct_conversations_distinct_users_check",
        ),
        UniqueConstraint(
            "user_one_id",
            "user_two_id",
            name="direct_conversations_unique_pair",
        ),
    )

    conversation_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("conversations.id", ondelete="CASCADE"),
        primary_key=True,
    )

    user_one_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    user_two_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )


class ConversationMember(Base):
    __tablename__ = "conversation_members"
    __table_args__ = (
        PrimaryKeyConstraint("conversation_id", "user_id"),
        Index(
            "conversation_members_user_idx",
            "user_id",
            text("joined_at DESC"),
            postgresql_where=text("left_at IS NULL"),
        ),
    )

    conversation_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("conversations.id", ondelete="CASCADE"),
        nullable=False,
    )

    user_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    role: Mapped[ConversationMemberRole] = mapped_column(
        conversation_member_role_enum,
        nullable=False,
        default=ConversationMemberRole.MEMBER,
        server_default=ConversationMemberRole.MEMBER.value,
    )

    joined_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    left_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )

    muted_until: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )

    archived_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )

    last_read_message_id: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey(
            "messages.id",
            ondelete="SET NULL",
            use_alter=True,
            name="conversation_members_last_read_message_fk",
        ),
    )

    last_read_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )


class Message(Base):
    __tablename__ = "messages"
    __table_args__ = (
        ForeignKeyConstraint(
            ["conversation_id", "sender_id"],
            [
                "conversation_members.conversation_id",
                "conversation_members.user_id",
            ],
            ondelete="RESTRICT",
            name="messages_member_sender_fk",
        ),
        CheckConstraint(
            "kind <> 'text' OR length(btrim(body)) > 0",
            name="messages_text_body_check",
        ),
        CheckConstraint("version >= 1", name="messages_version_check"),
        UniqueConstraint(
            "id",
            "conversation_id",
            name="messages_id_conversation_unique",
        ),
        Index(
            "messages_conversation_timeline_idx",
            "conversation_id",
            text("created_at DESC"),
            text("id DESC"),
            postgresql_where=text("deleted_at IS NULL"),
        ),
        Index(
            "messages_sender_client_message_idx",
            "sender_id",
            "client_message_id",
            unique=True,
            postgresql_where=text("client_message_id IS NOT NULL"),
        ),
        Index(
            "messages_reply_idx",
            "reply_to_message_id",
            postgresql_where=text("reply_to_message_id IS NOT NULL"),
        ),
        Index(
            "messages_body_fts_idx",
            text("to_tsvector('simple', coalesce(body, ''))"),
            postgresql_using="gin",
            postgresql_where=text("deleted_at IS NULL"),
        ),
    )

    id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        server_default=text("gen_random_uuid()"),
    )

    conversation_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("conversations.id", ondelete="CASCADE"),
        nullable=False,
    )

    sender_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="RESTRICT"),
        nullable=False,
    )

    client_message_id: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True)
    )

    kind: Mapped[MessageKind] = mapped_column(
        message_kind_enum,
        nullable=False,
    )

    body: Mapped[str] = mapped_column(
        Text,
        nullable=False,
        default="",
        server_default="",
    )

    metadata_json: Mapped[dict[str, Any]] = mapped_column(
        "metadata",
        JSONB,
        nullable=False,
        default=dict,
        server_default=text("'{}'::jsonb"),
    )

    reply_to_message_id: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("messages.id", ondelete="SET NULL"),
    )

    source_language: Mapped[str | None] = mapped_column(String(16))

    client_created_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    edited_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )

    deleted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True)
    )

    deleted_by_user_id: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
    )

    version: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=1,
        server_default="1",
    )


class MediaAsset(Base):
    __tablename__ = "media_assets"
    __table_args__ = (
        CheckConstraint(
            "size_bytes IS NULL OR size_bytes >= 0",
            name="media_assets_size_check",
        ),
        CheckConstraint(
            "width IS NULL OR width >= 0",
            name="media_assets_width_check",
        ),
        CheckConstraint(
            "height IS NULL OR height >= 0",
            name="media_assets_height_check",
        ),
        CheckConstraint(
            "duration_ms IS NULL OR duration_ms >= 0",
            name="media_assets_duration_check",
        ),
        Index(
            "media_assets_owner_idx",
            "owner_user_id",
            text("created_at DESC"),
        ),
    )

    id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        server_default=text("gen_random_uuid()"),
    )

    owner_user_id: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
    )

    kind: Mapped[MediaKind] = mapped_column(
        media_kind_enum,
        nullable=False,
    )

    storage_key: Mapped[str | None] = mapped_column(Text, unique=True)

    thumbnail_storage_key: Mapped[str | None] = mapped_column(Text, unique=True)

    upload_status: Mapped[str] = mapped_column(
        Text,
        nullable=False,
        default="complete",
        server_default="complete",
    )

    original_asset_id: Mapped[str | None] = mapped_column(Text)

    file_name: Mapped[str | None] = mapped_column(Text)

    mime_type: Mapped[str | None] = mapped_column(Text)

    size_bytes: Mapped[int | None] = mapped_column(BigInteger)

    width: Mapped[int | None] = mapped_column(Integer)

    height: Mapped[int | None] = mapped_column(Integer)

    duration_ms: Mapped[int | None] = mapped_column(Integer)

    preview_bytes: Mapped[bytes | None] = mapped_column(LargeBinary)

    metadata_json: Mapped[dict[str, Any]] = mapped_column(
        "metadata",
        JSONB,
        nullable=False,
        default=dict,
        server_default=text("'{}'::jsonb"),
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )


class MessageAttachment(Base):
    __tablename__ = "message_attachments"
    __table_args__ = (
        CheckConstraint(
            "position >= 0",
            name="message_attachments_position_check",
        ),
        UniqueConstraint(
            "message_id",
            "position",
            name="message_attachments_unique_position",
        ),
        Index(
            "message_attachments_message_idx",
            "message_id",
            "position",
        ),
    )

    id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        server_default=text("gen_random_uuid()"),
    )

    message_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("messages.id", ondelete="CASCADE"),
        nullable=False,
    )

    media_asset_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("media_assets.id", ondelete="RESTRICT"),
        nullable=False,
    )

    position: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
        server_default="0",
    )

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )


class MessageCallEvent(Base):
    __tablename__ = "message_call_events"
    __table_args__ = (
        CheckConstraint(
            "duration_ms >= 0",
            name="message_call_events_duration_check",
        ),
    )

    message_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("messages.id", ondelete="CASCADE"),
        primary_key=True,
    )

    kind: Mapped[CallKind] = mapped_column(
        call_kind_enum,
        nullable=False,
    )

    outcome: Mapped[CallOutcome] = mapped_column(
        call_outcome_enum,
        nullable=False,
    )

    duration_ms: Mapped[int] = mapped_column(
        Integer,
        nullable=False,
        default=0,
        server_default="0",
    )


class MessageTranslation(Base):
    __tablename__ = "message_translations"
    __table_args__ = (
        UniqueConstraint(
            "message_id",
            "target_language",
            name="message_translations_unique_target",
        ),
        CheckConstraint(
            "status <> 'completed' OR translated_body IS NOT NULL",
            name="message_translations_completed_body_check",
        ),
        Index(
            "message_translations_message_idx",
            "message_id",
            "target_language",
        ),
        Index(
            "message_translations_body_fts_idx",
            text("to_tsvector('simple', coalesce(translated_body, ''))"),
            postgresql_using="gin",
            postgresql_where=text("status = 'completed'"),
        ),
    )

    id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        server_default=text("gen_random_uuid()"),
    )

    message_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("messages.id", ondelete="CASCADE"),
        nullable=False,
    )

    source_language: Mapped[str] = mapped_column(
        String(16),
        nullable=False,
    )

    target_language: Mapped[str] = mapped_column(
        String(16),
        nullable=False,
    )

    translated_body: Mapped[str | None] = mapped_column(Text)

    status: Mapped[TranslationStatus] = mapped_column(
        translation_status_enum,
        nullable=False,
        default=TranslationStatus.PENDING,
        server_default=TranslationStatus.PENDING.value,
    )

    provider: Mapped[str | None] = mapped_column(Text)

    model: Mapped[str | None] = mapped_column(Text)

    error_message: Mapped[str | None] = mapped_column(Text)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )


class MessageReadReceipt(Base):
    __tablename__ = "message_reads"
    __table_args__ = (
        PrimaryKeyConstraint("message_id", "user_id"),
        ForeignKeyConstraint(
            ["message_id", "conversation_id"],
            ["messages.id", "messages.conversation_id"],
            ondelete="CASCADE",
            name="message_reads_message_fk",
        ),
        ForeignKeyConstraint(
            ["conversation_id", "user_id"],
            [
                "conversation_members.conversation_id",
                "conversation_members.user_id",
            ],
            ondelete="CASCADE",
            name="message_reads_member_fk",
        ),
        Index(
            "message_reads_user_idx",
            "user_id",
            text("read_at DESC"),
        ),
    )

    message_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        nullable=False,
    )

    conversation_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        nullable=False,
    )

    user_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        nullable=False,
    )

    read_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )


class MessageDeletion(Base):
    __tablename__ = "message_deletions"
    __table_args__ = (
        PrimaryKeyConstraint("message_id", "user_id"),
        ForeignKeyConstraint(
            ["message_id", "conversation_id"],
            ["messages.id", "messages.conversation_id"],
            ondelete="CASCADE",
            name="message_deletions_message_fk",
        ),
        ForeignKeyConstraint(
            ["conversation_id", "user_id"],
            [
                "conversation_members.conversation_id",
                "conversation_members.user_id",
            ],
            ondelete="CASCADE",
            name="message_deletions_member_fk",
        ),
        Index(
            "message_deletions_user_idx",
            "user_id",
            text("hidden_at DESC"),
        ),
    )

    message_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        nullable=False,
    )

    conversation_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        nullable=False,
    )

    user_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        nullable=False,
    )

    hidden_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )


class MessageEdit(Base):
    __tablename__ = "message_edits"

    id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        server_default=text("gen_random_uuid()"),
    )

    message_id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("messages.id", ondelete="CASCADE"),
        nullable=False,
    )

    editor_user_id: Mapped[UUID | None] = mapped_column(
        PG_UUID(as_uuid=True),
        ForeignKey("users.id", ondelete="SET NULL"),
    )

    previous_body: Mapped[str] = mapped_column(
        Text,
        nullable=False,
    )

    edited_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
