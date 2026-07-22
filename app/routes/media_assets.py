from __future__ import annotations

import asyncio
import math
import mimetypes
from pathlib import PurePosixPath
from typing import Annotated, Any, Optional
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_session
from app.dependencies import get_current_user
from app.models import (
    DirectConversation,
    MediaAsset,
    MediaKind,
    Message,
    MessageAttachment,
    User,
)
from app.object_storage import (
    DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS,
    get_object_storage_client,
)
from app.schemas import (
    MediaAssetAccessRead,
    MediaAssetCompleteRead,
    MediaAssetUploadCreate,
    MediaAssetUploadRead,
)


router = APIRouter(
    prefix="/media-assets",
    tags=["media-assets"],
)

SessionDependency = Annotated[
    AsyncSession,
    Depends(get_session),
]

CurrentUserDependency = Annotated[
    User,
    Depends(get_current_user),
]


def _safe_file_name(file_name: Optional[str], mime_type: str) -> str:
    candidate = PurePosixPath(file_name or "").name

    if candidate:
        return candidate

    extension = mimetypes.guess_extension(mime_type) or ".bin"

    return f"upload{extension}"


def _storage_key(
    *,
    user_id: UUID,
    media_asset_id: UUID,
    file_name: str,
) -> str:
    return f"users/{user_id}/media/{media_asset_id}/{file_name}"


def _normalized_waveform_samples(metadata: Optional[dict[str, Any]]) -> list[float]:
    if metadata is None:
        return []

    value = metadata.get("waveform_samples")

    if not isinstance(value, list):
        return []

    samples: list[float] = []

    for item in value[:80]:
        if isinstance(item, bool) or not isinstance(item, (int, float)):
            continue

        sample = float(item)

        if not math.isfinite(sample):
            continue

        samples.append(max(0.0, min(1.0, sample)))

    return samples


def _metadata_for_storage(
    *,
    kind: str,
    metadata: Optional[dict[str, Any]],
) -> dict[str, Any]:
    if kind != "voice_memo":
        return {}

    waveform_samples = _normalized_waveform_samples(metadata)

    if not waveform_samples:
        return {}

    return {"waveform_samples": waveform_samples}


async def _user_can_access_media_asset(
    session: AsyncSession,
    *,
    media_asset_id: UUID,
    user_id: UUID,
) -> bool:
    access_query = (
        select(Message.id)
        .join(
            MessageAttachment,
            MessageAttachment.message_id == Message.id,
        )
        .join(
            DirectConversation,
            DirectConversation.conversation_id == Message.conversation_id,
        )
        .where(
            MessageAttachment.media_asset_id == media_asset_id,
            or_(
                DirectConversation.user_one_id == user_id,
                DirectConversation.user_two_id == user_id,
            ),
            Message.deleted_at.is_(None),
        )
        .limit(1)
    )

    return await session.scalar(access_query) is not None


@router.post(
    "",
    response_model=MediaAssetUploadRead,
    status_code=status.HTTP_201_CREATED,
)
async def create_media_asset_upload(
    media_data: MediaAssetUploadCreate,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> MediaAssetUploadRead:
    media_asset_id = uuid4()
    file_name = _safe_file_name(media_data.file_name, media_data.mime_type)
    storage_key = _storage_key(
        user_id=current_user.id,
        media_asset_id=media_asset_id,
        file_name=file_name,
    )

    try:
        object_storage = get_object_storage_client()
        upload_url = object_storage.presigned_put_url(
            storage_key=storage_key,
            content_type=media_data.mime_type,
        )
    except RuntimeError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(error),
        ) from error

    media_asset = MediaAsset(
        id=media_asset_id,
        owner_user_id=current_user.id,
        kind=MediaKind(media_data.kind),
        storage_key=storage_key,
        file_name=file_name,
        mime_type=media_data.mime_type,
        size_bytes=media_data.size_bytes,
        width=media_data.width,
        height=media_data.height,
        duration_ms=media_data.duration_ms,
        metadata_json=_metadata_for_storage(
            kind=media_data.kind,
            metadata=media_data.metadata,
        ),
        upload_status="pending",
    )
    session.add(media_asset)
    await session.commit()

    return MediaAssetUploadRead(
        media_asset_id=media_asset_id,
        storage_key=storage_key,
        upload_url=upload_url,
        upload_headers={"Content-Type": media_data.mime_type},
        expires_in_seconds=DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS,
    )


@router.post(
    "/{media_asset_id}/complete",
    response_model=MediaAssetCompleteRead,
)
async def complete_media_asset_upload(
    media_asset_id: UUID,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> MediaAssetCompleteRead:
    media_asset = await session.get(MediaAsset, media_asset_id)

    if media_asset is None or media_asset.owner_user_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Media asset not found",
        )

    if media_asset.storage_key is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Media asset has no storage key",
        )

    try:
        object_storage = get_object_storage_client()
        metadata = await asyncio.to_thread(
            object_storage.object_metadata,
            storage_key=media_asset.storage_key,
        )
    except FileNotFoundError as error:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Media upload has not reached Object Storage",
        ) from error
    except RuntimeError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(error),
        ) from error

    object_size = metadata.get("ContentLength")

    if isinstance(object_size, int) and object_size != media_asset.size_bytes:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Uploaded media size does not match metadata",
        )

    media_asset.upload_status = "complete"
    await session.commit()

    return MediaAssetCompleteRead(
        media_asset_id=media_asset.id,
        upload_status=media_asset.upload_status,
    )


@router.get(
    "/{media_asset_id}/access",
    response_model=MediaAssetAccessRead,
)
async def create_media_asset_access_url(
    media_asset_id: UUID,
    current_user: CurrentUserDependency,
    session: SessionDependency,
) -> MediaAssetAccessRead:
    media_asset = await session.get(MediaAsset, media_asset_id)

    if media_asset is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Media asset not found",
        )

    can_access = media_asset.owner_user_id == current_user.id or (
        await _user_can_access_media_asset(
            session,
            media_asset_id=media_asset_id,
            user_id=current_user.id,
        )
    )

    if not can_access:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Media asset not found",
        )

    if media_asset.upload_status != "complete" or media_asset.storage_key is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Media asset is not available",
        )

    try:
        object_storage = get_object_storage_client()
        access_url = object_storage.presigned_get_url(
            storage_key=media_asset.storage_key,
        )
    except RuntimeError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(error),
        ) from error

    return MediaAssetAccessRead(
        media_asset_id=media_asset.id,
        access_url=access_url,
        expires_in_seconds=DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS,
        mime_type=media_asset.mime_type,
        file_name=media_asset.file_name,
        size_bytes=media_asset.size_bytes,
    )
