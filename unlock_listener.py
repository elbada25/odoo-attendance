"""Linux unlock listener for the Odoo attendance automation.

Runs as a systemd --user service. Subscribes to screen-saver D-Bus signals and
launches fichaje.py whenever the session is unlocked.

It listens on the two most common screen-saver D-Bus interfaces:
  - org.gnome.ScreenSaver        (GNOME / GNOME Flashback)
  - org.freedesktop.ScreenSaver  (freedesktop standard; KDE, XFCE, light-locker, ...)

Both emit an `ActiveChanged(boolean)` signal where `False` == unlocked.

Requirements (installed by install_linux.sh):
  - python3-dbus  (system package; pip `dbus-python` needs glib/dbus dev headers)
  - the project's .venv is NOT required here; this runs on the system python3
    so it can access the system dbus module.

Environment:
  - DISPLAY must be set (the service imports it from the user session).
  - On Wayland, WAYLAND_DISPLAY should also be present.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

try:
    import dbus
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib
except ImportError:
    print("ERROR: python3-dbus / python3-gi not installed. "
          "Run install_linux.sh or: sudo apt install python3-dbus python3-gi",
          file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
FICHAJE = SCRIPT_DIR / "fichaje.py"
LOG_FILE = SCRIPT_DIR / "attendance.log"

# (bus_name, object_path) pairs to subscribe to.
SCREENSAVER_BUSES = [
    ("org.gnome.ScreenSaver", "/org/gnome/ScreenSaver"),
    ("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver"),
    ("org.freedesktop.ScreenSaver", "/ScreenSaver"),
]


def write_log(msg: str) -> None:
    from datetime import datetime
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as fh:
            fh.write(f"[{ts}] {msg}\n")
    except OSError:
        pass


def on_active_changed(active: bool) -> None:
    """`active` is True when the screensaver becomes active (locked)."""
    if active:
        # Locked - nothing to do.
        return
    # Unlocked - launch the orchestrator.
    write_log("Unlock detected - launching fichaje.py")
    env = os.environ.copy()
    # Make sure the child can open a GUI window.
    env.setdefault("DISPLAY", ":0")
    try:
        subprocess.Popen(
            [sys.executable, str(FICHAJE)],
            cwd=str(SCRIPT_DIR),
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as exc:  # noqa: BLE001
        write_log(f"ERROR launching fichaje.py: {exc}")


def main() -> int:
    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()

    subscribed = 0
    for bus_name, obj_path in SCREENSAVER_BUSES:
        try:
            bus.add_signal_receiver(
                handler_function=on_active_changed,
                signal_name="ActiveChanged",
                dbus_interface="org.gnome.ScreenSaver",
                bus_name=bus_name,
                path=obj_path,
            )
            subscribed += 1
        except dbus.DBusException:
            pass

    # Also try the freedesktop interface name explicitly.
    for bus_name, obj_path in SCREENSAVER_BUSES:
        try:
            bus.add_signal_receiver(
                handler_function=on_active_changed,
                signal_name="ActiveChanged",
                dbus_interface="org.freedesktop.ScreenSaver",
                bus_name=bus_name,
                path=obj_path,
            )
            subscribed += 1
        except dbus.DBusException:
            pass

    if subscribed == 0:
        write_log("ERROR: could not subscribe to any ScreenSaver signal.")
        print("ERROR: no ScreenSaver D-Bus interface available.", file=sys.stderr)
        return 1

    write_log(f"Unlock listener started ({subscribed} subscription(s)).")
    print(f"Listening for unlock events ({subscribed} subscription(s))...")

    loop = GLib.MainLoop()
    try:
        loop.run()
    except KeyboardInterrupt:
        write_log("Listener stopped by user.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
