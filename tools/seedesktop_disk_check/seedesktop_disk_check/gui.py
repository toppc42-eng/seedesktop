"""
Tkinter UI: drives + SMART preview, tests with confirmations, reports tab.
"""

from __future__ import annotations

import traceback
from datetime import datetime
from tkinter import messagebox, ttk
import tkinter as tk
from seedesktop_disk_check.settings_store import load_font_size, save_font_size
from seedesktop_disk_check.win_disks import (
    DriveInfo,
    enumerate_fixed_drives,
    tests_for_drive,
)

_UI_FONT = "Segoe UI"
_MONO_FONT = "Consolas"


class ReportEntry:
    __slots__ = ("title", "body", "created")

    def __init__(self, title: str, body: str) -> None:
        self.title = title
        self.body = body
        self.created = datetime.now()


class DiskCheckApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        root.title("SeeDesktop — בדיקת כוננים")
        root.minsize(780, 560)
        root.geometry("920x700")

        self._drives: list[DriveInfo] = []
        self._selected: DriveInfo | None = None
        self._reports: list[ReportEntry] = []

        self._font_size = load_font_size()
        self._style = ttk.Style(self.root)

        self._build()
        self._apply_font_size()

    def _sync_scroll_region(self, _event=None) -> None:
        if getattr(self, "_scroll_canvas", None) is None:
            return
        self.root.update_idletasks()
        self._scroll_canvas.configure(scrollregion=self._scroll_canvas.bbox("all"))

    def _on_font_spin_commit(self, _evt=None) -> None:
        try:
            v = int(self._font_var.get().strip())
        except ValueError:
            self._font_var.set(str(self._font_size))
            return
        v = max(8, min(24, v))
        if v != self._font_size:
            self._font_size = v
            self._font_var.set(str(v))
            self._apply_font_size()
            try:
                save_font_size(v)
            except Exception:
                pass
        else:
            self._font_var.set(str(self._font_size))

    def _apply_font_size(self) -> None:
        sz = self._font_size

        self._style.configure("TLabel", font=(_UI_FONT, sz))
        self._style.configure("TButton", font=(_UI_FONT, sz))
        self._style.configure("TNotebook.Tab", font=(_UI_FONT, sz))
        self._style.configure("TLabelframe.Label", font=(_UI_FONT, sz))
        try:
            self._style.configure(
                "Treeview",
                font=(_UI_FONT, sz),
                rowheight=max(22, int(sz * 1.85)),
            )
        except tk.TclError:
            self._style.configure("Treeview", font=(_UI_FONT, sz))
        self._style.configure("Treeview.Heading", font=(_UI_FONT, sz, "bold"))

        self._detail.configure(font=(_UI_FONT, sz))
        self._rep_list.configure(font=(_UI_FONT, sz))
        self._rep_body.configure(font=(_MONO_FONT, sz))

        try:
            self._font_spin.configure(font=(_UI_FONT, sz))
        except tk.TclError:
            pass

        if self._selected is not None:
            self._show_drive_detail(self._selected)
        else:
            self._set_detail_text(
                "בחר כונן מהרשימה כדי לראות פרטי SMART/בריאות ובדיקות."
            )
        self._rebuild_test_buttons()

    def _build(self) -> None:
        bar = tk.Frame(self.root)
        bar.pack(side=tk.TOP, fill=tk.X, padx=8, pady=8)

        font_row = tk.Frame(bar)
        font_row.pack(side=tk.LEFT)
        ttk.Label(font_row, text="גודל גופן:").pack(side=tk.RIGHT, padx=(0, 6))
        self._font_var = tk.StringVar(value=str(self._font_size))
        self._font_spin = tk.Spinbox(
            font_row,
            from_=8,
            to=24,
            width=4,
            textvariable=self._font_var,
            justify=tk.CENTER,
            command=self._on_font_spin_commit,
        )
        self._font_spin.pack(side=tk.RIGHT)
        self._font_spin.bind("<Return>", lambda e: self._on_font_spin_commit())
        self._font_spin.bind("<FocusOut>", lambda e: self._on_font_spin_commit())

        ttk.Button(bar, text="רענון רשימת כוננים", command=self._refresh_drives).pack(
            side=tk.RIGHT
        )

        outer = tk.Frame(self.root)
        outer.pack(fill=tk.BOTH, expand=True)

        self._scroll_canvas = tk.Canvas(outer, highlightthickness=0)
        vsb = ttk.Scrollbar(outer, orient=tk.VERTICAL, command=self._scroll_canvas.yview)
        self._scroll_inner = tk.Frame(self._scroll_canvas)
        self._scroll_window = self._scroll_canvas.create_window(
            (0, 0),
            window=self._scroll_inner,
            anchor=tk.NW,
        )

        def _on_inner_cfg(_e=None) -> None:
            self._scroll_canvas.configure(scrollregion=self._scroll_canvas.bbox("all"))

        def _on_canvas_cfg(e) -> None:
            self._scroll_canvas.itemconfig(self._scroll_window, width=e.width)

        self._scroll_inner.bind("<Configure>", _on_inner_cfg)
        self._scroll_canvas.bind("<Configure>", _on_canvas_cfg)

        def _wheel(e) -> None:
            self._scroll_canvas.yview_scroll(int(-1 * (e.delta / 120)), "units")

        self._scroll_canvas.bind("<Enter>", lambda _e: self._scroll_canvas.bind_all("<MouseWheel>", _wheel))
        self._scroll_canvas.bind("<Leave>", lambda _e: self._scroll_canvas.unbind_all("<MouseWheel>"))

        self._scroll_canvas.configure(yscrollcommand=vsb.set)
        self._scroll_canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        vsb.pack(side=tk.RIGHT, fill=tk.Y)

        nb = ttk.Notebook(self._scroll_inner)
        nb.pack(fill=tk.X, padx=8, pady=(0, 8))
        nb.bind("<<NotebookTabChanged>>", lambda _e: self._sync_scroll_region())

        self._tab_drives = tk.Frame(nb)
        self._tab_reports = tk.Frame(nb)
        nb.add(self._tab_drives, text="כוננים ובדיקות")
        nb.add(self._tab_reports, text="דוחות")

        self._build_drives_tab()
        self._build_reports_tab()

        self._refresh_drives()
        self.root.after(200, self._sync_scroll_region)

    def _build_drives_tab(self) -> None:
        upper = tk.Frame(self._tab_drives, height=400)
        upper.pack(fill=tk.X)
        upper.pack_propagate(False)

        paned = ttk.PanedWindow(upper, orient=tk.HORIZONTAL)
        paned.pack(fill=tk.BOTH, expand=True)

        left = ttk.LabelFrame(paned, text="כוננים קבועים")
        paned.add(left, weight=1)

        cols = ("letter", "health", "size")
        self._tree = ttk.Treeview(
            left,
            columns=cols,
            show="headings",
            selectmode="browse",
            height=12,
        )
        self._tree.heading("letter", text="כונן")
        self._tree.heading("health", text="בריאות / מצב")
        self._tree.heading("size", text="גודל")
        self._tree.column("letter", width=70, anchor=tk.CENTER)
        self._tree.column("health", width=160, anchor=tk.CENTER)
        self._tree.column("size", width=100, anchor=tk.CENTER)
        sy = ttk.Scrollbar(left, orient=tk.VERTICAL, command=self._tree.yview)
        self._tree.configure(yscrollcommand=sy.set)
        self._tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        sy.pack(side=tk.RIGHT, fill=tk.Y)

        self._tree.bind("<<TreeviewSelect>>", self._on_select_drive)

        right = ttk.Frame(paned)
        paned.add(right, weight=2)

        self._detail = tk.Text(
            right,
            height=12,
            wrap=tk.WORD,
            font=(_UI_FONT, self._font_size),
            state=tk.DISABLED,
        )
        dy = ttk.Scrollbar(right, orient=tk.VERTICAL, command=self._detail.yview)
        self._detail.configure(yscrollcommand=dy.set)
        self._detail.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        dy.pack(side=tk.RIGHT, fill=tk.Y)

        tests_frame = ttk.LabelFrame(self._tab_drives, text="בדיקות לכונן הנבחר")
        tests_frame.pack(fill=tk.X, pady=(8, 0))

        self._tests_container = tk.Frame(tests_frame)
        self._tests_container.pack(fill=tk.X, padx=6, pady=6)

    def _build_reports_tab(self) -> None:
        split = ttk.PanedWindow(self._tab_reports, orient=tk.HORIZONTAL)
        split.pack(fill=tk.BOTH, expand=True)

        list_fr = ttk.LabelFrame(split, text="רשימת דוחות")
        split.add(list_fr, weight=1)

        self._rep_list = tk.Listbox(
            list_fr,
            font=(_UI_FONT, self._font_size),
            exportselection=False,
        )
        rs = ttk.Scrollbar(list_fr, orient=tk.VERTICAL, command=self._rep_list.yview)
        self._rep_list.configure(yscrollcommand=rs.set)
        self._rep_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        rs.pack(side=tk.RIGHT, fill=tk.Y)
        self._rep_list.bind("<<ListboxSelect>>", self._on_report_pick)

        body_fr = ttk.LabelFrame(split, text="תוכן הדוח")
        split.add(body_fr, weight=3)

        self._rep_body = tk.Text(
            body_fr,
            wrap=tk.WORD,
            font=(_MONO_FONT, self._font_size),
            state=tk.DISABLED,
        )
        rb = ttk.Scrollbar(body_fr, orient=tk.VERTICAL, command=self._rep_body.yview)
        self._rep_body.configure(yscrollcommand=rb.set)
        self._rep_body.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        rb.pack(side=tk.RIGHT, fill=tk.Y)

        bf = tk.Frame(self._tab_reports)
        bf.pack(fill=tk.X, pady=6)
        ttk.Button(bf, text="נקה דוחות מהמסך", command=self._clear_reports).pack(
            side=tk.RIGHT
        )

    def _clear_reports(self) -> None:
        self._reports.clear()
        self._rep_list.delete(0, tk.END)
        self._rep_body.configure(state=tk.NORMAL)
        self._rep_body.delete("1.0", tk.END)
        self._rep_body.configure(state=tk.DISABLED)

    def _on_report_pick(self, _evt=None) -> None:
        sel = self._rep_list.curselection()
        if not sel:
            return
        i = int(sel[0])
        if i < 0 or i >= len(self._reports):
            return
        r = self._reports[i]
        self._rep_body.configure(state=tk.NORMAL)
        self._rep_body.delete("1.0", tk.END)
        self._rep_body.insert(tk.END, r.body)
        self._rep_body.configure(state=tk.DISABLED)

    def _refresh_drives(self) -> None:
        try:
            self._drives = enumerate_fixed_drives()
        except Exception as e:
            messagebox.showerror("שגיאה", f"לא ניתן לטעון כוננים:\n{e}")
            self._drives = []

        for x in self._tree.get_children():
            self._tree.delete(x)
        for d in self._drives:
            gb = d.size_bytes / (1024**3) if d.size_bytes else 0
            health = d.health_status or "—"
            if d.operational_status:
                health = f"{health} / {d.operational_status}"
            self._tree.insert(
                "",
                tk.END,
                values=(f"{d.letter}:", health, f"{gb:.1f} GB"),
            )

        self._selected = None
        self._set_detail_text("בחר כונן מהרשימה כדי לראות פרטי SMART/בריאות ובדיקות.")
        self._rebuild_test_buttons()

    def _on_select_drive(self, _evt=None) -> None:
        sel = self._tree.selection()
        if not sel:
            return
        idx = self._tree.index(sel[0])
        if idx < 0 or idx >= len(self._drives):
            return
        self._selected = self._drives[idx]
        self._show_drive_detail(self._selected)
        self._rebuild_test_buttons()

    def _set_detail_text(self, s: str) -> None:
        self._detail.configure(state=tk.NORMAL)
        self._detail.delete("1.0", tk.END)
        self._detail.insert(tk.END, s)
        self._detail.configure(state=tk.DISABLED)

    def _show_drive_detail(self, d: DriveInfo) -> None:
        free_gb = d.free_bytes / (1024**3) if d.free_bytes else 0
        total_gb = d.size_bytes / (1024**3) if d.size_bytes else 0
        lines = [
            f"כונן: {d.letter}:",
            f"תווית: {d.label or '—'}",
            f"מערכת קבצים: {d.filesystem or '—'}",
            f"נפח: {total_gb:.2f} GB פנוי {free_gb:.2f} GB",
            "",
            "--- מצב דיסק פיזי (לפני בדיקות) ---",
            f"מספר דיסק: {d.disk_number if d.disk_number is not None else '—'}",
            f"דגם: {d.model or '—'}",
            f"סריאלי: {d.serial_number or '—'}",
            f"סוג מדיה: {d.media_type or '—'}",
            f"HealthStatus: {d.health_status or '—'}",
            f"OperationalStatus: {d.operational_status or '—'}",
            "",
            "--- תצוגה מקדימה של מוני אמינות (SMART-like) ---",
            d.smart_preview or "(אין נתונים)",
        ]
        self._set_detail_text("\n".join(lines))

    def _rebuild_test_buttons(self) -> None:
        for w in self._tests_container.winfo_children():
            w.destroy()

        d = self._selected
        if d is None:
            ttk.Label(
                self._tests_container,
                text="בחר כונן כדי להפעיל בדיקות.",
                style="TLabel",
            ).pack(anchor=tk.W)
            self.root.after(50, self._sync_scroll_region)
            return

        fs = (d.filesystem or "").upper()
        warn = ""
        if fs and fs not in ("NTFS", "REFS"):
            warn = f"מערכת הקבצים היא {fs} — חלק מהבדיקות (CHKDSK) עשויות להתנהג אחרת מ-NTFS.\n\n"

        for test in tests_for_drive(d):
            fr = ttk.Frame(self._tests_container)
            fr.pack(fill=tk.X, pady=4)

            title = tk.Text(
                fr,
                height=2,
                wrap=tk.WORD,
                font=(_UI_FONT, self._font_size, "bold"),
                relief=tk.FLAT,
                background=self.root.cget("bg"),
            )
            title.insert(tk.END, test.title)
            title.configure(state=tk.DISABLED, cursor="arrow")
            title.pack(fill=tk.X)

            sub = tk.Text(
                fr,
                height=3,
                wrap=tk.WORD,
                font=(_UI_FONT, max(8, self._font_size - 1)),
                relief=tk.FLAT,
                background=self.root.cget("bg"),
                fg="#333",
            )
            sub.insert(tk.END, warn + test.explain)
            sub.configure(state=tk.DISABLED, cursor="arrow")
            sub.pack(fill=tk.X)

            btn = ttk.Button(
                fr,
                text="הרצה וביצוע דוח…",
                command=lambda t=test: self._confirm_and_run(t),
            )
            btn.pack(anchor=tk.W, pady=(4, 0))

        self.root.after(50, self._sync_scroll_region)

    def _confirm_and_run(self, test) -> None:
        d = self._selected
        if d is None:
            return
        msg = (
            f"{test.title}\n\n"
            f"מה הבדיקה עושה:\n{test.explain}\n\n"
            f"לפני שמריצים:\n{test.before_you_run}\n\n"
            f"כונן: {d.letter}:\n\n"
            "להמשיך?"
        )
        if not messagebox.askokcancel("אישור בדיקה", msg):
            return
        self.root.config(cursor="watch")
        self.root.update_idletasks()
        try:
            out = test.runner(d.letter)
        except Exception as e:
            out = f"שגיאה בהרצה:\n{e}\n\n{traceback.format_exc()}"
        finally:
            self.root.config(cursor="")

        title = f"{datetime.now():%Y-%m-%d %H:%M} — {d.letter}: — {test.title}"
        body = (
            f"כונן: {d.letter}:\n"
            f"בדיקה: {test.title}\n"
            f"---\n\n"
            f"{out}"
        )
        self._reports.append(ReportEntry(title, body))
        self._rep_list.insert(tk.END, title)
        self._rep_list.selection_clear(0, tk.END)
        self._rep_list.selection_set(tk.END)
        self._rep_list.see(tk.END)
        self._on_report_pick()

        messagebox.showinfo("הושלם", "הבדיקה הסתיימה. הדוח נוסף לטאב «דוחות».")

    def run(self) -> None:
        self.root.mainloop()


def main() -> None:
    root = tk.Tk()
    try:
        root.tk.call("tk", "scaling", 1.15)
    except tk.TclError:
        pass
    DiskCheckApp(root).run()
