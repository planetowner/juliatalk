from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.database import SessionLocal
from app.models import User
from app.security import decode_access_token
from app.websocket_manager import connection_manager


router = APIRouter(
    tags=["websocket"],
)


async def authenticate_websocket(
    websocket: WebSocket,
) -> User | None:
    authorization = websocket.headers.get(
        "authorization"
    )

    if authorization is None:
        return None

    scheme, separator, token = authorization.partition(" ")

    if separator != " ":
        return None

    if scheme.lower() != "bearer":
        return None

    token = token.strip()

    if not token:
        return None

    try:
        user_id, token_version = decode_access_token(token)
    except ValueError:
        return None

    async with SessionLocal() as session:
        user = await session.get(User, user_id)

        if user is None:
            return None

        if user.token_version != token_version:
            return None

        return user


@router.websocket("/ws")
async def websocket_endpoint(
    websocket: WebSocket,
) -> None:
    user = await authenticate_websocket(websocket)

    if user is None:
        await websocket.close(code=1008)
        return

    await connection_manager.connect(
        user_id=user.id,
        websocket=websocket,
    )

    try:
        await websocket.send_json(
            {
                "type": "connected",
                "user": {
                    "id": user.id,
                    "username": user.username,
                    "display_name": user.display_name,
                },
            }
        )

        while True:
            data = await websocket.receive_json()
            event_type = data.get("type")

            if event_type == "ping":
                await websocket.send_json(
                    {
                        "type": "pong",
                    }
                )
                continue

            await websocket.send_json(
                {
                    "type": "error",
                    "detail": "Unsupported WebSocket event",
                }
            )

    except WebSocketDisconnect:
        pass

    finally:
        connection_manager.disconnect(
            user_id=user.id,
            websocket=websocket,
        )