import json
import os
from collections.abc import AsyncIterator
from pathlib import Path

from sqlalchemy.ext.asyncio import (
    AsyncConnection,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase
from sqlalchemy import text


PROJECT_ROOT = Path(__file__).resolve().parent.parent
VOLUME_MOUNT_PATH_ENV_NAME = "RAILWAY_VOLUME_MOUNT_PATH"


def resolve_database_path() -> Path:
    volume_mount_path = os.getenv(
        VOLUME_MOUNT_PATH_ENV_NAME
    )

    if volume_mount_path is None:
        return PROJECT_ROOT / "chat.db"

    volume_mount_path = volume_mount_path.strip()

    if not volume_mount_path:
        raise RuntimeError(
            "RAILWAY_VOLUME_MOUNT_PATH is empty."
        )

    return Path(volume_mount_path) / "chat.db"


DATABASE_PATH = resolve_database_path()

DATABASE_PATH.parent.mkdir(
    parents=True,
    exist_ok=True,
)

DATABASE_URL = (
    f"sqlite+aiosqlite:///{DATABASE_PATH.as_posix()}"
)

engine = create_async_engine(DATABASE_URL)

SessionLocal = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,
)


class Base(DeclarativeBase):
    pass


SEED_USERS_ENV_NAME = "SEED_USERS"


async def ensure_seed_users(
    connection: AsyncConnection,
) -> None:
    raw = os.getenv(SEED_USERS_ENV_NAME, "").strip()

    if not raw:
        return

    try:
        users = json.loads(raw)
    except json.JSONDecodeError:
        return

    if not isinstance(users, list):
        return

    for user in users:
        if not isinstance(user, dict):
            continue

        username = user.get("username")
        password_hash = user.get("password_hash")

        if not username or not password_hash:
            continue

        existing = (
            await connection.execute(
                text(
                    "SELECT id FROM users WHERE username = :username"
                ),
                {"username": username},
            )
        ).first()

        if existing is not None:
            continue

        columns = {
            "username": username,
            "display_name": user.get("display_name", username),
            "password_hash": password_hash,
            "token_version": user.get("token_version", 0),
            "preferred_language": user.get(
                "preferred_language", "ko"
            ),
        }

        user_id = user.get("id")

        if isinstance(user_id, int):
            columns["id"] = user_id

        column_names = ", ".join(columns)
        placeholders = ", ".join(
            f":{name}" for name in columns
        )

        await connection.execute(
            text(
                f"INSERT INTO users ({column_names}) "
                f"VALUES ({placeholders})"
            ),
            columns,
        )


async def ensure_database_schema(
    connection: AsyncConnection,
) -> None:
    table_result = await connection.execute(
        text(
            "SELECT name FROM sqlite_master "
            "WHERE type = 'table' AND name = 'messages'"
        )
    )

    if table_result.first() is None:
        return

    column_result = await connection.execute(
        text("PRAGMA table_info(messages)")
    )

    existing_columns = {
        row._mapping["name"]
        for row in column_result
    }

    column_definitions = {
        "message_type": (
            "ALTER TABLE messages "
            "ADD COLUMN message_type VARCHAR(20) "
            "NOT NULL DEFAULT 'text'"
        ),
        "metadata": (
            "ALTER TABLE messages "
            "ADD COLUMN metadata JSON"
        ),
        "reply_to_message_id": (
            "ALTER TABLE messages "
            "ADD COLUMN reply_to_message_id INTEGER "
            "REFERENCES messages(id)"
        ),
        "edited_at": (
            "ALTER TABLE messages "
            "ADD COLUMN edited_at DATETIME"
        ),
        "deleted_at": (
            "ALTER TABLE messages "
            "ADD COLUMN deleted_at DATETIME"
        ),
    }

    for column_name, statement in column_definitions.items():
        if column_name not in existing_columns:
            await connection.execute(text(statement))

    index_statements = [
        "CREATE INDEX IF NOT EXISTS "
        "ix_messages_message_type ON messages (message_type)",
        "CREATE INDEX IF NOT EXISTS "
        "ix_messages_reply_to_message_id "
        "ON messages (reply_to_message_id)",
        "CREATE INDEX IF NOT EXISTS "
        "ix_messages_deleted_at ON messages (deleted_at)",
    ]

    for statement in index_statements:
        await connection.execute(text(statement))


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session
