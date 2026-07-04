import os
from collections.abc import AsyncIterator
from pathlib import Path

from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase


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


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session