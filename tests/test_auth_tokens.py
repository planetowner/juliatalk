from __future__ import annotations

import os
import unittest
from uuid import UUID

import jwt
from fastapi import HTTPException


os.environ.setdefault(
    "DATABASE_URL",
    "postgresql+asyncpg://postgres:postgres@localhost:5432/juliatalk_test",
)
os.environ.setdefault(
    "JWT_SECRET",
    "test-jwt-secret-with-at-least-32-bytes",
)

from app.models import User
from app.routes.auth import refresh_session
from app.schemas import RefreshTokenRequest
from app.security import (
    JWT_ALGORITHM,
    JWT_SECRET,
    create_access_token,
    create_refresh_token,
    decode_access_token,
    decode_refresh_token,
)


class _FakeSession:
    def __init__(self, user: User) -> None:
        self.user = user

    async def get(self, model: type[User], user_id: UUID) -> User | None:
        if model is User and self.user.id == user_id:
            return self.user

        return None


class AuthenticationTokenTests(unittest.TestCase):
    user_id = UUID("11111111-1111-4111-8111-111111111111")

    def test_access_and_refresh_tokens_are_not_interchangeable(self) -> None:
        access_token = create_access_token(self.user_id, token_version=3)
        refresh_token = create_refresh_token(self.user_id, token_version=3)

        self.assertEqual(
            decode_access_token(access_token),
            (self.user_id, 3),
        )
        self.assertEqual(
            decode_refresh_token(refresh_token),
            (self.user_id, 3),
        )

        with self.assertRaises(ValueError):
            decode_access_token(refresh_token)

        with self.assertRaises(ValueError):
            decode_refresh_token(access_token)

    def test_refresh_token_has_no_time_expiration(self) -> None:
        refresh_token = create_refresh_token(self.user_id, token_version=0)

        payload = jwt.decode(
            refresh_token,
            JWT_SECRET,
            algorithms=[JWT_ALGORITHM],
        )

        self.assertNotIn("exp", payload)
        self.assertEqual(payload["token_kind"], "refresh")


class RefreshSessionTests(unittest.IsolatedAsyncioTestCase):
    user_id = UUID("11111111-1111-4111-8111-111111111111")

    def _user(self, *, token_version: int) -> User:
        return User(
            id=self.user_id,
            username="test-user",
            display_name="June",
            password_hash="unused",
            preferred_language="ko",
            token_version=token_version,
        )

    async def test_refresh_returns_a_new_complete_token_pair(self) -> None:
        user = self._user(token_version=2)
        refresh_token = create_refresh_token(
            self.user_id,
            token_version=2,
        )

        response = await refresh_session(
            RefreshTokenRequest(refresh_token=refresh_token),
            _FakeSession(user),
        )

        self.assertEqual(
            decode_access_token(response.access_token),
            (self.user_id, 2),
        )
        self.assertEqual(
            decode_refresh_token(response.refresh_token),
            (self.user_id, 2),
        )
        self.assertEqual(response.user.id, self.user_id)

    async def test_password_change_invalidates_the_refresh_token(self) -> None:
        user = self._user(token_version=3)
        old_refresh_token = create_refresh_token(
            self.user_id,
            token_version=2,
        )

        with self.assertRaises(HTTPException) as context:
            await refresh_session(
                RefreshTokenRequest(refresh_token=old_refresh_token),
                _FakeSession(user),
            )

        self.assertEqual(context.exception.status_code, 401)


if __name__ == "__main__":
    unittest.main()
