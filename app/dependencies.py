from __future__ import annotations

from typing import Annotated, Optional

from fastapi import Depends, HTTPException, status
from fastapi.security import (
    HTTPAuthorizationCredentials,
    HTTPBearer,
)
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_session
from app.models import User
from app.security import decode_access_token


bearer_scheme = HTTPBearer(auto_error=False)

SessionDependency = Annotated[
    AsyncSession,
    Depends(get_session),
]

CredentialsDependency = Annotated[
    Optional[HTTPAuthorizationCredentials],
    Depends(bearer_scheme),
]


async def get_current_user(
    credentials: CredentialsDependency,
    session: SessionDependency,
) -> User:
    authentication_error = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={
            "WWW-Authenticate": "Bearer",
        },
    )

    if credentials is None:
        raise authentication_error

    if credentials.scheme.lower() != "bearer":
        raise authentication_error

    try:
        user_id, token_version = decode_access_token(
            credentials.credentials
        )
    except ValueError:
        raise authentication_error

    user = await session.get(User, user_id)

    if user is None:
        raise authentication_error

    if user.token_version != token_version:
        raise authentication_error

    return user
