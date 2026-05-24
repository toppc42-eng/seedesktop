"""
Tkinter UI: run SFC /scannow, on failure run DISM, save report, optional 2nd SFC.
"""

from __future__ import annotations

import queue
import sys
import threading
import tkinter as tk
from tkinter import messagebox, scrolledtext, ttk

from seedesktop_system_repair.paths import last_report_link, new_report_path, reports_dir
from seedesktop_system_repair.runner import (
    build_report_header,
    is_windows_admin,
    run_dism_restorehealth,
    run_sfc_scannow,
    sfc_suggests_run_dism,
)


class SystemRepairApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        root.title("SeeDesktop — בדיקת קבצי מערכת (SFC / DISM)")
        root.minsize(640, 480)
        root.geometry("820x620")

        self._q: queue.Queue[str | None] = queue.Queue()
        self._busy = False

        self._build()
        self.root.after(100, self._drain_log_queue)

        if not is_windows_admin():
            messagebox.showwarning(
                "הרשאות מנהל",
                "מומלץ להפעיל את התוכנה כמנהל (לחיצה ימנית → הפעלה כמנהל).\n"
                "ללא כך SFC ו-DISM עלולים להיכשל.",
            )

    def _build(self) -> None:
        top = ttk.Frame(self.root, padding=8)
        top.pack(fill=tk.X)

        ttk.Label(
            top,
            text=(
                "שלב 1: sfc /scannow — בודק קבצי מערכת.\n"
                "אם נכשל (קוד יציאה ≠ 0) או מופיעה הודעת כשל ידועה בלוג — "
                "שלב 2 אוטומטי: DISM /Online /Cleanup-Image /RestoreHealth.\n"
                "לאחר DISM — שלב 3: sfc שוב לאימות."
            ),
            wraplength=780,
            justify=tk.RIGHT,
        ).pack(anchor=tk.E, fill=tk.X)

        bar = ttk.Frame(self.root, padding=8)
        bar.pack(fill=tk.X)

        self._btn_run = ttk.Button(
            bar,
            text="התחל בדיקה (SFC → DISM במידת הצורך → SFC)",
            command=self._start_run,
        )
        self._btn_run.pack(side=tk.RIGHT, padx=4)

        ttk.Button(
            bar,
            text="פתח תיקיית דוחות",
            command=self._open_reports_dir,
        ).pack(side=tk.RIGHT, padx=4)

        self._status = ttk.Label(bar, text="מוכן.")
        self._status.pack(side=tk.LEFT)

        self._log = scrolledtext.ScrolledText(
            self.root,
            wrap=tk.WORD,
            font=("Consolas", 10),
            height=28,
        )
        self._log.pack(fill=tk.BOTH, expand=True, padx=8, pady=(0, 8))

    def _append_log(self, s: str) -> None:
        self._log.insert(tk.END, s)
        self._log.see(tk.END)

    def _drain_log_queue(self) -> None:
        try:
            while True:
                item = self._q.get_nowait()
                if item is None:
                    self._on_run_finished()
                    break
                self._append_log(item)
        except queue.Empty:
            pass
        self.root.after(80, self._drain_log_queue)

    def _emit(self, s: str) -> None:
        self._q.put(s)

    def _start_run(self) -> None:
        if self._busy:
            return
        if not messagebox.askokcancel(
            "אישור",
            "הבדיקה עלולה להימשך זמן רב (עשרות דקות).\n"
            "המחשב יישאר בשימוש — לא לכבות.\n\nלהתחיל?",
        ):
            return
        self._busy = True
        self._btn_run.configure(state=tk.DISABLED)
        self._status.configure(text="רץ…")
        self._log.delete("1.0", tk.END)

        def worker() -> None:
            report: list[str] = []

            def out(s: str) -> None:
                report.append(s)
                self._emit(s)

            def log_fn(line: str) -> None:
                report.append(line)
                self._emit(line)

            try:
                out(build_report_header())
                out("\n=== [1] SFC /scannow ===\n\n")
                code1 = run_sfc_scannow(log_fn)
                text1 = "".join(report)

                need_dism = sfc_suggests_run_dism(text1, code1)
                out(
                    f"\n(ניתוח אוטומטי: {'מריצים DISM' if need_dism else 'לא הופעל DISM (לפי קוד יציאה והלוג)'})\n"
                )

                if need_dism:
                    out("\n=== [2] DISM /Online /Cleanup-Image /RestoreHealth ===\n\n")
                    run_dism_restorehealth(log_fn)
                    out("\n=== [3] SFC /scannow (אחרי DISM) ===\n\n")
                    run_sfc_scannow(log_fn)

                path = new_report_path()
                path.write_text("".join(report), encoding="utf-8")
                last = last_report_link()
                last.write_text(
                    f"Latest report:\n{path.resolve()}\n",
                    encoding="utf-8",
                )
                out(
                    f"\n\n=== נשמר דוח ===\n{path}\n"
                    f"(קיצור: {last})\n"
                )
            except Exception as e:
                out(f"\n\n*** שגיאה: {e}\n")
            finally:
                self._q.put(None)

        threading.Thread(target=worker, daemon=True).start()

    def _on_run_finished(self) -> None:
        self._busy = False
        self._btn_run.configure(state=tk.NORMAL)
        self._status.configure(text="הסתיים. ראה דוח בתיקייה.")

    def _open_reports_dir(self) -> None:
        p = reports_dir()
        p.mkdir(parents=True, exist_ok=True)
        try:
            import os

            os.startfile(str(p))  # type: ignore[attr-defined]
        except Exception as e:
            messagebox.showerror("שגיאה", str(e))


def main() -> None:
    if sys.platform != "win32":
        print("Windows only.")
        sys.exit(1)
    root = tk.Tk()
    try:
        root.tk.call("tk", "scaling", 1.1)
    except tk.TclError:
        pass
    SystemRepairApp(root)
    root.mainloop()
