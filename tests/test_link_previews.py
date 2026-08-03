import io
import os
import unittest
from email.message import Message
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request


os.environ.setdefault(
    "DATABASE_URL",
    "postgresql+asyncpg://postgres:postgres@localhost:5432/juliatalk_test",
)
os.environ.setdefault("OPENAI_API_KEY", "test-openai-api-key")
os.environ.setdefault("JWT_SECRET", "test-jwt-secret")

from app.routes import messages as message_routes


class FakeHTTPResponse:
    def __init__(
        self,
        body: bytes,
        *,
        url: str,
        content_type: str = "text/html; charset=UTF-8",
    ) -> None:
        self._stream = io.BytesIO(body)
        self._url = url
        self.bytes_read = 0
        self.headers = Message()
        self.headers["Content-Type"] = content_type

    def __enter__(self) -> "FakeHTTPResponse":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def geturl(self) -> str:
        return self._url

    def read(self, size: int = -1) -> bytes:
        chunk = self._stream.read(size)
        self.bytes_read += len(chunk)
        return chunk


class LinkPreviewMetadataTests(unittest.TestCase):
    def test_kakao_scraper_headers_receive_page_specific_open_graph(self) -> None:
        url = "https://rent.heykorean.com/rent/view/1090440"
        page_image_url = (
            "https://data.heykorean.com/housing_thumbnail/origin/housing/"
            "rent/2026/08/01/6a6e067b1be76c54339313.webp"
        )
        html = (
            "<html><head>"
            f'<meta property="og:url" content="{url}">'
            '<meta property="og:title" '
            'content="StuyTown 거실룸 룸메이트 구해요 !">'
            '<meta property="og:description" '
            'content="StuyTown 거실룸 룸메이트 구해요 !">'
            f'<meta property="og:image" content="{page_image_url}">'
            '<meta property="og:site_name" '
            'content="StuyTown 거실룸 룸메이트 구해요 !">'
            "</head><body></body></html>"
        ).encode()
        response = FakeHTTPResponse(html, url=url)

        def fake_urlopen(
            request: Request,
            *,
            timeout: int,
        ) -> FakeHTTPResponse:
            headers = {
                key.lower(): value
                for key, value in request.header_items()
            }
            self.assertEqual(
                headers["user-agent"],
                "facebookexternalhit/1.1; kakaotalk-scrap/1.0; "
                "+https://devtalk.kakao.com/t/scrap/33984",
            )
            self.assertEqual(headers["accept"], "*/*")
            self.assertEqual(
                headers["accept-language"],
                "ko-KR,ko;q=0.8,en-US;q=0.6,en;q=0.4",
            )
            self.assertEqual(
                timeout,
                message_routes.LINK_PREVIEW_FETCH_TIMEOUT_SECONDS,
            )
            return response

        with patch.object(
            message_routes,
            "urlopen",
            side_effect=fake_urlopen,
        ):
            preview = message_routes.build_link_preview_metadata(url, None)

        self.assertIsNotNone(preview)
        assert preview is not None
        self.assertEqual(preview["url"], url)
        self.assertEqual(preview["canonical_url"], url)
        self.assertEqual(preview["domain"], "rent.heykorean.com")
        self.assertEqual(
            preview["title"],
            "StuyTown 거실룸 룸메이트 구해요 !",
        )
        self.assertEqual(
            preview["description"],
            "StuyTown 거실룸 룸메이트 구해요 !",
        )
        self.assertEqual(
            preview["image_url"],
            page_image_url,
        )
        self.assertEqual(
            preview["site_name"],
            "StuyTown 거실룸 룸메이트 구해요 !",
        )

    def test_open_graph_after_legacy_256_kib_limit_is_parsed(self) -> None:
        requested_url = "https://youtu.be/CS0zz7WlnV0"
        canonical_url = "https://www.youtube.com/watch?v=CS0zz7WlnV0"
        thumbnail_url = (
            "https://i.ytimg.com/vi/CS0zz7WlnV0/maxresdefault.jpg"
        )
        padding = "x" * (700 * 1024)
        html = (
            "<html><head><script>"
            + padding
            + "</script>"
            + f'<meta property="og:url" content="{canonical_url}">'
            + '<meta property="og:title" content="Gold Farm">'
            + f'<meta property="og:image" content="{thumbnail_url}">'
            + "</head><body></body></html>"
        ).encode()
        response = FakeHTTPResponse(html, url=canonical_url)

        with patch.object(
            message_routes,
            "urlopen",
            return_value=response,
        ):
            preview = message_routes.build_link_preview_metadata(
                requested_url,
                None,
            )

        self.assertIsNotNone(preview)
        assert preview is not None
        self.assertGreater(
            html.find(b"og:title"),
            256 * 1024,
        )
        self.assertEqual(preview["title"], "Gold Farm")
        self.assertEqual(preview["canonical_url"], canonical_url)
        self.assertEqual(preview["domain"], "youtu.be")
        self.assertEqual(
            preview["image_url"],
            thumbnail_url,
        )

    def test_reader_stops_after_html_head(self) -> None:
        url = "https://example.com/article"
        head = (
            "<html><head>"
            '<meta property="og:title" content="Preview title">'
            "</head>"
        ).encode()
        body = head + b"<body>" + (b"x" * (3 * 1024 * 1024)) + b"</body>"
        response = FakeHTTPResponse(body, url=url)

        with patch.object(
            message_routes,
            "urlopen",
            return_value=response,
        ):
            preview = message_routes.build_link_preview_metadata(url, None)

        self.assertIsNotNone(preview)
        assert preview is not None
        self.assertEqual(preview["title"], "Preview title")
        self.assertLess(response.bytes_read, len(body))
        self.assertLessEqual(
            response.bytes_read,
            message_routes.LINK_PREVIEW_READ_CHUNK_BYTES,
        )

    def test_http_error_logs_warning_and_returns_domain_fallback(self) -> None:
        url = "https://m.fmkorea.com/10166678809"
        error = HTTPError(url, 430, "Unknown", hdrs=None, fp=None)

        with (
            patch.object(message_routes, "urlopen", side_effect=error),
            self.assertLogs(message_routes.logger, level="WARNING") as logs,
        ):
            preview = message_routes.build_link_preview_metadata(url, None)

        self.assertIsNotNone(preview)
        assert preview is not None
        self.assertEqual(preview["domain"], "m.fmkorea.com")
        self.assertNotIn("title", preview)
        self.assertTrue(any("HTTPError" in message for message in logs.output))
        self.assertTrue(any("430" in message for message in logs.output))

    def test_http_error_preserves_device_fetched_metadata(self) -> None:
        url = "https://m.fmkorea.com/10166678809"
        image_url = "https://image.fmkorea.com/files/preview.jpg"
        metadata = {
            "url": url,
            "canonical_url": "https://www.fmkorea.com/10166678809",
            "domain": "m.fmkorea.com",
            "title": "우리는 모르는 잘생긴 남자의 삶",
            "description": "Tap here to open the link.",
            "site_name": "에펨코리아",
            "image_url": image_url,
        }
        error = HTTPError(url, 429, "Too Many Requests", hdrs=None, fp=None)

        with (
            patch.object(message_routes, "urlopen", side_effect=error),
            patch.object(message_routes.logger, "warning"),
        ):
            preview = message_routes.build_link_preview_metadata(url, metadata)

        self.assertIsNotNone(preview)
        assert preview is not None
        self.assertEqual(preview["canonical_url"], metadata["canonical_url"])
        self.assertEqual(preview["title"], metadata["title"])
        self.assertEqual(preview["description"], metadata["description"])
        self.assertEqual(preview["site_name"], metadata["site_name"])
        self.assertEqual(preview["image_url"], image_url)


if __name__ == "__main__":
    unittest.main()
