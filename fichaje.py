"""Cross-platform orchestrator for the Odoo attendance automation.

Responsibilities (shared by Windows and Linux):
  1. Load config.toml.
  2. Skip if today is a configured skip-weekday (e.g. weekends).
  3. Skip if already handled today (marker file in .markers/).
  4. Show a dialog with three options:
       - "Fichar"        -> run odoo_attendance.py, then mark today done.
       - "Ya he fichado" -> mark today done without running anything.
       - "Ahora no"      -> do nothing (will ask again on next unlock).
  5. Log every step to attendance.log.

The dialog uses tkinter (built-in on Windows; requires python3-tk on Linux).
The OS-specific part is only the TRIGGER that launches this script:
  - Windows: Task Scheduler on session unlock  ->  pythonw fichaje.py
  - Linux:   systemd user service + D-Bus listener -> python fichaje.py
"""

from __future__ import annotations

import os
import subprocess
import sys
from datetime import date
from pathlib import Path

try:  # Python 3.11+
    import tomllib
except ModuleNotFoundError:  # Python 3.10
    import tomli as tomllib  # type: ignore[no-redef]

SCRIPT_DIR = Path(__file__).resolve().parent
CONFIG_PATH = SCRIPT_DIR / "config.toml"
MARKER_DIR = SCRIPT_DIR / ".markers"
LOG_FILE = SCRIPT_DIR / "attendance.log"
ATTENDANCE_SCRIPT = SCRIPT_DIR / "odoo_attendance.py"

# Reuse the same venv interpreter that runs this script.
PYTHON_EXE = Path(sys.executable)
# On Windows prefer pythonw (no console) for the child; on Linux keep python.
PYTHONW_EXE = PYTHON_EXE.parent / ("pythonw.exe" if os.name == "nt" else "python")


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
def load_config() -> dict:
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH, "rb") as fh:
            return tomllib.load(fh)
    print(f"ERROR: {CONFIG_PATH} not found. Run the installer or copy "
          f"config.example.toml to config.toml.", file=sys.stderr)
    sys.exit(2)


def write_log(msg: str) -> None:
    from datetime import datetime
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(f"[{ts}] {msg}\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Day / marker logic
# ---------------------------------------------------------------------------
def today_marker_path() -> Path:
    return MARKER_DIR / f"{date.today().isoformat()}.done"


def is_skip_day(config: dict) -> bool:
    skip = config.get("behavior", {}).get("skip_weekdays", [])
    return date.today().weekday() in skip


def get_today_blocks(config: dict) -> list[tuple[str, str, str]]:
    """Resolve today's blocks (same logic as odoo_attendance.get_today_blocks)."""
    sched = config.get("schedule", {})
    key = f"{date.today().month:02d}-{date.today().day:02d}"
    special = sched.get("special_days", {})
    if key in special:
        return [tuple(b) for b in special[key]]
    summer_months = sched.get("summer_months", [])
    day_map = sched.get("summer", {}) if date.today().month in summer_months else sched.get("normal", {})
    return [tuple(b) for b in day_map.get(str(date.today().weekday()), [])]


def mark_done() -> None:
    MARKER_DIR.mkdir(parents=True, exist_ok=True)
    today_marker_path().touch()


# ---------------------------------------------------------------------------
# Dialog (tkinter, cross-platform)
# ---------------------------------------------------------------------------
def show_dialog(config: dict) -> str:
    """Show the confirmation dialog. Returns 'fichar' | 'done' | 'cancel'."""
    import tkinter as tk
    from tkinter import ttk

    result = {"choice": "cancel"}

    root = tk.Tk()
    root.title("Fichaje Odoo")
    root.geometry("440x210")
    root.resizable(False, False)
    # Center on screen
    root.update_idletasks()
    w, h = 440, 210
    sw, sh = root.winfo_screenwidth(), root.winfo_screenheight()
    root.geometry(f"+{(sw - w) // 2}+{(sh - h) // 2}")
    root.attributes("-topmost", True)

    # Question mark icon (built-in)
    try:
        root.iconbitmap(default="")  # no-op fallback
    except Exception:
        pass

    label = ttk.Label(
        root,
        text="\u00bfQuieres fichar la asistencia de hoy?",
        font=("Segoe UI", 12) if os.name == "nt" else ("Sans", 12),
        anchor="center",
        justify="center",
        padding=10,
    )
    label.pack(fill="x", pady=(18, 10))

    btn_frame = ttk.Frame(root)
    btn_frame.pack(pady=8)

    def choose(value: str) -> None:
        result["choice"] = value
        root.destroy()

    btn_fichar = ttk.Button(btn_frame, text="Fichar", width=12, command=lambda: choose("fichar"))
    btn_fichar.pack(side="left", padx=6)

    btn_done = ttk.Button(btn_frame, text="No preguntar m\u00e1s hoy", width=18, command=lambda: choose("done"))
    btn_done.pack(side="left", padx=6)

    btn_cancel = ttk.Button(btn_frame, text="Ahora no", width=12, command=lambda: choose("cancel"))
    btn_cancel.pack(side="left", padx=6)

    # Force foreground focus shortly after the window appears.
    def _force_focus() -> None:
        root.deiconify()
        root.lift()
        root.focus_force()
        root.attributes("-topmost", True)
    root.after(100, _force_focus)
    root.after(250, _force_focus)

    root.protocol("WM_DELETE_WINDOW", lambda: choose("cancel"))
    root.mainloop()
    return result["choice"]


# ---------------------------------------------------------------------------
# Run the Selenium automation
# ---------------------------------------------------------------------------
def run_attendance(config: dict) -> int:
    """Run odoo_attendance.py with the same interpreter. Returns exit code."""
    if not ATTENDANCE_SCRIPT.exists():
        write_log(f"ERROR: {ATTENDANCE_SCRIPT} not found.")
        return 1
    cmd = [str(PYTHON_EXE), str(ATTENDANCE_SCRIPT)]
    write_log(f"Running: {' '.join(cmd)}")
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(SCRIPT_DIR),
            capture_output=True,
            text=True,
            timeout=600,
        )
    except subprocess.TimeoutExpired:
        write_log("ERROR: attendance script timed out.")
        return 1

    for line in (proc.stdout or "").splitlines():
        write_log(f"  | {line}")
    for line in (proc.stderr or "").splitlines():
        write_log(f"  ! {line}")
    write_log(f"Script exited with code {proc.returncode}")
    return proc.returncode


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    config = load_config()
    today = date.today().isoformat()
    weekday = date.today().strftime("%A")

    write_log(f"Orchestrator triggered (day={weekday}, date={today})")

    # 0) Master switch: if disabled in config, do nothing at all.
    if not config.get("behavior", {}).get("enabled", True):
        write_log("Attendance dialog disabled in config - nothing to do.")
        return 0

    # 1) Skip configured weekdays (e.g. weekends)
    if is_skip_day(config):
        write_log("Skip-weekday - nothing to do.")
        return 0

    # 2) Already handled today?
    MARKER_DIR.mkdir(parents=True, exist_ok=True)
    if today_marker_path().exists():
        write_log("Already done today - skipping.")
        return 0

    # 3) No blocks scheduled today? Nothing to ask about.
    blocks = get_today_blocks(config)
    if not blocks:
        write_log("No blocks scheduled today - skipping dialog.")
        return 0

    write_log("Showing dialog...")
    choice = show_dialog(config)

    if choice == "cancel":
        write_log("User chose 'Ahora no' - will ask again later.")
        return 0
    if choice == "done":
        mark_done()
        write_log("User chose 'No preguntar m\u00e1s hoy' - marked done for today.")
        return 0
    if choice == "fichar":
        rc = run_attendance(config)
        if rc == 0:
            mark_done()
            write_log("Completed successfully - marked done for today.")
        else:
            write_log(f"Attendance script failed (code {rc}) - NOT marked done.")
        return rc

    write_log("Unknown dialog choice - ignoring.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
