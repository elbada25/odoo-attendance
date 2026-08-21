"""Check for newer releases on GitHub and apply updates automatically."""

from __future__ import annotations

import base64
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path
from typing import NamedTuple

SCRIPT_DIR = Path(__file__).resolve().parent
CONF_DIR = SCRIPT_DIR  # same dir (we live in conf/)

# GitHub repository to check for releases.
GITHUB_REPO = "elbada25/odoo-attendance"

_API_URL = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"


class UpdateInfo(NamedTuple):
    has_update: bool
    latest_version: str       # e.g. "v1.1.0"
    current_version: str      # e.g. "1.0.0"
    download_url: str         # URL to the GitHub Releases page
    installer_url: str        # direct download URL for the installer asset
    body: str                 # release notes (may be empty)


def _parse_version(tag: str) -> tuple[int, ...]:
    tag = tag.lstrip("v")
    parts = tag.split("-")[0]
    return tuple(int(p) for p in parts.split(".") if p.isdigit())


def check_for_updates(current_version: str | None = None) -> UpdateInfo:
    """Query the GitHub Releases API and compare with *current_version*."""
    if current_version is None:
        try:
            current_version = (
                (SCRIPT_DIR / "VERSION").read_text(encoding="utf-8").strip()
            )
        except Exception:
            current_version = "0.0.0"

    fallback = UpdateInfo(
        has_update=False,
        latest_version="?",
        current_version=current_version,
        download_url=f"https://github.com/{GITHUB_REPO}/releases",
        installer_url="",
        body="",
    )

    try:
        req = urllib.request.Request(_API_URL, headers={"Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode())
    except Exception:
        return fallback

    latest_tag = data.get("tag_name", "v0.0.0")
    download_url = data.get("html_url", fallback.download_url)
    body = data.get("body", "") or ""

    # Find the installer asset for this OS
    installer_url = ""
    wanted = "instalador_windows.bat" if os.name == "nt" else "instalador_linux.sh"
    for asset in data.get("assets", []):
        if asset.get("name") == wanted:
            installer_url = asset.get("browser_download_url", "")
            break

    try:
        latest_ver = _parse_version(latest_tag)
        current_ver = _parse_version(current_version)
    except Exception:
        return UpdateInfo(
            has_update=False, latest_version=latest_tag,
            current_version=current_version, download_url=download_url,
            installer_url=installer_url, body=body,
        )

    return UpdateInfo(
        has_update=latest_ver > current_ver,
        latest_version=latest_tag,
        current_version=current_version,
        download_url=download_url,
        installer_url=installer_url,
        body=body,
    )


def download_and_apply_update(installer_url: str) -> bool:
    """Download the new installer, extract its payload, and update the app.

    Preserves the user's ``config.toml``.  Returns ``True`` on success.
    """
    if not installer_url:
        return False

    # 1. Download the installer
    tmp_dir = Path(tempfile.mkdtemp(prefix="odoo_update_"))
    installer_path = tmp_dir / "installer"
    try:
        print("Downloading update...")
        urllib.request.urlretrieve(installer_url, installer_path)
    except Exception as exc:
        print(f"Download failed: {exc}")
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return False

    # 2. Read and decode the base64 payload from the installer
    try:
        content = installer_path.read_text(encoding="utf-8", errors="replace")
        s = content.rindex("___ODOO_PAYLOAD_BEGIN___") + 25
        e = content.rindex("___ODOO_PAYLOAD_END___")
        b64 = "".join(content[s:e].split())  # remove all whitespace
        payload_bytes = base64.b64decode(b64)
    except Exception as exc:
        print(f"Failed to extract payload: {exc}")
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return False

    # 3. Backup existing config.toml
    config_path = CONF_DIR / "config.toml"
    config_backup = None
    if config_path.exists():
        config_backup = config_path.read_bytes()

    # 4. Extract payload into conf/
    try:
        with tarfile.open(fileobj=io.BytesIO(payload_bytes), mode="r:gz") as tar:
            tar.extractall(path=CONF_DIR)
    except Exception as exc:
        print(f"Failed to extract update: {exc}")
        # Restore config if we had it
        if config_backup is not None:
            config_path.write_bytes(config_backup)
        shutil.rmtree(tmp_dir, ignore_errors=True)
        return False

    # 5. Restore user's config.toml
    if config_backup is not None:
        config_path.write_bytes(config_backup)

    # 6. Update Python dependencies
    venv_py = _find_venv_python()
    if venv_py:
        try:
            subprocess.run(
                [str(venv_py), "-m", "pip", "install", "--upgrade", "pip"],
                capture_output=True, timeout=120, cwd=str(CONF_DIR),
            )
            subprocess.run(
                [str(venv_py), "-m", "pip", "install", "-r",
                 str(CONF_DIR / "requirements.txt")],
                capture_output=True, timeout=300, cwd=str(CONF_DIR),
            )
        except Exception:
            pass  # non-fatal; the app will still work

    # 7. Clean up
    shutil.rmtree(tmp_dir, ignore_errors=True)
    print("Update applied successfully.")
    return True


def _find_venv_python() -> Path | None:
    """Locate the venv Python executable."""
    if os.name == "nt":
        candidates = [
            CONF_DIR / ".venv" / "Scripts" / "python.exe",
            CONF_DIR.parent / "conf" / ".venv" / "Scripts" / "python.exe",
        ]
    else:
        candidates = [
            CONF_DIR / ".venv" / "bin" / "python",
            CONF_DIR.parent / "conf" / ".venv" / "bin" / "python",
        ]
    for c in candidates:
        if c.exists():
            return c
    # Fallback: use the Python that's running this script
    return Path(sys.executable)
