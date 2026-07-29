import os
import unittest
from datetime import datetime, timezone
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from uuid import UUID

from fastapi import Response


os.environ.setdefault(
    "DATABASE_URL",
    "postgresql+asyncpg://postgres:postgres@localhost:5432/juliatalk_test",
)
os.environ.setdefault("OPENAI_API_KEY", "test-openai-api-key")
os.environ.setdefault("JWT_SECRET", "test-jwt-secret")

from app.models import Message, User
from app.routes import messages as message_routes


class ConversationPaginationTests(unittest.IsolatedAsyncioTestCase):
    async def test_cursor_page_returns_only_older_messages_and_has_more(self) -> None:
        current_user_id = UUID("00000000-0000-0000-0000-000000000001")
        other_user_id = UUID("00000000-0000-0000-0000-000000000002")
        conversation_id = UUID("00000000-0000-0000-0000-000000000010")
        cursor_id = UUID("00000000-0000-0000-0000-000000000103")
        cursor_created_at = datetime(2026, 7, 24, 3, 0, tzinfo=timezone.utc)
        current_user = SimpleNamespace(id=current_user_id)
        other_user = SimpleNamespace(id=other_user_id)
        direct_conversation = SimpleNamespace(conversation_id=conversation_id)
        cursor_message = SimpleNamespace(
            id=cursor_id,
            conversation_id=conversation_id,
            created_at=cursor_created_at,
        )
        newest_older_message = SimpleNamespace(
            id=UUID("00000000-0000-0000-0000-000000000102")
        )
        oldest_returned_message = SimpleNamespace(
            id=UUID("00000000-0000-0000-0000-000000000101")
        )
        extra_message = SimpleNamespace(
            id=UUID("00000000-0000-0000-0000-000000000100")
        )
        session = SimpleNamespace(
            get=AsyncMock(),
            scalars=AsyncMock(
                return_value=[
                    newest_older_message,
                    oldest_returned_message,
                    extra_message,
                ]
            ),
        )

        async def get_model(model: object, model_id: UUID) -> object:
            if model is User and model_id == other_user_id:
                return other_user
            if model is Message and model_id == cursor_id:
                return cursor_message
            return None

        session.get.side_effect = get_model
        response = Response()

        with (
            patch.object(
                message_routes,
                "get_direct_conversation",
                AsyncMock(return_value=direct_conversation),
            ),
            patch.object(
                message_routes,
                "build_message_reads",
                AsyncMock(
                    side_effect=lambda _session, messages, **_: messages
                ),
            ),
        ):
            result = await message_routes.list_conversation(
                other_user_id=other_user_id,
                current_user=current_user,
                session=session,
                response=response,
                before_message_id=cursor_id,
                limit=2,
            )

        self.assertEqual(
            result,
            [oldest_returned_message, newest_older_message],
        )
        self.assertEqual(response.headers["x-has-more"], "true")

        statement = session.scalars.await_args.args[0]
        statement_text = str(statement)
        self.assertIn("messages.created_at <", statement_text)
        self.assertIn("messages.id <", statement_text)

    async def test_last_page_reports_no_more_messages(self) -> None:
        current_user = SimpleNamespace(
            id=UUID("00000000-0000-0000-0000-000000000001")
        )
        other_user_id = UUID("00000000-0000-0000-0000-000000000002")
        direct_conversation = SimpleNamespace(
            conversation_id=UUID(
                "00000000-0000-0000-0000-000000000010"
            )
        )
        messages = [
            SimpleNamespace(
                id=UUID("00000000-0000-0000-0000-000000000002")
            ),
            SimpleNamespace(
                id=UUID("00000000-0000-0000-0000-000000000001")
            ),
        ]
        session = SimpleNamespace(
            get=AsyncMock(return_value=SimpleNamespace(id=other_user_id)),
            scalars=AsyncMock(return_value=messages),
        )
        response = Response()

        with (
            patch.object(
                message_routes,
                "get_direct_conversation",
                AsyncMock(return_value=direct_conversation),
            ),
            patch.object(
                message_routes,
                "build_message_reads",
                AsyncMock(
                    side_effect=lambda _session, page, **_: page
                ),
            ),
        ):
            result = await message_routes.list_conversation(
                other_user_id=other_user_id,
                current_user=current_user,
                session=session,
                response=response,
                limit=2,
            )

        self.assertEqual(result, list(reversed(messages)))
        self.assertEqual(response.headers["x-has-more"], "false")

    async def test_after_cursor_page_returns_newer_messages_in_order(self) -> None:
        current_user_id = UUID("00000000-0000-0000-0000-000000000001")
        other_user_id = UUID("00000000-0000-0000-0000-000000000002")
        conversation_id = UUID("00000000-0000-0000-0000-000000000010")
        cursor_id = UUID("00000000-0000-0000-0000-000000000101")
        cursor_created_at = datetime(2026, 7, 24, 3, 0, tzinfo=timezone.utc)
        current_user = SimpleNamespace(id=current_user_id)
        other_user = SimpleNamespace(id=other_user_id)
        direct_conversation = SimpleNamespace(conversation_id=conversation_id)
        cursor_message = SimpleNamespace(
            id=cursor_id,
            conversation_id=conversation_id,
            created_at=cursor_created_at,
        )
        first_newer_message = SimpleNamespace(
            id=UUID("00000000-0000-0000-0000-000000000102")
        )
        second_newer_message = SimpleNamespace(
            id=UUID("00000000-0000-0000-0000-000000000103")
        )
        extra_message = SimpleNamespace(
            id=UUID("00000000-0000-0000-0000-000000000104")
        )
        session = SimpleNamespace(
            get=AsyncMock(),
            scalars=AsyncMock(
                return_value=[
                    first_newer_message,
                    second_newer_message,
                    extra_message,
                ]
            ),
        )

        async def get_model(model: object, model_id: UUID) -> object:
            if model is User and model_id == other_user_id:
                return other_user
            if model is Message and model_id == cursor_id:
                return cursor_message
            return None

        session.get.side_effect = get_model
        response = Response()

        with (
            patch.object(
                message_routes,
                "get_direct_conversation",
                AsyncMock(return_value=direct_conversation),
            ),
            patch.object(
                message_routes,
                "build_message_reads",
                AsyncMock(
                    side_effect=lambda _session, messages, **_: messages
                ),
            ),
        ):
            result = await message_routes.list_conversation(
                other_user_id=other_user_id,
                current_user=current_user,
                session=session,
                response=response,
                after_message_id=cursor_id,
                limit=2,
            )

        self.assertEqual(
            result,
            [first_newer_message, second_newer_message],
        )
        self.assertEqual(response.headers["x-has-more"], "true")

        statement = session.scalars.await_args.args[0]
        statement_text = str(statement)
        self.assertIn("messages.created_at >", statement_text)
        self.assertIn("messages.id >", statement_text)

    async def test_message_context_returns_small_bidirectional_window(self) -> None:
        current_user_id = UUID("00000000-0000-0000-0000-000000000001")
        other_user_id = UUID("00000000-0000-0000-0000-000000000002")
        conversation_id = UUID("00000000-0000-0000-0000-000000000010")
        target_id = UUID("00000000-0000-0000-0000-000000000103")
        target_created_at = datetime(2026, 7, 24, 3, 0, tzinfo=timezone.utc)
        current_user = SimpleNamespace(id=current_user_id)
        other_user = SimpleNamespace(id=other_user_id)
        direct_conversation = SimpleNamespace(conversation_id=conversation_id)
        target_message = SimpleNamespace(
            id=target_id,
            conversation_id=conversation_id,
            created_at=target_created_at,
        )
        older_messages_descending = [
            SimpleNamespace(
                id=UUID("00000000-0000-0000-0000-000000000102")
            ),
            SimpleNamespace(
                id=UUID("00000000-0000-0000-0000-000000000101")
            ),
            SimpleNamespace(
                id=UUID("00000000-0000-0000-0000-000000000100")
            ),
        ]
        newer_messages_ascending = [
            SimpleNamespace(
                id=UUID("00000000-0000-0000-0000-000000000104")
            ),
            SimpleNamespace(
                id=UUID("00000000-0000-0000-0000-000000000105")
            ),
            SimpleNamespace(
                id=UUID("00000000-0000-0000-0000-000000000106")
            ),
        ]
        session = SimpleNamespace(
            get=AsyncMock(return_value=other_user),
            scalar=AsyncMock(return_value=target_message),
            scalars=AsyncMock(
                side_effect=[
                    older_messages_descending,
                    newer_messages_ascending,
                ]
            ),
        )

        with (
            patch.object(
                message_routes,
                "get_direct_conversation",
                AsyncMock(return_value=direct_conversation),
            ),
            patch.object(
                message_routes,
                "build_message_reads",
                AsyncMock(
                    side_effect=lambda _session, messages, **_: messages
                ),
            ),
            patch.object(
                message_routes,
                "MessageContextRead",
                side_effect=lambda **values: SimpleNamespace(**values),
            ),
        ):
            result = await message_routes.get_conversation_message_context(
                other_user_id=other_user_id,
                message_id=target_id,
                current_user=current_user,
                session=session,
                older_limit=2,
                newer_limit=2,
            )

        self.assertEqual(
            result.messages,
            [
                older_messages_descending[1],
                older_messages_descending[0],
                target_message,
                newer_messages_ascending[0],
                newer_messages_ascending[1],
            ],
        )
        self.assertTrue(result.has_more_older)
        self.assertTrue(result.has_more_newer)


if __name__ == "__main__":
    unittest.main()
