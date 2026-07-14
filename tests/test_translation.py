import os
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch


os.environ.setdefault("OPENAI_API_KEY", "test-openai-api-key")
os.environ.setdefault("OPENAI_MODEL", "gpt-5.6-terra")

from app import translation


class TranslationTests(unittest.IsolatedAsyncioTestCase):
    async def test_translate_message_uses_openai_responses_api(self) -> None:
        create_response = AsyncMock(
            return_value=SimpleNamespace(output_text="안녕하세요")
        )

        with patch.object(
            translation.openai_client.responses,
            "create",
            create_response,
        ):
            result = await translation.translate_message(
                "你好",
                source_language="zh-CN",
                target_language="ko",
                context_messages=("你今天好吗？",),
            )

        self.assertEqual(result.translated_text, "안녕하세요")
        self.assertEqual(result.provider, "openai")
        self.assertEqual(result.model, translation.TRANSLATION_MODEL)

        create_response.assert_awaited_once()
        request = create_response.await_args.kwargs
        self.assertEqual(request["model"], translation.TRANSLATION_MODEL)
        self.assertEqual(request["reasoning"], {"effort": "none"})
        self.assertEqual(request["instructions"], translation.build_system_prompt())
        self.assertIn("你好", request["input"])
        self.assertFalse(request["store"])

    async def test_translate_message_rejects_empty_openai_output(self) -> None:
        create_response = AsyncMock(
            return_value=SimpleNamespace(output_text="   ")
        )

        with patch.object(
            translation.openai_client.responses,
            "create",
            create_response,
        ):
            with self.assertRaisesRegex(
                RuntimeError,
                "OpenAI returned an empty translation",
            ):
                await translation.translate_message(
                    "你好",
                    source_language="zh-CN",
                    target_language="ko",
                )

    async def test_same_language_skips_openai_request(self) -> None:
        create_response = AsyncMock()

        with patch.object(
            translation.openai_client.responses,
            "create",
            create_response,
        ):
            result = await translation.translate_message(
                "안녕하세요",
                source_language="ko",
                target_language="ko",
            )

        self.assertEqual(result.translated_text, "안녕하세요")
        create_response.assert_not_awaited()

    async def test_english_skips_openai_for_both_languages(self) -> None:
        for source_language, target_language in (
            ("ko", "zh-CN"),
            ("zh-CN", "ko"),
        ):
            with self.subTest(target_language=target_language):
                create_response = AsyncMock()

                with patch.object(
                    translation.openai_client.responses,
                    "create",
                    create_response,
                ):
                    result = await translation.translate_message(
                        "Hello, how are you? 123 😊",
                        source_language=source_language,
                        target_language=target_language,
                    )

                self.assertEqual(
                    result.translated_text,
                    "Hello, how are you? 123 😊",
                )
                create_response.assert_not_awaited()

    def test_mixed_text_uses_korean_or_chinese_script(self) -> None:
        self.assertTrue(
            translation.should_translate_text(
                "Hello 안녕하세요",
                source_language="ko",
                target_language="zh-CN",
            )
        )
        self.assertTrue(
            translation.should_translate_text(
                "Hello 你好",
                source_language="zh-CN",
                target_language="ko",
            )
        )


if __name__ == "__main__":
    unittest.main()
