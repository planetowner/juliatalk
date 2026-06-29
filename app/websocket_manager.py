from typing import Any

from fastapi import WebSocket, WebSocketDisconnect


class ConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[int, set[WebSocket]] = {}

    async def connect(
        self,
        user_id: int,
        websocket: WebSocket,
    ) -> None:
        await websocket.accept()

        if user_id not in self._connections:
            self._connections[user_id] = set()

        self._connections[user_id].add(websocket)

    def disconnect(
        self,
        user_id: int,
        websocket: WebSocket,
    ) -> None:
        user_connections = self._connections.get(user_id)

        if user_connections is None:
            return

        user_connections.discard(websocket)

        if not user_connections:
            del self._connections[user_id]

    async def send_to_user(
        self,
        user_id: int,
        data: dict[str, Any],
    ) -> None:
        user_connections = list(
            self._connections.get(user_id, set())
        )

        disconnected_connections: list[WebSocket] = []

        for websocket in user_connections:
            try:
                await websocket.send_json(data)
            except (WebSocketDisconnect, RuntimeError):
                disconnected_connections.append(websocket)

        for websocket in disconnected_connections:
            self.disconnect(user_id, websocket)

    def connection_count(
        self,
        user_id: int,
    ) -> int:
        return len(
            self._connections.get(user_id, set())
        )


connection_manager = ConnectionManager()