"""Shared theme system for Odoo Attendance.

Refined neutral palette with a single sober accent.
Widgets are flat and modern; surfaces differ by tone, not borders.
"""

from __future__ import annotations

import os


def detect_dark_mode() -> bool:
    if os.name == "nt":
        try:
            import winreg
            key = winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
            )
            val, _ = winreg.QueryValueEx(key, "AppsUseLightTheme")
            winreg.CloseKey(key)
            return val == 0
        except Exception:
            pass
    try:
        from pathlib import Path
        gtk = Path.home() / ".config" / "gtk-3.0" / "settings.ini"
        if gtk.exists():
            text = gtk.read_text(encoding="utf-8", errors="replace")
            if "gtk-application-prefer-dark-theme=1" in text:
                return True
    except Exception:
        pass
    return False


DARK: dict[str, str] = {
    # Surfaces (darkest -> lightest)
    "bg":          "#1a1a1a",
    "surface":     "#222222",
    "surface2":    "#2a2a2a",
    "surface3":    "#333333",
    "surface4":    "#3d3d3d",

    # Text
    "text":        "#ececec",
    "text_sec":    "#ababab",
    "text_dis":    "#6f6f6f",

    # Accent — refined steel blue
    "accent":          "#4f8ef7",
    "accent_hov":      "#6aa1f8",
    "accent_pressed":  "#3f7ae0",
    "accent_dim":      "#2a3d5c",

    # Borders
    "border":      "#3a3a3a",
    "border_foc":  "#4f8ef7",

    # Semantic
    "success":       "#5cb877",
    "error":         "#e05555",
    "warning":       "#d4a62a",
    "warning_hov":   "#e0b53d",
    "warning_pressed": "#c09520",

    # Title / nav / footer
    "title_bg":    "#1f1f1f",
    "nav_bg":      "#1f1f1f",
    "nav_item":    "#1f1f1f",
    "nav_hov":     "#2c2c2c",
    "nav_active":  "#1a1a1a",
    "nav_indicator": "#4f8ef7",
    "footer_bg":   "#1f1f1f",

    # Code / log
    "code_bg":     "#171717",
    "code_text":   "#d6d6d6",

    # Inputs
    "input_bg":    "#2a2a2a",

    # Scrollbar
    "scroll_thumb":       "#4a4a4a",
    "scroll_thumb_hover": "#5c5c5c",
    "scroll_trough":      "#1a1a1a",

    # Aliases for datepickers.py compatibility
    "btn_bg":      "#2a2a2a",
    "btn_hov":     "#333333",
    "primary":     "#4f8ef7",
    "primary_hov": "#6aa1f8",
}

LIGHT: dict[str, str] = {
    "bg":          "#f4f4f4",
    "surface":     "#ffffff",
    "surface2":    "#ffffff",
    "surface3":    "#ececec",
    "surface4":    "#e0e0e0",

    "text":        "#1c1c1c",
    "text_sec":    "#5f5f5f",
    "text_dis":    "#9a9a9a",

    "accent":          "#2563eb",
    "accent_hov":      "#3b76f0",
    "accent_pressed":  "#1d4ed8",
    "accent_dim":      "#dbe7fd",

    "border":      "#d8d8d8",
    "border_foc":  "#2563eb",

    "success":       "#2e9e5b",
    "error":         "#d64545",
    "warning":       "#c9911a",
    "warning_hov":   "#d9a52a",
    "warning_pressed": "#b07f12",

    "title_bg":    "#ececec",
    "nav_bg":      "#ececec",
    "nav_item":    "#ececec",
    "nav_hov":     "#e0e0e0",
    "nav_active":  "#ffffff",
    "nav_indicator": "#2563eb",
    "footer_bg":   "#ececec",

    "code_bg":     "#f8f8f8",
    "code_text":   "#1a1a1a",

    "input_bg":    "#ffffff",

    "scroll_thumb":       "#c8c8c8",
    "scroll_thumb_hover": "#b0b0b0",
    "scroll_trough":      "#f4f4f4",

    "btn_bg":      "#ffffff",
    "btn_hov":     "#ececec",
    "primary":     "#2563eb",
    "primary_hov": "#3b76f0",
}


def get_theme(dark: bool | None = None) -> dict[str, str]:
    if dark is None:
        dark = detect_dark_mode()
    return DARK if dark else LIGHT


def fonts() -> dict[str, tuple]:
    family = "Segoe UI" if os.name == "nt" else "Sans"
    return {
        "body":     (family, 9),
        "body_b":   (family, 9, "bold"),
        "small":    (family, 8),
        "small_b":  (family, 8, "bold"),
        "section":  (family, 12, "bold"),
        "nav":      (family, 9),
        "nav_active": (family, 9, "bold"),
        "label":    (family, 9),
        "helper":   (family, 8),
        "btn":      (family, 9),
        "btn_b":    (family, 9, "bold"),
        "mono":     ("Consolas", 9) if os.name == "nt" else ("Mono", 9),
        "title":    (family, 10, "bold"),
    }


def apply_ttk_theme(style, C: dict[str, str]) -> None:
    """Minimal ttk theme for the few remaining ttk widgets."""
    f = fonts()
    style.theme_use("clam")
    style.configure(".", background=C["surface"], foreground=C["text"],
                    font=f["body"])
    style.configure("TFrame", background=C["surface"])
    style.configure("Surface.TFrame", background=C["surface"])
    style.configure("TLabel", background=C["surface"], foreground=C["text"],
                    font=f["body"])
    style.configure("Surface.TLabel", background=C["surface"],
                    foreground=C["text"], font=f["body"])
