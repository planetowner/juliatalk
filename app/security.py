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


def decode_access_token(
    token: str,
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
