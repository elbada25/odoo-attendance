"""Read the application version from the VERSION file next to this module."""

from __future__ import annotations

from pathlib import Path

_VERSION_PATH = Path(__file__).resolve().parent / "VERSION"


def get_version() -> str:
    """Return the version string (e.g. ``"1.0.0"``)."""
    try:
        return _VERSION_PATH.read_text(encoding="utf-8").strip()
    except Exception:
        return "0.0.0"
