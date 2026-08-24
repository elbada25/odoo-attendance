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
import threading
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

PYTHON_EXE = Path(sys.executable)


def _no_console_si():
    if os.name == "nt":
        si = subprocess.STARTUPINFO()  # type: ignore[attr-defined]
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW  # type: ignore[attr-defined]
        si.wShowWindow = subprocess.SW_HIDE  # type: ignore[attr-defined]
        return si
    return None


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
# Dialog (tkinter, cross-platform, themed)
# ---------------------------------------------------------------------------
def show_dialog(config: dict, update_url: str = "",
                latest_version: str = "") -> str:
    """Show the confirmation dialog. Returns 'fichar' | 'done' | 'cancel' | 'update'."""
    import tkinter as tk
    from theme import get_theme, fonts
    from widgets import ModernButton

    C = get_theme()
    F = fonts()

    result = {"choice": "cancel"}
    has_update = bool(update_url)

    root = tk.Tk()
    root.title("Fichaje Odoo")
    root.configure(bg=C["bg"])
    root.resizable(False, False)

    w = 460
    h = 280 if has_update else 220
    sw = root.winfo_screenwidth()
    sh = root.winfo_screenheight()
    root.geometry(f"{w}x{h}+{(sw - w) // 2}+{(sh - h) // 2}")
    root.attributes("-topmost", True)

    try:
        root.iconbitmap(default="")
    except Exception:
        pass

    def choose(value: str) -> None:
        result["choice"] = value
        root.destroy()

    # ── Update bar (top) ──
    if has_update:
        bar = tk.Frame(root, bg=C["warning"], height=3)
        bar.pack(fill="x", side="top")
        update_frame = tk.Frame(root, bg=C["surface"])
        update_frame.pack(fill="x", padx=20, pady=(12, 0))
        inner = tk.Frame(update_frame, bg=C["surface"])
        inner.pack(fill="x", padx=16, pady=10)
        tk.Label(inner, text=f"Nueva version disponible  \u2022  {latest_version}",
                 bg=C["surface"], fg=C["warning"], font=F["body_b"]).pack(
            side="left")
        ModernButton(inner, "Actualizar ahora", C, F, variant="warning",
                     padx=14, pady=6,
                     command=lambda: choose("update")).pack(side="right")

    # ── Main content ──
    content = tk.Frame(root, bg=C["bg"])
    top_pad = 24 if has_update else 32
    content.pack(fill="both", expand=True, padx=36, pady=(top_pad, 12))

    tk.Label(content, text="\u00bfQuieres registrar tu asistencia de hoy?",
             bg=C["bg"], fg=C["text"], font=F["body"]).pack(
        anchor="center", pady=(0, 20))

    # ── Buttons ──
    btn_row = tk.Frame(content, bg=C["bg"])
    btn_row.pack(fill="x")

    ModernButton(btn_row, "Fichar", C, F, variant="primary",
                 command=lambda: choose("fichar")).pack(
        side="left", padx=(0, 8), fill="x", expand=True)
    ModernButton(btn_row, "No preguntar m\u00e1s hoy", C, F,
                 command=lambda: choose("done")).pack(
        side="left", padx=4, fill="x", expand=True)
    ModernButton(btn_row, "Ahora no", C, F, variant="subtle",
                 command=lambda: choose("cancel")).pack(
        side="left", padx=(8, 0), fill="x", expand=True)

    # ── Bottom divider ──
    tk.Frame(root, bg=C["border"], height=1).pack(fill="x", side="bottom")

    # Focus
    def _force_focus() -> None:
        root.deiconify()
        root.lift()
        root.focus_force()
        root.attributes("-topmost", True)
    root.after(100, _force_focus)
    root.after(250, _force_focus)

    root.protocol("WM_DELETE_WINDOW", lambda: choose("cancel"))
    root.mainloop()

    if result["choice"] == "update" and update_url:
        import check_updates as _cu
        try:
            ok = _cu.download_and_apply_update(update_url)
            if ok:
                import tkinter.messagebox as _mb
                _mb.showinfo("Actualizacion completada",
                             "La aplicacion se ha actualizado correctamente.")
        except Exception:
            pass
        return "cancel"

    return result["choice"]


# ---------------------------------------------------------------------------
# Run the Selenium automation
# ---------------------------------------------------------------------------
def run_attendance(config: dict) -> int:
    if not ATTENDANCE_SCRIPT.exists():
        write_log(f"ERROR: {ATTENDANCE_SCRIPT} not found.")
        return 1
    cmd = [str(PYTHON_EXE), str(ATTENDANCE_SCRIPT)]
    write_log(f"Running: {' '.join(cmd)}")
    try:
        proc = subprocess.run(
            cmd, cwd=str(SCRIPT_DIR), capture_output=True, text=True,
            timeout=600, startupinfo=_no_console_si(),
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

    if not config.get("behavior", {}).get("enabled", True):
        write_log("Attendance dialog disabled in config - nothing to do.")
        return 0

    if is_skip_day(config):
        write_log("Skip-weekday - nothing to do.")
        return 0

    MARKER_DIR.mkdir(parents=True, exist_ok=True)
    if today_marker_path().exists():
        write_log("Already done today - skipping.")
        return 0

    blocks = get_today_blocks(config)
    if not blocks:
        write_log("No blocks scheduled today - skipping dialog.")
        return 0

    installer_url = ""
    latest_version = ""
    if config.get("behavior", {}).get("check_updates", True):
        import check_updates as _cu
        from version import get_version as _get_version

        update_result: list = [None]

        def _check() -> None:
            try:
                update_result[0] = _cu.check_for_updates(_get_version())
            except Exception:
                pass

        t = threading.Thread(target=_check, daemon=True)
        t.start()
        t.join(timeout=3)

        if update_result[0] is not None and update_result[0].has_update:
            installer_url = update_result[0].installer_url
            latest_version = update_result[0].latest_version
            write_log(f"Update available: {latest_version}")

    write_log("Showing dialog...")
    choice = show_dialog(config, update_url=installer_url,
                         latest_version=latest_version)

    if choice == "cancel":
        write_log("User chose 'Ahora no' - will ask again later.")
        return 0
    if choice == "done":
        mark_done()
        write_log("User chose 'No preguntar mas hoy' - marked done for today.")
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
