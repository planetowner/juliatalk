import unittest

from app.display_names import display_name_for_viewer


class DisplayNameForViewerTests(unittest.TestCase):
    def test_returns_configured_names_for_viewers(self) -> None:
        expected_names = {
            ("liababo", "junebabo"): "애기🤍",
            ("liababo", "yunjung5437"): "엄마",
            ("junebabo", "liababo"): "오빠💙",
            ("junebabo", "yunjung5437"): "阿姨",
            ("yunjung5437", "junebabo"): "리아",
            ("yunjung5437", "liababo"): "준",
        }

        for (viewer_username, subject_username), expected in expected_names.items():
            with self.subTest(
                viewer_username=viewer_username,
                subject_username=subject_username,
            ):
                self.assertEqual(
                    display_name_for_viewer(
                        viewer_username=viewer_username,
                        subject_username=subject_username,
                        fallback="Server Name",
                    ),
                    expected,
                )

    def test_normalizes_usernames_before_matching(self) -> None:
        self.assertEqual(
            display_name_for_viewer(
                viewer_username="  JUNEbabo ",
                subject_username=" LIABABO ",
                fallback="Lia",
            ),
            "오빠💙",
        )

    def test_falls_back_to_global_display_name(self) -> None:
        self.assertEqual(
            display_name_for_viewer(
                viewer_username="unknown-viewer",
                subject_username="unknown-subject",
                fallback="Server Name",
            ),
            "Server Name",
        )


if __name__ == "__main__":
    unittest.main()
