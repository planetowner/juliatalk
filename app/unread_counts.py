from __future__ import annotations

import asyncio
from collections import defaultdict
from typing import Any, Optional
from uuid import UUID, uuid4

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
    ConversationMember,
    Message,
    MessageDeletion,
    MessageReadReceipt,
)
from app.websocket_manager import connection_manager


async def load_unread_counts_by_sender(
    session: AsyncSession,
    *,
    user_id: UUID,
) -> dict[UUID, int]:
    member_conversation_ids = select(
        ConversationMember.conversation_id
    ).where(
        ConversationMember.user_id == user_id,
    )
    read_message_ids = select(
        MessageReadReceipt.message_id
    ).where(
        MessageReadReceipt.user_id == user_id,
    )
    hidden_message_ids = select(
        MessageDeletion.message_id
    ).where(
        MessageDeletion.user_id == user_id,
    )
    rows = await session.execute(
        select(
            Message.sender_id,
            func.count(Message.id),
        )
        .where(
            Message.conversation_id.in_(member_conversation_ids),
            Message.sender_id != user_id,
            Message.deleted_at.is_(None),
            Message.id.not_in(read_message_ids),
            Message.id.not_in(hidden_message_ids),
        )
        .group_by(Message.sender_id)
    )

    return {
        sender_id: int(unread_count)
        for sender_id, unread_count in rows
    }


def build_unread_counts_snapshot(
    *,
    user_id: UUID,
    counts_by_sender_id: dict[UUID, int],
    stream_id: str,
    sequence: int,
    cause_message_id: Optional[UUID] = None,
) -> dict[str, Any]:
    normalized_counts = {
        str(sender_id): max(0, int(unread_count))
        for sender_id, unread_count in counts_by_sender_id.items()
        if unread_count > 0
    }
    snapshot: dict[str, Any] = {
        "user_id": str(user_id),
        "stream_id": stream_id,
        "sequence": sequence,
        "counts_by_sender_id": normalized_counts,
        "total_unread_count": sum(normalized_counts.values()),
    }

    if cause_message_id is not None:
        snapshot["cause_message_id"] = str(cause_message_id)

    return snapshot


class UnreadCountsEventPublisher:
    def __init__(self) -> None:
        self._stream_id = str(uuid4())
        self._sequence_by_user_id: defaultdict[UUID, int] = defaultdict(int)
        self._lock_by_user_id: dict[UUID, asyncio.Lock] = {}

    async def send_event(
        self,
        session: AsyncSession,
        *,
        user_id: UUID,
        event: dict[str, Any],
        cause_message_id: Optional[UUID] = None,
    ) -> None:
        if connection_manager.connection_count(user_id) == 0:
            return

        lock = self._lock_by_user_id.setdefault(user_id, asyncio.Lock())

        async with lock:
            counts_by_sender_id = await load_unread_counts_by_sender(
                session,
                user_id=user_id,
            )
            self._sequence_by_user_id[user_id] += 1
            snapshot = build_unread_counts_snapshot(
                user_id=user_id,
                counts_by_sender_id=counts_by_sender_id,
                stream_id=self._stream_id,
                sequence=self._sequence_by_user_id[user_id],
                cause_message_id=cause_message_id,
            )
            await connection_manager.send_to_user(
                user_id=user_id,
                data={
                    **event,
                    "unread_counts": snapshot,
                },
            )


unread_counts_event_publisher = UnreadCountsEventPublisher()
