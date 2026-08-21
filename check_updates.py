"""Check for newer releases on GitHub and report update availability."""

from __future__ import annotations

import json
import urllib.request
from pathlib import Path
from typing import NamedTuple

SCRIPT_DIR = Path(__file__).resolve().parent

# GitHub repository to check for releases.
# Change this if you fork the project.
GITHUB_REPO = "elbada25/odoo-attendance"

_API_URL = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"


class UpdateInfo(NamedTuple):
    has_update: bool
    latest_version: str       # e.g. "v1.1.0"
    current_version: str      # e.g. "1.0.0"
    download_url: str         # URL to the GitHub Releases page
    body: str                 # release notes (may be empty)


def _parse_version(tag: str) -> tuple[int, ...]:
    """Convert ``'v1.2.3'`` or ``'1.2.3'`` to ``(1, 2, 3)``."""
    tag = tag.lstrip("v")
    parts = tag.split("-")[0]  # ignore pre-release suffixes
    return tuple(int(p) for p in parts.split(".") if p.isdigit())


def check_for_updates(current_version: str | None = None) -> UpdateInfo:
    """Query the GitHub Releases API and compare with *current_version*.

    If *current_version* is ``None``, it is read from the ``VERSION`` file
    next to this module.

    Returns an :class:`UpdateInfo` with the comparison result.
    """
    if current_version is None:
        try:
            current_version = (
                (SCRIPT_DIR / "VERSION").read_text(encoding="utf-8").strip()
            )
        except Exception:
            current_version = "0.0.0"

    try:
        req = urllib.request.Request(_API_URL, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
        latest_tag = data.get("tag_name", "v0.0.0")
        download_url = data.get("html_url", f"https://github.com/{GITHUB_REPO}/releases")
        body = data.get("body", "") or ""
    except Exception:
        # Network error, API down, etc. — treat as "no update available"
        return UpdateInfo(
            has_update=False,
            latest_version="?",
            current_version=current_version,
            download_url=f"https://github.com/{GITHUB_REPO}/releases",
            body="",
        )

    try:
        latest_ver = _parse_version(latest_tag)
        current_ver = _parse_version(current_version)
    except Exception:
        return UpdateInfo(
            has_update=False,
            latest_version=latest_tag,
            current_version=current_version,
            download_url=download_url,
            body=body,
        )

    return UpdateInfo(
        has_update=latest_ver > current_ver,
        latest_version=latest_tag,
        current_version=current_version,
        download_url=download_url,
        body=body,
    )
