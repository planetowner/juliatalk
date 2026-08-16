from __future__ import annotations

import asyncio
import logging
import mimetypes
from pathlib import PurePosixPath
from time import perf_counter
from typing import Any, Literal, Optional
from uuid import UUID, uuid4

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.dependencies import CurrentUserDependency, SessionDependency
from app.media_metadata import normalize_waveform_samples
from app.models import (
    DirectConversation,
    MediaAsset,
    MediaKind,
    Message,
    MessageAttachment,
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


logger = logging.getLogger(__name__)


router = APIRouter(
    prefix="/media-assets",
    tags=["media-assets"],
)


def _safe_file_name(file_name: Optional[str], mime_type: str) -> str:
    # 저장 키에 사용자가 보낸 디렉터리 경로가 섞이지 않게 마지막 파일명만 써요.
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


def _thumbnail_storage_key(*, user_id: UUID, media_asset_id: UUID) -> str:
    return f"users/{user_id}/media/{media_asset_id}/thumbnail/chat.jpg"


def _metadata_for_storage(
    *,
    kind: str,
    metadata: Optional[dict[str, Any]],
) -> dict[str, Any]:
    if kind != "voice_memo":
        return {}

    waveform_samples = normalize_waveform_samples(metadata)

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
    thumbnail_storage_key = (
        _thumbnail_storage_key(
            user_id=current_user.id,
            media_asset_id=media_asset_id,
        )
        if media_data.kind == "photo"
        else None
    )

    try:
        object_storage = get_object_storage_client()
        upload_url = object_storage.presigned_put_url(
            storage_key=storage_key,
            content_type=media_data.mime_type,
        )
        thumbnail_upload_url = (
            object_storage.presigned_put_url(
                storage_key=thumbnail_storage_key,
                content_type="image/jpeg",
            )
            if thumbnail_storage_key is not None
            else None
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
        thumbnail_storage_key=thumbnail_storage_key,
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
        thumbnail_upload_url=thumbnail_upload_url,
        thumbnail_upload_headers=(
            {"Content-Type": "image/jpeg"}
            if thumbnail_upload_url is not None
            else None
        ),
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

    measure_photo = media_asset.kind == MediaKind.PHOTO

    try:
        object_storage = get_object_storage_client()
    except RuntimeError as error:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(error),
        ) from error

    metadata_futures = [
        asyncio.to_thread(
            object_storage.object_metadata,
            storage_key=media_asset.storage_key,
        )
    ]

    if media_asset.thumbnail_storage_key is not None:
        metadata_futures.append(
            asyncio.to_thread(
                object_storage.object_metadata,
                storage_key=media_asset.thumbnail_storage_key,
            )
        )

    metadata_started_at = perf_counter()
    metadata_results = await asyncio.gather(
        *metadata_futures,
        return_exceptions=True,
    )

    if measure_photo:
        logger.info(
            "photo_send_timing stage=storage_metadata elapsed_ms=%.1f "
            "original_bytes=%d has_preview=%s",
            (perf_counter() - metadata_started_at) * 1000,
            media_asset.size_bytes,
            media_asset.thumbnail_storage_key is not None,
        )

    metadata = metadata_results[0]

    if isinstance(metadata, FileNotFoundError):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Media upload has not reached Object Storage",
        ) from metadata

    if isinstance(metadata, RuntimeError):
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(metadata),
        ) from metadata

    if isinstance(metadata, BaseException):
        raise metadata

    object_size = metadata.get("ContentLength")

    if isinstance(object_size, int) and object_size != media_asset.size_bytes:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Uploaded media size does not match metadata",
        )

    if media_asset.thumbnail_storage_key is not None:
        thumbnail_metadata = metadata_results[1]

        if isinstance(thumbnail_metadata, FileNotFoundError):
            # 이전 앱이 썸네일 URL을 사용하지 않아도 원본 업로드는 마칠 수 있어요.
            media_asset.thumbnail_storage_key = None
        elif isinstance(thumbnail_metadata, RuntimeError):
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=str(thumbnail_metadata),
            ) from thumbnail_metadata
        elif isinstance(thumbnail_metadata, BaseException):
            raise thumbnail_metadata

    media_asset.upload_status = "complete"
    commit_started_at = perf_counter()
    await session.commit()

    if measure_photo:
        logger.info(
            "photo_send_timing stage=asset_commit elapsed_ms=%.1f "
            "original_bytes=%d",
            (perf_counter() - commit_started_at) * 1000,
            media_asset.size_bytes,
        )

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
    variant: Literal["original", "thumbnail"] = "original",
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
        # 자산 존재 여부가 노출되지 않도록 권한이 없어도 찾지 못한 것처럼 응답해요.
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Media asset not found",
        )

    if media_asset.upload_status != "complete" or media_asset.storage_key is None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Media asset is not available",
        )

    storage_key = (
        media_asset.thumbnail_storage_key
        if variant == "thumbnail" and media_asset.thumbnail_storage_key is not None
        else media_asset.storage_key
    )

    try:
        object_storage = get_object_storage_client()
        access_url = object_storage.presigned_get_url(
            storage_key=storage_key,
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
        mime_type=(
            "image/jpeg"
            if storage_key == media_asset.thumbnail_storage_key
            else media_asset.mime_type
        ),
        file_name=media_asset.file_name,
        size_bytes=media_asset.size_bytes,
    )
