from datetime import datetime, timedelta, timezone
from pathlib import Path

import jwt
from jwt.exceptions import InvalidTokenError
from pwdlib import PasswordHash


JWT_SECRET_PATH = (
    Path(__file__).resolve().parent.parent / ".jwt_secret"
)

JWT_ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_DAYS = 30

password_hash = PasswordHash.recommended()


def load_jwt_secret() -> str:
    if not JWT_SECRET_PATH.exists():
        raise RuntimeError(
            f"JWT secret file not found: {JWT_SECRET_PATH}"
        )

    secret = JWT_SECRET_PATH.read_text(
        encoding="utf-8"
    ).strip()

    if not secret:
        raise RuntimeError("JWT secret file is empty.")

    return secret


JWT_SECRET = load_jwt_secret()


def hash_password(password: str) -> str:
    return password_hash.hash(password)


def verify_password(
    password: str,
    stored_password_hash: str,
) -> bool:
    return password_hash.verify(
        password,
        stored_password_hash,
    )


def create_access_token(
    user_id: int,
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
) -> tuple[int, int]:
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
        user_id = int(subject)
    except ValueError as error:
        raise ValueError(
            "Access token contains an invalid user ID."
        ) from error

    if user_id <= 0:
        raise ValueError(
            "Access token contains an invalid user ID."
        )

    if not isinstance(token_version, int):
        raise ValueError(
            "Access token does not contain a valid token version."
        )

    if token_version < 0:
        raise ValueError(
            "Access token contains an invalid token version."
        )

    return user_id, token_version