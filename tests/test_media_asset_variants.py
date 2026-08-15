import asyncio
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from uuid import uuid4

from app.routes import media_assets
from app.schemas import MediaAssetUploadCreate


class _FakeObjectStorage:
    def __init__(self) -> None:
        self.get_storage_keys: list[str] = []

    def presigned_put_url(self, *, storage_key: str, content_type: str) -> str:
        return f"https://storage.example.com/put/{storage_key}?type={content_type}"

    def presigned_get_url(self, *, storage_key: str) -> str:
        self.get_storage_keys.append(storage_key)
        return f"https://storage.example.com/get/{storage_key}"


class _FakeSession:
    def __init__(self, asset=None) -> None:
        self.asset = asset
        self.added = []

    def add(self, value) -> None:
        self.added.append(value)

    async def commit(self) -> None:
        return None

    async def get(self, model, media_asset_id):
        return self.asset


class MediaAssetVariantTests(unittest.TestCase):
    def test_photo_upload_prepares_original_and_chat_thumbnail(self) -> None:
        storage = _FakeObjectStorage()
        session = _FakeSession()
        current_user = SimpleNamespace(id=uuid4())

        with patch.object(
            media_assets,
            "get_object_storage_client",
            return_value=storage,
        ):
            result = asyncio.run(
                media_assets.create_media_asset_upload(
                    MediaAssetUploadCreate(
                        kind="photo",
                        file_name="photo.jpg",
                        mime_type="image/jpeg",
                        size_bytes=3,
                        width=1200,
                        height=900,
                    ),
                    current_user,
                    session,
                )
            )

        asset = session.added[0]
        self.assertIsNotNone(result.thumbnail_upload_url)
        self.assertEqual(
            result.thumbnail_upload_headers,
            {"Content-Type": "image/jpeg"},
        )
        self.assertTrue(
            asset.thumbnail_storage_key.endswith("/thumbnail/chat.jpg")
        )

    def test_thumbnail_access_uses_thumbnail_and_falls_back_to_original(
        self,
    ) -> None:
        storage = _FakeObjectStorage()
        owner_id = uuid4()
        asset_id = uuid4()
        asset = SimpleNamespace(
            id=asset_id,
            owner_user_id=owner_id,
            upload_status="complete",
            storage_key="media/original.jpg",
            thumbnail_storage_key="media/thumbnail/chat.jpg",
            mime_type="image/heic",
            file_name="original.heic",
            size_bytes=30,
        )
        session = _FakeSession(asset)
        current_user = SimpleNamespace(id=owner_id)

        with patch.object(
            media_assets,
            "get_object_storage_client",
            return_value=storage,
        ):
            thumbnail_result = asyncio.run(
                media_assets.create_media_asset_access_url(
                    asset_id,
                    current_user,
                    session,
                    variant="thumbnail",
                )
            )
            asset.thumbnail_storage_key = None
            fallback_result = asyncio.run(
                media_assets.create_media_asset_access_url(
                    asset_id,
                    current_user,
                    session,
                    variant="thumbnail",
                )
            )

        self.assertEqual(
            storage.get_storage_keys,
            ["media/thumbnail/chat.jpg", "media/original.jpg"],
        )
        self.assertEqual(thumbnail_result.mime_type, "image/jpeg")
        self.assertEqual(fallback_result.mime_type, "image/heic")
