from __future__ import annotations


_DISPLAY_NAME_BY_VIEWER_USERNAME: dict[str, dict[str, str]] = {
    "liababo": {
        "junebabo": "애기🤍",
        "yunjung5437": "엄마",
    },
    "junebabo": {
        "liababo": "오빠💙",
        "yunjung5437": "阿姨",
    },
    "yunjung5437": {
        "junebabo": "리아",
        "liababo": "준",
    },
}


def display_name_for_viewer(
    *,
    viewer_username: str,
    subject_username: str,
    fallback: str,
) -> str:
    viewer_key = viewer_username.strip().casefold()
    subject_key = subject_username.strip().casefold()

    return _DISPLAY_NAME_BY_VIEWER_USERNAME.get(viewer_key, {}).get(
        subject_key,
        fallback,
    )
