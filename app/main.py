from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

import app.models
from app.database import (
    Base,
    engine,
    ensure_database_extensions,
    ensure_schema_compatibility,
)
from app.routes.auth import router as auth_router
from app.routes.devices import router as devices_router
from app.routes.media_assets import router as media_assets_router
from app.routes.messages import router as messages_router
from app.routes.users import router as users_router
from app.routes.websocket import router as websocket_router


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    async with engine.begin() as connection:
        await ensure_database_extensions(connection)
        await connection.run_sync(Base.metadata.create_all)
        await ensure_schema_compatibility(connection)

    yield

    await engine.dispose()


app = FastAPI(lifespan=lifespan)

app.include_router(auth_router)
app.include_router(users_router)
app.include_router(devices_router)
app.include_router(media_assets_router)
app.include_router(messages_router)
app.include_router(websocket_router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}
