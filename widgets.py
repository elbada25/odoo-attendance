"""Modern flat widget set for Odoo Attendance.

Custom-drawn widgets with proper hover/focus/pressed states:
  - ModernEntry      flat input with accent focus ring
  - ModernButton     flat button with hover/pressed states
  - ModernScrollbar  thin rounded scrollbar drawn on canvas
  - ModernCheck      checkbox with drawn indicator
  - ModernToggle     segmented toggle button (weekdays)
"""

from __future__ import annotations

import tkinter as tk


def _round_rect(cv: tk.Canvas, x1, y1, x2, y2, r, **kw):
    """Draw a rounded rectangle on a canvas using a smooth polygon."""
    pts = [x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r, x2, y2 - r, x2, y2,
           x2 - r, y2, x1 + r, y2, x1, y2, x1, y2 - r, x1, y1 + r, x1, y1]
    return cv.create_polygon(pts, smooth=True, **kw)


# ── Entry ─────────────────────────────────────────────────────────────────
class ModernEntry(tk.Entry):
    """Flat entry: no relief, 1px border, accent border on focus."""

    def __init__(self, master, C, F, textvariable=None, show="", width=None,
                 **kw):
        self._C = C
        self._input_bg = C["input_bg"]
        super().__init__(
            master,
            textvariable=textvariable,
            show=show,
            bg=self._input_bg,
            fg=C["text"],
            insertbackground=C["text"],
            relief="flat",
            bd=0,
            highlightthickness=1,
            highlightbackground=C["border"],
            highlightcolor=C["border_foc"],
            font=F["body"],
            selectbackground=C["accent"],
            selectforeground="#ffffff",
            **kw)
        if width:
            self.configure(width=width)
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)
        self.bind("<FocusIn>", self._on_focus_in)
        self.bind("<FocusOut>", self._on_focus_out)

    def _on_enter(self, _e):
        if self.focus_get() is not self and str(self["state"]) != "disabled":
            self.configure(bg=self._C["surface3"])

    def _on_leave(self, _e):
        if self.focus_get() is not self:
            self.configure(bg=self._input_bg)

    def _on_focus_in(self, _e):
        self.configure(bg=self._input_bg)

    def _on_focus_out(self, _e):
        self.configure(bg=self._input_bg)


# ── Button ────────────────────────────────────────────────────────────────
class ModernButton(tk.Button):
    """Flat button with variants and hover/pressed states."""

    def __init__(self, master, text, C, F, command=None, variant="default",
                 padx=16, pady=7, **kw):
        self._C = C
        if variant == "primary":
            nb, nf, hb, pb = C["accent"], "#ffffff", C["accent_hov"], C["accent_pressed"]
            font = F["btn_b"]
        elif variant == "danger":
            nb, nf, hb, pb = C["surface2"], C["error"], C["surface3"], C["surface4"]
            font = F["btn"]
        elif variant == "warning":
            nb, nf, hb, pb = C["warning"], "#ffffff", C["warning_hov"], C["warning_pressed"]
            font = F["btn_b"]
        elif variant == "subtle":
            nb, nf, hb, pb = C["surface"], C["text_sec"], C["surface3"], C["surface4"]
            font = F["btn"]
        else:
            nb, nf, hb, pb = C["surface2"], C["text"], C["surface3"], C["surface4"]
            font = F["btn"]
        self._palette = (nb, nf, hb, pb)
        super().__init__(
            master, text=text, command=command,
            bg=nb, fg=nf,
            relief="flat", bd=0,
            font=font,
            padx=padx, pady=pady,
            cursor="hand2",
            activebackground=pb, activeforeground=nf,
            highlightthickness=0,
            **kw)
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)
        self.bind("<Button-1>", self._on_press)
        self.bind("<ButtonRelease-1>", self._on_release)

    def _on_enter(self, _e):
        if str(self["state"]) != "disabled":
            self.configure(bg=self._palette[2])

    def _on_leave(self, _e):
        if str(self["state"]) != "disabled":
            self.configure(bg=self._palette[0])

    def _on_press(self, _e):
        self.configure(bg=self._palette[3])

    def _on_release(self, _e):
        self.configure(bg=self._palette[2])


# ── Scrollbar ─────────────────────────────────────────────────────────────
class ModernScrollbar(tk.Canvas):
    """Thin rounded scrollbar drawn on a canvas."""

    def __init__(self, master, command, C, width=12):
        super().__init__(master, width=width, bg=C["scroll_trough"],
                         highlightthickness=0, bd=0)
        self._C = C
        self._cmd = command
        self._off = 0.0
        self._ratio = 1.0
        self._hover = False
        self.bind("<Configure>", lambda e: self._draw())
        self.bind("<B1-Motion>", self._on_drag)
        self.bind("<Button-1>", self._on_click)
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)
        self.bind("<MouseWheel>", self._on_wheel)

    def set(self, lo, hi):
        try:
            self._off = max(0.0, min(1.0, float(lo)))
            self._ratio = max(0.0, min(1.0, float(hi) - float(lo)))
        except Exception:
            return
        self._draw()

    def _draw(self, *_):
        C = self._C
        self.delete("all")
        w = self.winfo_width()
        h = self.winfo_height()
        if w <= 1 or h <= 1:
            return
        thumb_h = max(28, int(h * self._ratio))
        max_y = h - thumb_h
        y0 = int(self._off * h)
        if y0 > max_y:
            y0 = max_y
        color = C["scroll_thumb_hover"] if self._hover else C["scroll_thumb"]
        _round_rect(self, 3, y0, w - 3, y0 + thumb_h, 4,
                    fill=color, outline="")

    def _on_click(self, e):
        if self.winfo_height() > 0:
            self._cmd("moveto", e.y / self.winfo_height())

    def _on_drag(self, e):
        if self.winfo_height() > 0:
            self._cmd("moveto", e.y / self.winfo_height())

    def _on_wheel(self, e):
        self._cmd("scroll", int(-1 * (e.delta / 120)), "units")

    def _on_enter(self, _e):
        self._hover = True
        self._draw()

    def _on_leave(self, _e):
        self._hover = False
        self._draw()


# ── Checkbox ──────────────────────────────────────────────────────────────
class ModernCheck(tk.Frame):
    """Checkbox with a custom-drawn rounded indicator."""

    def __init__(self, master, text, variable, C, F, command=None, indent=0):
        super().__init__(master, bg=C["surface"])
        self._var = variable
        self._C = C
        self._cmd = command

        self._box = tk.Canvas(self, width=18, height=18, bg=C["surface"],
                              highlightthickness=0, bd=0, cursor="hand2")
        self._box.pack(side="left", padx=(indent, 8))
        self._lbl = tk.Label(self, text=text, bg=C["surface"], fg=C["text"],
                             font=F["body"], cursor="hand2", anchor="w",
                             justify="left")
        self._lbl.pack(side="left", fill="x")

        self._box.bind("<Button-1>", self._toggle)
        self._lbl.bind("<Button-1>", self._toggle)
        for w in (self._box, self._lbl):
            w.bind("<Enter>", self._on_enter)
            w.bind("<Leave>", self._on_leave)
        self._var.trace_add("write", lambda *_: self._draw())
        self._draw()

    def _on_enter(self, _e):
        C = self._C
        self._box.configure(bg=C["surface3"])
        self._lbl.configure(bg=C["surface3"], fg=C["text"])
        self._redraw()

    def _on_leave(self, _e):
        self._draw()

    def _redraw(self, *_):
        C = self._C
        bg = self._lbl.cget("bg")
        self._box.delete("all")
        if self._var.get():
            _round_rect(self._box, 1, 1, 17, 17, 4,
                        fill=C["accent"], outline=C["accent"])
            self._box.create_line(5, 9, 8, 12, 13, 6, fill="#ffffff", width=2,
                                  capstyle="round", joinstyle="round")
        else:
            _round_rect(self._box, 1, 1, 17, 17, 4,
                        fill=C["input_bg"], outline=C["border"])
        if bg:
            self._box.configure(bg=bg)

    def _draw(self, *_):
        C = self._C
        self._box.configure(bg=C["surface"])
        self._lbl.configure(bg=C["surface"], fg=C["text"])
        self._redraw()

    def _toggle(self, _e=None):
        self._var.set(not self._var.get())
        self._redraw()
        if self._cmd:
            self._cmd()


# ── Segmented toggle ──────────────────────────────────────────────────────
class ModernToggle(tk.Frame):
    """Compact segmented toggle (used for weekday selection)."""

    def __init__(self, master, text, variable, C, F, on_change=None):
        super().__init__(master, bd=0, cursor="hand2")
        self._var = variable
        self._C = C
        self._on_change = on_change
        self._lbl = tk.Label(self, text=text, font=F["small_b"], bd=0,
                             cursor="hand2")
        self._lbl.pack(padx=13, pady=5)
        self._var.trace_add("write", lambda *_: self._update())
        self._update()
        for w in (self, self._lbl):
            w.bind("<Button-1>", self._toggle)
            w.bind("<Enter>", self._enter)
            w.bind("<Leave>", self._leave)

    def _toggle(self, _e=None):
        self._var.set(not self._var.get())
        if self._on_change:
            self._on_change()

    def _enter(self, _e):
        if not self._var.get():
            C = self._C
            self.configure(bg=C["surface3"])
            self._lbl.configure(bg=C["surface3"], fg=C["text"])

    def _leave(self, _e):
        self._update()

    def _update(self):
        C = self._C
        if self._var.get():
            bg, fg = C["accent"], "#ffffff"
        else:
            bg, fg = C["surface2"], C["text_sec"]
        self.configure(bg=bg)
        self._lbl.configure(bg=bg, fg=fg)
