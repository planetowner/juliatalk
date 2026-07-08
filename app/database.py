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


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session
