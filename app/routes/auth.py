from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_session
from app.models import User
from app.schemas import (
    LoginRequest,
    TokenResponse,
    UserRead,
)
from app.security import (
    create_access_token,
    verify_password,
)


router = APIRouter(
    prefix="/auth",
    tags=["auth"],
)

SessionDependency = Annotated[
    AsyncSession,
    Depends(get_session),
]


@router.post(
    "/login",
    response_model=TokenResponse,
)
async def login(
    login_data: LoginRequest,
    session: SessionDependency,
) -> TokenResponse:
    user = await session.scalar(
        select(User).where(
            User.username == login_data.username
        )
    )

    if user is None or not verify_password(
        login_data.password,
        user.password_hash,
    ):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid username or password",
            headers={
                "WWW-Authenticate": "Bearer",
            },
        )

    return TokenResponse(
        access_token=create_access_token(
            user_id=user.id,
            token_version=user.token_version,
        ),
        token_type="bearer",
        user=UserRead.model_validate(user),
    )