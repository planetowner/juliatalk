from datetime import datetime, timezone
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_session
from app.dependencies import get_current_user
from app.models import DevicePlatform, User, UserDevice
from app.schemas import DeviceRegistrationRead, DeviceRegistrationUpdate


router = APIRouter(prefix="/devices", tags=["devices"])

SessionDependency = Annotated[AsyncSession, Depends(get_session)]
CurrentUserDependency = Annotated[User, Depends(get_current_user)]


@router.put(
    "/current",
    response_model=DeviceRegistrationRead,
)
async def register_current_device(
    registration: DeviceRegistrationUpdate,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> UserDevice:
    conditions = [
        (
            (UserDevice.user_id == current_user.id)
            & (UserDevice.installation_id == registration.installation_id)
            & UserDevice.revoked_at.is_(None)
        )
    ]

    if registration.push_token is not None:
        conditions.append(
            (UserDevice.push_token == registration.push_token)
            & UserDevice.revoked_at.is_(None)
        )

    if registration.voip_push_token is not None:
        conditions.append(
            (UserDevice.voip_push_token == registration.voip_push_token)
            & UserDevice.revoked_at.is_(None)
        )

    result = await session.scalars(
        select(UserDevice).where(or_(*conditions))
    )
    matching_devices = list(result)
    device = next(
        (
            item
            for item in matching_devices
            if item.user_id == current_user.id
            and item.installation_id == registration.installation_id
        ),
        matching_devices[0] if matching_devices else None,
    )
    now = datetime.now(timezone.utc)

    if device is None:
        if (
            registration.push_token is None
            and registration.voip_push_token is None
        ):
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail="Registered device not found",
            )

        device = UserDevice(
            user_id=current_user.id,
            platform=DevicePlatform.IOS,
            installation_id=registration.installation_id,
        )
        session.add(device)

    for duplicate in matching_devices:
        if duplicate is device:
            continue

        duplicate.push_token = None
        duplicate.voip_push_token = None
        duplicate.revoked_at = now

    device.user_id = current_user.id
    device.platform = DevicePlatform.IOS
    device.installation_id = registration.installation_id

    if "push_token" in registration.model_fields_set:
        device.push_token = registration.push_token

    if "voip_push_token" in registration.model_fields_set:
        device.voip_push_token = registration.voip_push_token

    device.app_bundle_id = registration.app_bundle_id
    device.apns_environment = registration.apns_environment
    device.device_name = registration.device_name
    device.last_seen_at = now
    device.revoked_at = (
        now
        if device.push_token is None and device.voip_push_token is None
        else None
    )

    await session.commit()
    await session.refresh(device)
    return device


@router.delete(
    "/current/{installation_id}",
    status_code=status.HTTP_204_NO_CONTENT,
)
async def revoke_current_device(
    installation_id: str,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> Response:
    device = await session.scalar(
        select(UserDevice).where(
            UserDevice.user_id == current_user.id,
            UserDevice.installation_id == installation_id,
            UserDevice.revoked_at.is_(None),
        )
    )

    if device is not None:
        device.push_token = None
        device.voip_push_token = None
        device.revoked_at = datetime.now(timezone.utc)
        await session.commit()

    return Response(status_code=status.HTTP_204_NO_CONTENT)
