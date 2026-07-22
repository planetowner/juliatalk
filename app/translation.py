from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Sequence

from dotenv import load_dotenv
from openai import AsyncOpenAI


PROJECT_ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = PROJECT_ROOT / ".env"

load_dotenv(
    dotenv_path=ENV_PATH,
    override=False,
)


def required_environment_value(name: str) -> str:
    value = os.getenv(name)

    if value is None:
        raise RuntimeError(
            f"{name} is missing from the environment."
        )

    value = value.strip()

    if not value:
        raise RuntimeError(
            f"{name} is empty."
        )

    return value


OPENAI_API_KEY = required_environment_value(
    "OPENAI_API_KEY"
)

OPENAI_MODEL = os.getenv(
    "OPENAI_MODEL",
    "gpt-5.6-terra",
).strip()

if not OPENAI_MODEL:
    raise RuntimeError(
        "OPENAI_MODEL is empty."
    )

TRANSLATION_PROVIDER_NAME = "openai"
TRANSLATION_MODEL = OPENAI_MODEL

SUPPORTED_LANGUAGE_NAMES = {
    "ko": "한국어",
    "zh-CN": "중국어 간체",
}


openai_client = AsyncOpenAI(
    api_key=OPENAI_API_KEY,
    timeout=60.0,
    max_retries=2,
)


@dataclass(frozen=True)
class TranslationResult:
    translated_text: str
    source_language: str
    target_language: str
    provider: str
    model: str


def language_name(language_code: str) -> str:
    name = SUPPORTED_LANGUAGE_NAMES.get(language_code)

    if name is None:
        raise ValueError(
            f"Unsupported language code: {language_code}"
        )

    return name


def normalize_language_code(
    language_code: Optional[str],
) -> Optional[str]:
    normalized = (language_code or "").strip().replace(
        "_",
        "-",
    ).lower()

    if not normalized:
        return None

    if normalized == "ko" or normalized.startswith("ko-"):
        return "ko"

    if normalized == "zh" or normalized.startswith("zh-"):
        return "zh-CN"

    return normalized


def infer_text_language(text: str) -> Optional[str]:
    korean_count = 0
    chinese_count = 0

    for character in text:
        codepoint = ord(character)

        if (
            0xAC00 <= codepoint <= 0xD7AF
            or 0x1100 <= codepoint <= 0x11FF
            or 0x3130 <= codepoint <= 0x318F
        ):
            korean_count += 1
        elif (
            0x3400 <= codepoint <= 0x4DBF
            or 0x4E00 <= codepoint <= 0x9FFF
            or 0xF900 <= codepoint <= 0xFAFF
        ):
            chinese_count += 1

    if korean_count == 0 and chinese_count == 0:
        return None

    if korean_count >= chinese_count:
        return "ko"

    return "zh-CN"


def should_translate_text(
    text: str,
    *,
    source_language: Optional[str],
    target_language: Optional[str],
) -> bool:
    cleaned_text = text.strip()

    if not cleaned_text:
        return False

    normalized_target = normalize_language_code(target_language)
    inferred_language = infer_text_language(cleaned_text)

    # Only messages containing Hangul or Han characters are translated.
    # Latin-only text, numbers, punctuation, and emoji must pass through.
    if normalized_target is None or inferred_language is None:
        return False

    return inferred_language != normalized_target


def build_context_text(
    context_messages: Sequence[str],
) -> str:
    cleaned_messages = [
        message.strip()
        for message in context_messages
        if message.strip()
    ]

    if not cleaned_messages:
        return "제공된 이전 대화가 없다."

    numbered_messages = [
        f"{index}. {message}"
        for index, message in enumerate(
            cleaned_messages,
            start=1,
        )
    ]

    return "\n".join(numbered_messages)


def build_system_prompt() -> str:
    return (
        "너는 한국어와 중국어 간체 사이의 연인 메신저 대화를 "
        "번역하는 전문 번역가다.\n"
        "줄임말, 오타, 인터넷 은어, 비속어, 욕설, 반어법, "
        "짜증, 체념, 비꼼, 애교, 이모지와 문장 강도를 "
        "최대한 그대로 보존하라.\n"
        "욕설이나 거친 표현이 있으면 무조건 순화하지 말고, "
        "대상 언어에서 실제 연인이 사용할 법한 비슷한 강도의 "
        "자연스러운 표현으로 번역하라.\n"
        "다만 원문보다 더 심한 욕설이나 공격성을 추가하지 마라.\n"
        "이전 대화는 번역 대상 문장의 의미와 말투를 파악하는 "
        "참고 자료일 뿐이다.\n"
        "이전 대화를 다시 번역하거나 답장하지 마라.\n"
        "원문에 없는 사과, 설명, 감정 또는 정보를 추가하지 마라.\n"
        "번역에 대한 해설, 따옴표, 접두어 없이 번역문만 반환하라."
    )


async def translate_message(
    text: str,
    source_language: str,
    target_language: str,
    context_messages: Sequence[str] = (),
) -> TranslationResult:
    cleaned_text = text.strip()

    if not cleaned_text:
        raise ValueError(
            "Translation text cannot be blank."
        )

    source_language_name = language_name(
        source_language
    )
    target_language_name = language_name(
        target_language
    )

    if not should_translate_text(
        cleaned_text,
        source_language=source_language,
        target_language=target_language,
    ):
        return TranslationResult(
            translated_text=cleaned_text,
            source_language=source_language,
            target_language=target_language,
            provider=TRANSLATION_PROVIDER_NAME,
            model=TRANSLATION_MODEL,
        )

    context_text = build_context_text(
        context_messages
    )

    response = await openai_client.responses.create(
        model=TRANSLATION_MODEL,
        reasoning={"effort": "none"},
        instructions=build_system_prompt(),
        input=(
            f"원문 언어: {source_language_name}\n"
            f"번역 언어: {target_language_name}\n\n"
            "최근 대화 맥락:\n"
            f"{context_text}\n\n"
            "이번에 번역할 메시지:\n"
            f"{cleaned_text}"
        ),
        max_output_tokens=1000,
        store=False,
    )

    translated_text = response.output_text

    if (
        not isinstance(translated_text, str)
        or not translated_text.strip()
    ):
        raise RuntimeError(
            "OpenAI returned an empty translation."
        )

    return TranslationResult(
        translated_text=translated_text.strip(),
        source_language=source_language,
        target_language=target_language,
        provider=TRANSLATION_PROVIDER_NAME,
        model=TRANSLATION_MODEL,
    )
