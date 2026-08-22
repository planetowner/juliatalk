import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import UUID

import jwt
from jwt.exceptions import InvalidTokenError


JWT_SECRET_PATH = (
    Path(__file__).resolve().parent.parent / ".jwt_secret"
)

JWT_ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_DAYS = 30
ACCESS_TOKEN_KIND = "access"
REFRESH_TOKEN_KIND = "refresh"


def load_jwt_secret() -> str:
    environment_secret = os.getenv("JWT_SECRET")

    if environment_secret is not None:
        environment_secret = environment_secret.strip()

        if not environment_secret:
            raise RuntimeError(
                "JWT_SECRET environment variable is empty."
            )

        return environment_secret

    if not JWT_SECRET_PATH.exists():
        raise RuntimeError(
            "JWT secret was not found in the "
            "JWT_SECRET environment variable or file: "
            f"{JWT_SECRET_PATH}"
        )

    file_secret = JWT_SECRET_PATH.read_text(
        encoding="utf-8"
    ).strip()

    if not file_secret:
        raise RuntimeError(
            "JWT secret file is empty."
        )

    return file_secret


JWT_SECRET = load_jwt_secret()


def create_access_token(
    user_id: UUID,
    token_version: int,
) -> str:
    now = datetime.now(timezone.utc)

    payload = {
        "sub": str(user_id),
        "token_version": token_version,
        "token_kind": ACCESS_TOKEN_KIND,
        "iat": now,
        "exp": now + timedelta(
            days=ACCESS_TOKEN_EXPIRE_DAYS
        ),
    }

    return jwt.encode(
        payload,
        JWT_SECRET,
        algorithm=JWT_ALGORITHM,
    )


def create_refresh_token(
    user_id: UUID,
    token_version: int,
) -> str:
    now = datetime.now(timezone.utc)

    # 비밀번호를 바꿀 때 token_version으로 폐기하므로 갱신 토큰에는 시간 만료를 두지 않아요.
    payload = {
        "sub": str(user_id),
        "token_version": token_version,
        "token_kind": REFRESH_TOKEN_KIND,
        "iat": now,
    }

    return jwt.encode(
        payload,
        JWT_SECRET,
        algorithm=JWT_ALGORITHM,
    )


def _decode_token(
    token: str,
    *,
    expected_kind: str,
) -> tuple[UUID, int]:
    try:
        payload = jwt.decode(
            token,
            JWT_SECRET,
            algorithms=[JWT_ALGORITHM],
        )
    except InvalidTokenError as error:
        raise ValueError(
            "Invalid or expired access token."
        ) from error

    token_kind = payload.get("token_kind")
    if expected_kind == ACCESS_TOKEN_KIND:
        # token_kind 도입 전에 발급한 액세스 토큰도 남은 유효기간 동안 허용해요.
        if token_kind not in (None, ACCESS_TOKEN_KIND):
            raise ValueError("Token is not an access token.")
    elif token_kind != expected_kind:
        raise ValueError("Token has an unexpected kind.")

    subject = payload.get("sub")
    token_version = payload.get("token_version")

    if not isinstance(subject, str):
        raise ValueError(
            "Access token does not contain a valid user ID."
        )

    try:
        user_id = UUID(subject)
    except ValueError as error:
        raise ValueError(
            "Access token contains an invalid user ID."
        ) from error

    if not isinstance(token_version, int):
        raise ValueError(
            "Access token does not contain a valid token version."
        )

    if token_version < 0:
        raise ValueError(
            "Access token contains an invalid token version."
        )

    return user_id, token_version


def decode_access_token(
    token: str,
) -> tuple[UUID, int]:
    return _decode_token(
        token,
        expected_kind=ACCESS_TOKEN_KIND,
    )


def decode_refresh_token(
    token: str,
) -> tuple[UUID, int]:
    return _decode_token(
        token,
        expected_kind=REFRESH_TOKEN_KIND,
    )
