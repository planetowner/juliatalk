from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select

from app.dependencies import SessionDependency, get_user_for_token
from app.models import User
from app.schemas import (
    LoginRequest,
    RefreshTokenRequest,
    TokenResponse,
    UserRead,
)
from app.passwords import verify_password
from app.security import (
    create_access_token,
    create_refresh_token,
    decode_refresh_token,
)


router = APIRouter(
    prefix="/auth",
    tags=["auth"],
)


def _token_response(user: User) -> TokenResponse:
    return TokenResponse(
        access_token=create_access_token(
            user_id=user.id,
            token_version=user.token_version,
        ),
        refresh_token=create_refresh_token(
            user_id=user.id,
            token_version=user.token_version,
        ),
        token_type="bearer",
        user=UserRead.model_validate(user),
    )


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

    return _token_response(user)


@router.post(
    "/refresh",
    response_model=TokenResponse,
)
async def refresh_session(
    refresh_data: RefreshTokenRequest,
    session: SessionDependency,
) -> TokenResponse:
    authentication_error = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not refresh session",
        headers={"WWW-Authenticate": "Bearer"},
    )

    try:
        user_id, token_version = decode_refresh_token(
            refresh_data.refresh_token
        )
    except ValueError:
        raise authentication_error

    user = await get_user_for_token(
        session,
        user_id=user_id,
        token_version=token_version,
    )

    if user is None:
        raise authentication_error

    return _token_response(user)
