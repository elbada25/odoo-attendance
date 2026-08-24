"""Date and time picker widgets for tkinter.

Provides:
  - DateEntry: entry with a calendar popup (YYYY-MM-DD), still typeable.
  - TimeEntry: entry with a time dropdown popup (HH:MM), still typeable.

Both widgets keep the entry fully editable by keyboard. A small button
on the right opens a popup picker for mouse-based selection.
"""

from __future__ import annotations

import calendar
from datetime import date, datetime
import tkinter as tk
from tkinter import ttk


class CalendarPopup(tk.Toplevel):
    """A simple calendar popup that returns a date string to a callback."""

    def __init__(self, parent, current_date: date, on_select, colors: dict):
        super().__init__(parent)
        self._on_select = on_select
        self._colors = colors
        self._view_year = current_date.year
        self._view_month = current_date.month
        self._selected_day = current_date.day

        self.overrideredirect(True)
        self.resizable(False, False)
        self.attributes("-topmost", True)
        self.configure(bg=colors["surface"])

        # Position near parent
        px = parent.winfo_rootx()
        py = parent.winfo_rooty() + parent.winfo_height()
        self.geometry(f"+{px}+{py}")

        self._build()
        self.bind("<FocusOut>", lambda e: self.destroy())
        self.focus_set()

    def _build(self):
        C = self._colors
        header = tk.Frame(self, bg=C["surface"])
        header.pack(fill="x", padx=2, pady=2)

        btn_style = dict(bg=C["surface"], fg=C["text"], relief="flat",
                         padx=8, pady=2, font=("Segoe UI", 9), activebackground=C["btn_hov"])

        prev = tk.Button(header, text="<", command=self._prev_month, **btn_style)
        prev.pack(side="left")
        self._month_label = tk.Label(
            header, text="", bg=C["surface"], fg=C["text"],
            font=("Segoe UI", 9, "bold"), width=18)
        self._month_label.pack(side="left", fill="x", expand=True)
        nxt = tk.Button(header, text=">", command=self._next_month, **btn_style)
        nxt.pack(side="right")

        # Day grid
        grid = tk.Frame(self, bg=C["surface"])
        grid.pack(fill="both", padx=4, pady=(0, 4))
        for c, name in enumerate(["L", "M", "X", "J", "V", "S", "D"]):
            tk.Label(grid, text=name, bg=C["surface"], fg=C["text_sec"],
                     font=("Segoe UI", 8), width=4).grid(
                row=0, column=c, padx=1, pady=(0, 2))
        self._day_buttons: list[tk.Button] = []
        self._update_grid(grid)
        self._update_label()

    def _update_label(self):
        names = ["Enero", "Febrero", "Marzo", "Abril", "Mayo", "Junio",
                 "Julio", "Agosto", "Septiembre", "Octubre", "Noviembre", "Diciembre"]
        self._month_label.config(text=f"{names[self._view_month - 1]} {self._view_year}")

    def _update_grid(self, parent):
        C = self._colors
        for btn in self._day_buttons:
            btn.destroy()
        self._day_buttons.clear()

        cal = calendar.monthcalendar(self._view_year, self._view_month)
        for r, week in enumerate(cal):
            for c, day in enumerate(week):
                if day == 0:
                    tk.Label(parent, text="", bg=C["surface"], width=4).grid(
                        row=r + 1, column=c, padx=1, pady=1)
                else:
                    is_today = (day == self._selected_day and
                                self._view_month == date.today().month and
                                self._view_year == date.today().year)
                    bg = C["primary"] if is_today else C["surface"]
                    fg = "white" if is_today else C["text"]
                    btn = tk.Button(
                        parent, text=str(day), bg=bg, fg=fg, relief="flat",
                        width=4, font=("Segoe UI", 9),
                        activebackground=C["btn_hov"],
                        command=lambda d=day: self._pick(d))
                    btn.grid(row=r + 1, column=c, padx=1, pady=1)
                    self._day_buttons.append(btn)

    def _prev_month(self):
        self._view_month -= 1
        if self._view_month < 1:
            self._view_month = 12
            self._view_year -= 1
        self._update_grid(self._day_buttons[0].master if self._day_buttons else None)
        self._update_label()

    def _next_month(self):
        self._view_month += 1
        if self._view_month > 12:
            self._view_month = 1
            self._view_year += 1
        self._update_grid(self._day_buttons[0].master if self._day_buttons else None)
        self._update_label()

    def _pick(self, day: int):
        d = date(self._view_year, self._view_month, day)
        self._on_select(d.strftime("%Y-%m-%d"))
        self.destroy()


class DateEntry(ttk.Frame):
    """Entry + calendar button. Entry remains fully editable by keyboard."""

    def __init__(self, master, textvariable, colors, fonts, width=14, **kw):
        super().__init__(master, style="TFrame", **kw)
        self._var = textvariable
        self._C = colors
        self._F = fonts

        from widgets import ModernEntry
        self._entry = ModernEntry(self, colors, fonts,
                                  textvariable=textvariable, width=width)
        self._entry.pack(side="left", ipady=2)

        btn = tk.Button(
            self, text="\U0001F4C5", width=3, relief="flat",
            bg=colors["btn_bg"], fg=colors["text"],
            activebackground=colors["btn_hov"],
            font=("Segoe UI", 8), command=self._open_calendar)
        btn.pack(side="left", padx=(2, 0))

    def _open_calendar(self):
        val = self._var.get().strip()
        try:
            d = datetime.strptime(val, "%Y-%m-%d").date()
        except ValueError:
            d = date.today()
        CalendarPopup(self._entry, d, self._on_date_picked, self._C)

    def _on_date_picked(self, date_str: str):
        self._var.set(date_str)


class TimePopup(tk.Toplevel):
    """A simple time picker popup with hour/minute spinboxes."""

    def __init__(self, parent, current_time: str, on_select, colors: dict):
        super().__init__(parent)
        self._on_select = on_select
        self._C = colors

        self.overrideredirect(True)
        self.resizable(False, False)
        self.attributes("-topmost", True)
        self.configure(bg=colors["surface"])

        px = parent.winfo_rootx()
        py = parent.winfo_rooty() + parent.winfo_height()
        self.geometry(f"+{px}+{py}")

        try:
            h, m = current_time.split(":")
            h, m = int(h), int(m)
        except (ValueError, AttributeError):
            h, m = 9, 0

        frame = tk.Frame(self, bg=colors["surface"])
        frame.pack(padx=12, pady=10)

        self._hour = tk.StringVar(value=f"{h:02d}")
        self._minute = tk.StringVar(value=f"{m:02d}")

        def _make_spin(var, max_val):
            f = tk.Frame(self, bg=colors["surface"])
            up = tk.Button(f, text="\u25B2", width=3, relief="flat",
                           bg=colors["btn_bg"], fg=colors["text"],
                           activebackground=colors["btn_hov"],
                           font=("Segoe UI", 7),
                           command=lambda: var.set(
                               f"{(int(var.get()) + 1) % (max_val + 1):02d}"))
            up.pack()
            entry = tk.Entry(f, textvariable=var, width=4, justify="center",
                             bg=colors["input_bg"], fg=colors["text"],
                             relief="flat", font=("Segoe UI", 11, "bold"),
                             insertbackground=colors["text"])
            entry.pack(pady=2)
            dn = tk.Button(f, text="\u25BC", width=3, relief="flat",
                           bg=colors["btn_bg"], fg=colors["text"],
                           activebackground=colors["btn_hov"],
                           font=("Segoe UI", 7),
                           command=lambda: var.set(
                               f"{(int(var.get()) - 1) % (max_val + 1):02d}"))
            dn.pack()
            return f

        _make_spin(self._hour, 23).pack(side="left", padx=4)
        tk.Label(self, text=":", bg=colors["surface"], fg=colors["text"],
                 font=("Segoe UI", 14, "bold")).pack(side="left")
        _make_spin(self._minute, 59).pack(side="left", padx=4)

        ok = tk.Button(self, text="Aceptar", relief="flat",
                       bg=colors["primary"], fg="white",
                       activebackground=colors["primary_hov"],
                       font=("Segoe UI", 9, "bold"), padx=12, pady=4,
                       command=self._confirm)
        ok.pack(pady=(8, 0))

        self.bind("<FocusOut>", lambda e: self.destroy())
        self.focus_set()

    def _confirm(self):
        try:
            h = int(self._hour.get())
            m = int(self._minute.get())
            self._on_select(f"{h:02d}:{m:02d}")
        except ValueError:
            pass
        self.destroy()


class TimeEntry(ttk.Frame):
    """Entry + clock button. Entry remains fully editable by keyboard."""

    def __init__(self, master, textvariable, colors, fonts, width=10, **kw):
        super().__init__(master, style="TFrame", **kw)
        self._var = textvariable
        self._C = colors
        self._F = fonts

        from widgets import ModernEntry
        self._entry = ModernEntry(self, colors, fonts,
                                  textvariable=textvariable, width=width)
        self._entry.pack(side="left", ipady=2)

        btn = tk.Button(
            self, text="\U0001F552", width=3, relief="flat",
            bg=colors["btn_bg"], fg=colors["text"],
            activebackground=colors["btn_hov"],
            font=("Segoe UI", 8), command=self._open_time)
        btn.pack(side="left", padx=(2, 0))

    def _open_time(self):
        TimePopup(self._entry, self._var.get(), self._on_time_picked, self._C)

    def _on_time_picked(self, time_str: str):
        self._var.set(time_str)
