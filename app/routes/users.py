from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_session
from app.dependencies import get_current_user
from app.models import User
from app.schemas import (
    DisplayNameUpdate,
    PasswordChangeRequest,
    UserRead,
)
from app.passwords import hash_password, verify_password


router = APIRouter(
    prefix="/users",
    tags=["users"],
)

SessionDependency = Annotated[
    AsyncSession,
    Depends(get_session),
]

CurrentUserDependency = Annotated[
    User,
    Depends(get_current_user),
]


@router.get(
    "/me",
    response_model=UserRead,
)
async def read_current_user(
    current_user: CurrentUserDependency,
) -> User:
    return current_user


@router.patch(
    "/me/display-name",
    response_model=UserRead,
)
async def update_display_name(
    display_name_data: DisplayNameUpdate,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> User:
    current_user.display_name = display_name_data.display_name

    await session.commit()
    await session.refresh(current_user)

    return current_user


@router.patch(
    "/me/password",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def change_password(
    password_data: PasswordChangeRequest,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> None:
    if not verify_password(
        password_data.current_password,
        current_user.password_hash,
    ):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Current password is incorrect",
        )

    if verify_password(
        password_data.new_password,
        current_user.password_hash,
    ):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="New password must be different from current password",
        )

    current_user.password_hash = hash_password(
        password_data.new_password
    )

    current_user.token_version += 1

    await session.commit()


@router.get(
    "",
    response_model=list[UserRead],
)
async def list_users(
    session: SessionDependency,
    current_user: CurrentUserDependency,
) -> list[User]:
    result = await session.scalars(
        select(User).order_by(User.id)
    )

    return list(result)
