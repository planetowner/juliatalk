from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional
from uuid import UUID

import httpx
import jwt
from jwt.exceptions import PyJWTError
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import SessionLocal
from app.models import (
    CallOutcome,
    ConversationMember,
    DirectConversation,
    MediaAsset,
    Message,
    MessageAttachment,
    MessageCallEvent,
    MessageDeletion,
    MessageKind,
    MessageReadReceipt,
    User,
    UserDevice,
)
from app.object_storage import get_object_storage_client


logger = logging.getLogger(__name__)

APNS_DEVELOPMENT_HOST = "https://api.sandbox.push.apple.com"
APNS_PRODUCTION_HOST = "https://api.push.apple.com"
APNS_MAX_PAYLOAD_BYTES = 4096
APNS_ALERT_BODY_MAX_BYTES = 2200
INVALID_DEVICE_TOKEN_REASONS = {
    "BadDeviceToken",
    "DeviceTokenNotForTopic",
    "Unregistered",
}


@dataclass(frozen=True)
class APNSSettings:
    key_id: str
    team_id: str
    bundle_id: str
    private_key: str


@dataclass(frozen=True)
class APNSResult:
    succeeded: bool
    status_code: int
    reason: Optional[str] = None


def _environment_value(name: str) -> Optional[str]:
    value = os.getenv(name)
    if value is None:
        return None

    normalized = value.strip()
    return normalized or None


def load_apns_settings() -> Optional[APNSSettings]:
    key_id = _environment_value("APNS_KEY_ID")
    team_id = _environment_value("APNS_TEAM_ID")
    bundle_id = _environment_value("APNS_BUNDLE_ID")
    private_key = _environment_value("APNS_PRIVATE_KEY")
    private_key_path = _environment_value("APNS_PRIVATE_KEY_PATH")

    if private_key is not None:
        private_key = private_key.replace("\\n", "\n")
    elif private_key_path is not None:
        try:
            private_key = Path(private_key_path).expanduser().read_text(
                encoding="utf-8"
            )
        except OSError:
            logger.exception("Could not read APNs private key")
            return None

    if not all((key_id, team_id, bundle_id, private_key)):
        return None

    return APNSSettings(
        key_id=key_id,
        team_id=team_id,
        bundle_id=bundle_id,
        private_key=private_key,
    )


def _truncate_utf8(value: str, max_bytes: int) -> str:
    encoded = value.encode("utf-8")
    if len(encoded) <= max_bytes:
        return value

    ellipsis = "…".encode("utf-8")
    prefix = encoded[: max(0, max_bytes - len(ellipsis))]
    return prefix.decode("utf-8", errors="ignore").rstrip() + "…"


def _encoded_payload_size(payload: dict[str, Any]) -> int:
    return len(
        json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
    )


def _bounded_alert_payload(payload: dict[str, Any]) -> dict[str, Any]:
    alert = payload.get("aps", {}).get("alert")
    if not isinstance(alert, dict):
        return payload

    body = alert.get("body")
    if not isinstance(body, str):
        return payload

    alert["body"] = _truncate_utf8(body, APNS_ALERT_BODY_MAX_BYTES)
    payload_size = _encoded_payload_size(payload)

    if payload_size <= APNS_MAX_PAYLOAD_BYTES:
        return payload

    custom_data = payload.get("juliatalk")
    if isinstance(custom_data, dict):
        for optional_key in ("sender_image_url", "photo_url"):
            if _encoded_payload_size(payload) <= APNS_MAX_PAYLOAD_BYTES:
                break
            custom_data.pop(optional_key, None)

    payload_size = _encoded_payload_size(payload)
    if payload_size > APNS_MAX_PAYLOAD_BYTES:
        body_size = len(alert["body"].encode("utf-8"))
        overflow = payload_size - APNS_MAX_PAYLOAD_BYTES
        alert["body"] = _truncate_utf8(
            alert["body"],
            max(0, body_size - overflow - 16),
        )

    if _encoded_payload_size(payload) > APNS_MAX_PAYLOAD_BYTES:
        alert["body"] = ""

    return payload


class APNSClient:
    def __init__(self, settings: APNSSettings) -> None:
        self._settings = settings
        self._cached_provider_token: Optional[str] = None
        self._provider_token_created_at = 0.0

    @property
    def voip_topic(self) -> str:
        return f"{self._settings.bundle_id}.voip"

    def _provider_token(self) -> str:
        now = time.time()
        if (
            self._cached_provider_token is not None
            and now - self._provider_token_created_at < 50 * 60
        ):
            return self._cached_provider_token

        token = jwt.encode(
            {"iss": self._settings.team_id, "iat": int(now)},
            self._settings.private_key,
            algorithm="ES256",
            headers={"kid": self._settings.key_id},
        )
        self._cached_provider_token = token
        self._provider_token_created_at = now
        return token

    async def send(
        self,
        *,
        device_token: str,
        payload: dict[str, Any],
        environment: str,
        push_type: str,
        topic: str,
        expiration: int,
    ) -> APNSResult:
        host = (
            APNS_PRODUCTION_HOST
            if environment == "production"
            else APNS_DEVELOPMENT_HOST
        )
        try:
            headers = {
                "authorization": f"bearer {self._provider_token()}",
                "apns-push-type": push_type,
                "apns-topic": topic,
                "apns-priority": "10",
                "apns-expiration": str(expiration),
            }
            async with httpx.AsyncClient(http2=True, timeout=10.0) as client:
                response = await client.post(
                    f"{host}/3/device/{device_token}",
                    headers=headers,
                    json=payload,
                )
        except (httpx.HTTPError, PyJWTError, ValueError):
            logger.exception("APNs request failed before receiving a response")
            return APNSResult(succeeded=False, status_code=0)

        reason = None
        if response.content:
            try:
                reason = response.json().get("reason")
            except (ValueError, AttributeError):
                reason = None

        if response.status_code != 200:
            logger.warning(
                "APNs rejected push: status=%s reason=%s",
                response.status_code,
                reason,
            )

        return APNSResult(
            succeeded=response.status_code == 200,
            status_code=response.status_code,
            reason=reason,
        )


def localized_message_body(
    message: Message,
    *,
    recipient_language: str,
    call_event: Optional[MessageCallEvent],
) -> Optional[str]:
    chinese = recipient_language == "zh-CN"

    if message.kind in {MessageKind.TEXT, MessageKind.LINK}:
        return message.body

    if message.kind == MessageKind.PHOTO:
        return "照片" if chinese else "사진을 보냈습니다."

    if message.kind == MessageKind.VIDEO:
        return "视频" if chinese else "동영상을 보냈습니다."

    if message.kind == MessageKind.VOICE_MEMO:
        return "语音备忘录" if chinese else "음성메시지를 보냈습니다."

    if message.kind == MessageKind.FILE:
        return "文件" if chinese else "파일을 보냈습니다."

    if message.kind == MessageKind.CALL and call_event is not None:
        if call_event.outcome in {CallOutcome.MISSED, CallOutcome.NO_ANSWER}:
            return "未接听语音通话" if chinese else "부재중 보이스톡"

    return None


async def _unread_count(session: AsyncSession, user_id: UUID) -> int:
    member_conversation_ids = select(
        ConversationMember.conversation_id
    ).where(ConversationMember.user_id == user_id)
    read_message_ids = select(MessageReadReceipt.message_id).where(
        MessageReadReceipt.user_id == user_id
    )
    hidden_message_ids = select(MessageDeletion.message_id).where(
        MessageDeletion.user_id == user_id
    )
    count = await session.scalar(
        select(func.count())
        .select_from(Message)
        .where(
            Message.conversation_id.in_(member_conversation_ids),
            Message.sender_id != user_id,
            Message.deleted_at.is_(None),
            Message.id.not_in(read_message_ids),
            Message.id.not_in(hidden_message_ids),
        )
    )
    return int(count or 0)


async def _photo_url(
    session: AsyncSession,
    message_id: UUID,
) -> Optional[str]:
    asset = await session.scalar(
        select(MediaAsset)
        .join(
            MessageAttachment,
            MessageAttachment.media_asset_id == MediaAsset.id,
        )
        .where(MessageAttachment.message_id == message_id)
        .order_by(MessageAttachment.position)
        .limit(1)
    )
    if asset is None:
        return None

    storage_key = asset.thumbnail_storage_key or asset.storage_key
    if storage_key is None:
        return None

    try:
        storage = get_object_storage_client()
        return await asyncio.to_thread(
            storage.presigned_get_url,
            storage_key=storage_key,
            expires_in=3600,
        )
    except RuntimeError:
        logger.exception("Could not create notification photo URL")
        return None


async def _revoke_invalid_token(
    session: AsyncSession,
    *,
    device: UserDevice,
    token_kind: str,
) -> None:
    if token_kind == "voip":
        device.voip_push_token = None
    else:
        device.push_token = None

    if device.push_token is None and device.voip_push_token is None:
        device.revoked_at = datetime.now(timezone.utc)


async def _send_voip_event(
    session: AsyncSession,
    *,
    client: APNSClient,
    message: Message,
    sender: User,
    recipient_id: UUID,
    call_event: MessageCallEvent,
) -> None:
    devices = list(
        await session.scalars(
            select(UserDevice).where(
                UserDevice.user_id == recipient_id,
                UserDevice.voip_push_token.is_not(None),
                UserDevice.revoked_at.is_(None),
            )
        )
    )
    payload = {
        "aps": {"content-available": 1},
        "juliatalk_call": {
            "action": "incoming",
            "call_uuid": str(message.id),
            "caller_id": str(sender.id),
            "caller_name": sender.display_name,
            "has_video": call_event.kind.value == "video",
        },
    }

    for device in devices:
        assert device.voip_push_token is not None
        result = await client.send(
            device_token=device.voip_push_token,
            payload=payload,
            environment=device.apns_environment,
            push_type="voip",
            topic=client.voip_topic,
            expiration=0,
        )
        if result.reason in INVALID_DEVICE_TOKEN_REASONS:
            await _revoke_invalid_token(
                session,
                device=device,
                token_kind="voip",
            )


async def send_message_notification(message_id: UUID) -> None:
    settings = load_apns_settings()
    if settings is None:
        logger.info("APNs is not configured; skipping message notification")
        return

    async with SessionLocal() as session:
        message = await session.get(Message, message_id)
        if message is None or message.deleted_at is not None:
            return

        direct_conversation = await session.get(
            DirectConversation,
            message.conversation_id,
        )
        sender = await session.get(User, message.sender_id)
        if direct_conversation is None or sender is None:
            return

        recipient_id = (
            direct_conversation.user_two_id
            if message.sender_id == direct_conversation.user_one_id
            else direct_conversation.user_one_id
        )
        recipient = await session.get(User, recipient_id)
        member = await session.get(
            ConversationMember,
            (message.conversation_id, recipient_id),
        )
        if recipient is None or member is None or member.left_at is not None:
            return

        now = datetime.now(timezone.utc)
        if member.muted_until is not None and member.muted_until > now:
            return

        call_event = await session.get(MessageCallEvent, message.id)
        client = APNSClient(settings)

        if (
            message.kind == MessageKind.CALL
            and call_event is not None
            and call_event.outcome == CallOutcome.STARTED
        ):
            await _send_voip_event(
                session,
                client=client,
                message=message,
                sender=sender,
                recipient_id=recipient_id,
                call_event=call_event,
            )
            await session.commit()
            return

        body = localized_message_body(
            message,
            recipient_language=recipient.preferred_language,
            call_event=call_event,
        )
        if body is None:
            return

        badge = await _unread_count(session, recipient_id)
        photo_url = (
            await _photo_url(session, message.id)
            if message.kind == MessageKind.PHOTO
            else None
        )
        custom_data: dict[str, Any] = {
            "message_id": str(message.id),
            "conversation_id": str(message.conversation_id),
            "sender_id": str(sender.id),
            "sender_name": sender.display_name,
            "sender_image_url": sender.profile_image_url,
            "message_type": message.kind.value,
            "language": recipient.preferred_language,
        }
        if photo_url is not None:
            custom_data["photo_url"] = photo_url

        payload = _bounded_alert_payload(
            {
                "aps": {
                    "alert": {
                        "title": sender.display_name,
                        "body": body,
                    },
                    "badge": badge,
                    "sound": "default",
                    "mutable-content": 1,
                    "thread-id": f"direct.{message.conversation_id}",
                    "category": (
                        "JULIATALK_PHOTO"
                        if message.kind == MessageKind.PHOTO
                        else "JULIATALK_REPLY"
                    ),
                    "interruption-level": "time-sensitive",
                },
                "juliatalk": custom_data,
            }
        )
        devices = list(
            await session.scalars(
                select(UserDevice).where(
                    UserDevice.user_id == recipient_id,
                    UserDevice.push_token.is_not(None),
                    UserDevice.revoked_at.is_(None),
                )
            )
        )

        for device in devices:
            assert device.push_token is not None
            result = await client.send(
                device_token=device.push_token,
                payload=payload,
                environment=device.apns_environment,
                push_type="alert",
                topic=settings.bundle_id,
                expiration=int(time.time()) + 24 * 60 * 60,
            )
            if result.reason in INVALID_DEVICE_TOKEN_REASONS:
                await _revoke_invalid_token(
                    session,
                    device=device,
                    token_kind="alert",
                )

        await session.commit()
