from __future__ import annotations

import os
from dataclasses import dataclass

import boto3
from botocore.client import Config
from botocore.exceptions import ClientError


DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS = 900


@dataclass(frozen=True)
class ObjectStorageSettings:
    bucket: str
    endpoint_url: str | None
    region_name: str
    addressing_style: str
    access_key_id: str
    secret_access_key: str


def _first_env(*names: str) -> str | None:
    for name in names:
        value = os.getenv(name)

        if value is not None and value.strip():
            return value.strip()

    return None


def load_object_storage_settings() -> ObjectStorageSettings:
    bucket = _first_env(
        "RAILWAY_OBJECT_STORAGE_BUCKET",
        "OBJECT_STORAGE_BUCKET",
        "AWS_S3_BUCKET",
        "S3_BUCKET",
        "BUCKET_NAME",
    )
    access_key_id = _first_env(
        "RAILWAY_OBJECT_STORAGE_ACCESS_KEY_ID",
        "OBJECT_STORAGE_ACCESS_KEY_ID",
        "OBJECT_STORAGE_ACCESS_KEY",
        "AWS_ACCESS_KEY_ID",
        "S3_ACCESS_KEY_ID",
        "S3_ACCESS_KEY",
    )
    secret_access_key = _first_env(
        "RAILWAY_OBJECT_STORAGE_SECRET_ACCESS_KEY",
        "OBJECT_STORAGE_SECRET_ACCESS_KEY",
        "OBJECT_STORAGE_SECRET_KEY",
        "AWS_SECRET_ACCESS_KEY",
        "S3_SECRET_ACCESS_KEY",
        "S3_SECRET_KEY",
    )

    missing = [
        name
        for name, value in (
            ("OBJECT_STORAGE_BUCKET", bucket),
            ("OBJECT_STORAGE_ACCESS_KEY_ID", access_key_id),
            ("OBJECT_STORAGE_SECRET_ACCESS_KEY", secret_access_key),
        )
        if value is None
    ]

    if missing:
        raise RuntimeError(
            "Object Storage is not configured. Missing: "
            + ", ".join(missing)
        )

    return ObjectStorageSettings(
        bucket=bucket,
        endpoint_url=_first_env(
            "RAILWAY_OBJECT_STORAGE_ENDPOINT_URL",
            "OBJECT_STORAGE_ENDPOINT_URL",
            "AWS_ENDPOINT_URL_S3",
            "S3_ENDPOINT_URL",
        ),
        region_name=_first_env(
            "RAILWAY_OBJECT_STORAGE_REGION",
            "OBJECT_STORAGE_REGION",
            "AWS_REGION",
            "S3_REGION",
        )
        or "auto",
        addressing_style=_first_env(
            "RAILWAY_OBJECT_STORAGE_ADDRESSING_STYLE",
            "OBJECT_STORAGE_ADDRESSING_STYLE",
            "S3_ADDRESSING_STYLE",
        )
        or "path",
        access_key_id=access_key_id,
        secret_access_key=secret_access_key,
    )


class ObjectStorageClient:
    def __init__(self, settings: ObjectStorageSettings) -> None:
        self._settings = settings
        self._client = boto3.client(
            "s3",
            endpoint_url=settings.endpoint_url,
            region_name=settings.region_name,
            aws_access_key_id=settings.access_key_id,
            aws_secret_access_key=settings.secret_access_key,
            config=Config(
                signature_version="s3v4",
                s3={"addressing_style": settings.addressing_style},
            ),
        )

    @property
    def bucket(self) -> str:
        return self._settings.bucket

    def presigned_put_url(
        self,
        *,
        storage_key: str,
        content_type: str,
        expires_in: int = DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS,
    ) -> str:
        return self._client.generate_presigned_url(
            "put_object",
            Params={
                "Bucket": self.bucket,
                "Key": storage_key,
                "ContentType": content_type,
            },
            ExpiresIn=expires_in,
        )

    def presigned_get_url(
        self,
        *,
        storage_key: str,
        expires_in: int = DEFAULT_PRESIGNED_URL_EXPIRES_SECONDS,
    ) -> str:
        return self._client.generate_presigned_url(
            "get_object",
            Params={
                "Bucket": self.bucket,
                "Key": storage_key,
            },
            ExpiresIn=expires_in,
        )

    def object_metadata(self, *, storage_key: str) -> dict[str, object]:
        try:
            return self._client.head_object(
                Bucket=self.bucket,
                Key=storage_key,
            )
        except ClientError as error:
            status_code = error.response.get("ResponseMetadata", {}).get(
                "HTTPStatusCode"
            )
            error_code = error.response.get("Error", {}).get("Code")

            if status_code == 404 or error_code in {"404", "NoSuchKey"}:
                raise FileNotFoundError(storage_key) from error

            raise


_object_storage_client: ObjectStorageClient | None = None


def get_object_storage_client() -> ObjectStorageClient:
    global _object_storage_client

    if _object_storage_client is None:
        _object_storage_client = ObjectStorageClient(
            load_object_storage_settings()
        )

    return _object_storage_client
