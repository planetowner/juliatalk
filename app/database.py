import os
from collections.abc import AsyncIterator
from pathlib import Path

from dotenv import load_dotenv
from sqlalchemy import text
from sqlalchemy.ext.asyncio import (
    AsyncConnection,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase


PROJECT_ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = PROJECT_ROOT / ".env"
DATABASE_URL_ENV_NAME = "DATABASE_URL"

load_dotenv(
    dotenv_path=ENV_PATH,
    override=False,
)


def resolve_database_url() -> str:
    database_url = os.getenv(DATABASE_URL_ENV_NAME)

    if database_url is None:
        raise RuntimeError(
            "DATABASE_URL is required."
        )

    database_url = database_url.strip()

    if not database_url:
        raise RuntimeError(
            "DATABASE_URL is empty."
        )

    if database_url.startswith("postgresql+asyncpg://"):
        return database_url

    if database_url.startswith("postgresql://"):
        return database_url.replace(
            "postgresql://",
            "postgresql+asyncpg://",
            1,
        )

    if database_url.startswith("postgres://"):
        return database_url.replace(
            "postgres://",
            "postgresql+asyncpg://",
            1,
        )

    raise RuntimeError(
        "DATABASE_URL must be a PostgreSQL URL."
    )


DATABASE_URL = resolve_database_url()

engine = create_async_engine(
    DATABASE_URL,
    pool_pre_ping=True,
)

SessionLocal = async_sessionmaker(
    bind=engine,
    class_=AsyncSession,
    expire_on_commit=False,
)


class Base(DeclarativeBase):
    pass


async def ensure_database_extensions(
    connection: AsyncConnection,
) -> None:
    await connection.execute(
        text("CREATE EXTENSION IF NOT EXISTS pgcrypto")
    )
    await connection.execute(
        text("CREATE EXTENSION IF NOT EXISTS citext")
    )


async def ensure_schema_compatibility(
    connection: AsyncConnection,
) -> None:
    await connection.execute(
        text(
            "ALTER TABLE users "
            "ADD COLUMN IF NOT EXISTS profile_image_url TEXT"
        )
    )
    await connection.execute(
        text(
            "ALTER TABLE messages "
            "ADD COLUMN IF NOT EXISTS metadata JSONB "
            "NOT NULL DEFAULT '{}'::jsonb"
        )
    )
    await connection.execute(
        text("ALTER TYPE message_kind ADD VALUE IF NOT EXISTS 'link'")
    )
    await connection.execute(
        text("ALTER TYPE message_kind ADD VALUE IF NOT EXISTS 'video'")
    )
    await connection.execute(
        text("ALTER TYPE media_kind ADD VALUE IF NOT EXISTS 'video'")
    )
    await connection.execute(
        text(
            "ALTER TABLE media_assets "
            "ADD COLUMN IF NOT EXISTS thumbnail_storage_key TEXT"
        )
    )
    await connection.execute(
        text(
            "ALTER TABLE media_assets "
            "ADD COLUMN IF NOT EXISTS upload_status TEXT "
            "NOT NULL DEFAULT 'complete'"
        )
    )
    await connection.execute(
        text(
            "ALTER TABLE media_assets "
            "ADD COLUMN IF NOT EXISTS metadata JSONB "
            "NOT NULL DEFAULT '{}'::jsonb"
        )
    )
    await connection.execute(
        text(
            "ALTER TABLE user_devices "
            "ADD COLUMN IF NOT EXISTS installation_id VARCHAR(128)"
        )
    )
    await connection.execute(
        text(
            "ALTER TABLE user_devices "
            "ADD COLUMN IF NOT EXISTS voip_push_token TEXT"
        )
    )
    await connection.execute(
        text(
            "ALTER TABLE user_devices "
            "ADD COLUMN IF NOT EXISTS app_bundle_id VARCHAR(255)"
        )
    )
    await connection.execute(
        text(
            "ALTER TABLE user_devices "
            "ADD COLUMN IF NOT EXISTS apns_environment VARCHAR(16) "
            "NOT NULL DEFAULT 'development'"
        )
    )
    await connection.execute(
        text(
            "CREATE UNIQUE INDEX IF NOT EXISTS "
            "user_devices_active_voip_push_token_idx "
            "ON user_devices (voip_push_token) "
            "WHERE voip_push_token IS NOT NULL AND revoked_at IS NULL"
        )
    )
    await connection.execute(
        text(
            "CREATE UNIQUE INDEX IF NOT EXISTS "
            "user_devices_active_installation_idx "
            "ON user_devices (user_id, installation_id) "
            "WHERE installation_id IS NOT NULL AND revoked_at IS NULL"
        )
    )


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session
