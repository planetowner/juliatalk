import os
import unittest
from types import SimpleNamespace
from uuid import UUID


os.environ.setdefault(
    "DATABASE_URL",
    "postgresql+asyncpg://postgres:postgres@localhost:5432/juliatalk_test",
)

from app.models import CallOutcome, MessageKind
from app.notifications import (
    APNS_MAX_PAYLOAD_BYTES,
    _bounded_alert_payload,
    _encoded_payload_size,
    localized_message_body,
)
from app.schemas import DeviceRegistrationUpdate
from app.unread_counts import build_unread_counts_snapshot


class NotificationLocalizationTests(unittest.TestCase):
    def test_media_summaries_match_supported_languages(self) -> None:
        expected = {
            MessageKind.PHOTO: ("사진을 보냈습니다.", "照片"),
            MessageKind.VIDEO: ("동영상을 보냈습니다.", "视频"),
            MessageKind.VOICE_MEMO: ("음성메시지를 보냈습니다.", "语音备忘录"),
        }

        for message_kind, (korean, chinese) in expected.items():
            message = SimpleNamespace(kind=message_kind, body="")
            with self.subTest(message_kind=message_kind):
                self.assertEqual(
                    localized_message_body(
                        message,
                        recipient_language="ko",
                        call_event=None,
                    ),
                    korean,
                )
                self.assertEqual(
                    localized_message_body(
                        message,
                        recipient_language="zh-CN",
                        call_event=None,
                    ),
                    chinese,
                )

    def test_file_summary_includes_file_name(self) -> None:
        message = SimpleNamespace(kind=MessageKind.FILE, body="")

        self.assertEqual(
            localized_message_body(
                message,
                recipient_language="ko",
                call_event=None,
                file_name="Day 01 관계.pdf",
            ),
            "파일: Day 01 관계.pdf",
        )
        self.assertEqual(
            localized_message_body(
                message,
                recipient_language="zh-CN",
                call_event=None,
                file_name="Day 01 관계.pdf",
            ),
            "文件: Day 01 관계.pdf",
        )

    def test_missed_call_summary_is_localized(self) -> None:
        message = SimpleNamespace(kind=MessageKind.CALL, body="")
        call_event = SimpleNamespace(outcome=CallOutcome.MISSED)

        self.assertEqual(
            localized_message_body(
                message,
                recipient_language="ko",
                call_event=call_event,
            ),
            "부재중 보이스톡",
        )
        self.assertEqual(
            localized_message_body(
                message,
                recipient_language="zh-CN",
                call_event=call_event,
            ),
            "未接听语音通话",
        )


class NotificationPayloadTests(unittest.TestCase):
    def test_alert_payload_is_bounded_to_apns_limit(self) -> None:
        payload = {
            "aps": {
                "alert": {"title": "june", "body": "긴 메시지" * 3000},
                "mutable-content": 1,
            },
            "juliatalk": {
                "sender_id": "sender-id",
                "sender_image_url": "https://example.com/" + "a" * 5000,
                "photo_url": "https://example.com/" + "b" * 5000,
            },
        }

        bounded = _bounded_alert_payload(payload)

        self.assertLessEqual(
            _encoded_payload_size(bounded),
            APNS_MAX_PAYLOAD_BYTES,
        )

    def test_explicit_null_can_clear_last_voip_token(self) -> None:
        registration = DeviceRegistrationUpdate.model_validate(
            {
                "installation_id": "device-id",
                "platform": "ios",
                "voip_push_token": None,
                "app_bundle_id": "com.planetowner.juliatalk",
                "apns_environment": "development",
            }
        )

        self.assertIsNone(registration.voip_push_token)
        self.assertIn("voip_push_token", registration.model_fields_set)

    def test_unread_snapshot_contains_authoritative_counts(self) -> None:
        user_id = UUID("00000000-0000-0000-0000-000000000001")
        first_sender_id = UUID("00000000-0000-0000-0000-000000000002")
        second_sender_id = UUID("00000000-0000-0000-0000-000000000003")
        message_id = UUID("00000000-0000-0000-0000-000000000004")

        snapshot = build_unread_counts_snapshot(
            user_id=user_id,
            counts_by_sender_id={
                first_sender_id: 2,
                second_sender_id: 3,
            },
            stream_id="test-stream",
            sequence=7,
            cause_message_id=message_id,
        )

        self.assertEqual(snapshot["user_id"], str(user_id))
        self.assertEqual(snapshot["stream_id"], "test-stream")
        self.assertEqual(snapshot["sequence"], 7)
        self.assertEqual(
            snapshot["counts_by_sender_id"],
            {
                str(first_sender_id): 2,
                str(second_sender_id): 3,
            },
        )
        self.assertEqual(snapshot["total_unread_count"], 5)
        self.assertEqual(snapshot["cause_message_id"], str(message_id))


if __name__ == "__main__":
    unittest.main()
