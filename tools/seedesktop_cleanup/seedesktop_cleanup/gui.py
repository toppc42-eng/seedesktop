"""Hebrew GUI: sidebar options + log + schedule panel."""

from __future__ import annotations

import threading
import tkinter as tk
from tkinter import messagebox, scrolledtext, ttk

from .cleaners import (
    CATEGORY_GROUPS_HE,
    CATEGORY_LABELS_HE,
    export_predelete_manifest,
    format_bytes,
    run_selected,
)
from .config_store import load_config, save_config
from .scheduler_win import install_schedule, query_task_exists, remove_schedule


def run_gui() -> None:
    root = tk.Tk()
    root.title("SeeDesktop — ניקוי מחשב")
    root.minsize(780, 520)
    root.geometry("900x600")

    style = ttk.Style()
    if "vista" in style.theme_names():
        style.theme_use("vista")

    cfg = load_config()
    cat_vars: dict[str, tk.BooleanVar] = {}
    for k, v in cfg["categories"].items():
        cat_vars[k] = tk.BooleanVar(value=v)

    opts = cfg.get("options", {})
    backup_manifest = tk.BooleanVar(
        value=bool(opts.get("backup_manifest_before_run", False))
    )

    sched = cfg["schedule"]
    sched_enabled = tk.BooleanVar(value=sched.get("enabled", False))
    sched_mode = tk.StringVar(value=sched.get("mode", "daily"))
    sched_hour = tk.IntVar(value=int(sched.get("hour", 2)))
    sched_minute = tk.IntVar(value=int(sched.get("minute", 0)))
    sched_weekday = tk.IntVar(value=int(sched.get("weekday", 0)))
    sched_monthday = tk.IntVar(value=int(sched.get("monthday", 1)))

    main_pane = ttk.PanedWindow(root, orient=tk.HORIZONTAL)
    main_pane.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)

    # --- Sidebar ---
    left = ttk.Frame(main_pane, width=300)
    main_pane.add(left, weight=0)

    ttk.Label(
        left,
        text="מה לנקות",
        font=("Segoe UI", 12, "bold"),
    ).pack(anchor=tk.W, pady=(0, 6))
    ttk.Checkbutton(
        left,
        text="שמור manifest טקסטואלי לפני ניקוי (%LOCALAPPDATA%\\SeeDesktopCleanup\\manifests)",
        variable=backup_manifest,
    ).pack(anchor=tk.W, pady=(0, 8))

    canvas = tk.Canvas(left, highlightthickness=0)
    scroll = ttk.Scrollbar(left, orient=tk.VERTICAL, command=canvas.yview)
    inner = ttk.Frame(canvas)
    inner.bind(
        "<Configure>",
        lambda e: canvas.configure(scrollregion=canvas.bbox("all")),
    )
    canvas.create_window((0, 0), window=inner, anchor=tk.NW)
    canvas.configure(yscrollcommand=scroll.set)

    for group_title, keys in CATEGORY_GROUPS_HE:
        lf = ttk.LabelFrame(inner, text=group_title, padding=(6, 8))
        lf.pack(fill=tk.X, pady=(4, 8), padx=0)
        for key in keys:
            if key not in cat_vars:
                cat_vars[key] = tk.BooleanVar(value=False)
            row = ttk.Frame(lf)
            row.pack(fill=tk.X, pady=1)
            ttk.Checkbutton(
                row,
                text=CATEGORY_LABELS_HE[key],
                variable=cat_vars[key],
            ).pack(anchor=tk.W)

    canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
    scroll.pack(side=tk.RIGHT, fill=tk.Y)

    def _on_mousewheel(event):
        canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

    canvas.bind_all("<MouseWheel>", _on_mousewheel)

    # --- Right: notebook ---
    right = ttk.Frame(main_pane)
    main_pane.add(right, weight=1)

    nb = ttk.Notebook(right)
    nb.pack(fill=tk.BOTH, expand=True)

    tab_clean = ttk.Frame(nb)
    tab_sched = ttk.Frame(nb)
    nb.add(tab_clean, text="ניקוי")
    nb.add(tab_sched, text="תזמון")

    log = scrolledtext.ScrolledText(
        tab_clean,
        wrap=tk.WORD,
        font=("Consolas", 10),
        height=20,
    )
    log.pack(fill=tk.BOTH, expand=True, pady=(0, 8))

    btn_row = ttk.Frame(tab_clean)
    btn_row.pack(fill=tk.X)

    running = {"v": False}

    def save_cats():
        data = load_config()
        data["categories"] = {k: v.get() for k, v in cat_vars.items()}
        data.setdefault("options", {})
        data["options"]["backup_manifest_before_run"] = backup_manifest.get()
        save_config(data)

    def do_run():
        if running["v"]:
            return
        running["v"] = True
        save_cats()
        log.delete("1.0", tk.END)
        log.insert(tk.END, "מריץ ניקוי…\n")

        def work():
            cats = {k: v.get() for k, v in cat_vars.items()}
            total = 0
            try:
                if backup_manifest.get():
                    mp = export_predelete_manifest(cats)
                    if mp is not None:
                        mmsg = f"נשמר manifest לפני ניקוי: {mp}\n"
                        root.after(0, lambda m=mmsg: log.insert(tk.END, m))
                for _key, freed, label in run_selected(cats):
                    total += freed
                    msg = f"✓ {label}: {format_bytes(freed)}\n"
                    root.after(0, lambda m=msg: log.insert(tk.END, m))
                sum_msg = f"\nסה\"כ משוחרר (הערכה): {format_bytes(total)}\n"
                root.after(0, lambda s=sum_msg: log.insert(tk.END, s))
            except Exception as e:
                err = f"\nשגיאה: {e}\n"
                root.after(0, lambda m=err: log.insert(tk.END, m))
            finally:
                running["v"] = False
                root.after(0, lambda: log.see(tk.END))

        threading.Thread(target=work, daemon=True).start()

    ttk.Button(btn_row, text="שמור בחירה", command=save_cats).pack(
        side=tk.LEFT, padx=(0, 8)
    )
    ttk.Button(btn_row, text="הרץ ניקוי עכשיו", command=do_run).pack(side=tk.LEFT)

    # --- Schedule tab ---
    sf = ttk.Frame(tab_sched, padding=10)
    sf.pack(fill=tk.BOTH, expand=True)

    ttk.Checkbutton(
        sf,
        text="הפעל ניקוי מתוזמן (משימת Windows)",
        variable=sched_enabled,
    ).pack(anchor=tk.W)

    mode_fr = ttk.LabelFrame(sf, text="תדירות", padding=8)
    mode_fr.pack(fill=tk.X, pady=8)
    for val, lab in (
        ("daily", "יומי"),
        ("weekly", "שבועי"),
        ("monthly", "חודשי"),
    ):
        ttk.Radiobutton(
            mode_fr,
            text=lab,
            value=val,
            variable=sched_mode,
        ).pack(anchor=tk.W)

    time_fr = ttk.LabelFrame(sf, text="שעה", padding=8)
    time_fr.pack(fill=tk.X, pady=4)
    ttk.Label(time_fr, text="שעה (0–23):").grid(row=0, column=0, sticky=tk.W)
    ttk.Spinbox(
        time_fr,
        from_=0,
        to=23,
        textvariable=sched_hour,
        width=5,
    ).grid(row=0, column=1, padx=8)
    ttk.Label(time_fr, text="דקות (0–59):").grid(row=0, column=2)
    ttk.Spinbox(
        time_fr,
        from_=0,
        to=59,
        textvariable=sched_minute,
        width=5,
    ).grid(row=0, column=3, padx=8)

    week_fr = ttk.LabelFrame(sf, text="שבועי — יום בשבוע", padding=8)
    week_fr.pack(fill=tk.X, pady=4)
    days = ["ראשון", "שני", "שלישי", "רביעי", "חמישי", "שישי", "שבת"]
    wd_combo = ttk.Combobox(
        week_fr,
        values=days,
        state="readonly",
        width=14,
    )
    wd_combo.current(sched_weekday.get())
    wd_combo.pack(anchor=tk.W)

    def get_weekday():
        return wd_combo.current()

    month_fr = ttk.LabelFrame(sf, text="חודשי — יום בחודש (1–28 מומלץ)", padding=8)
    month_fr.pack(fill=tk.X, pady=4)
    ttk.Spinbox(
        month_fr,
        from_=1,
        to=28,
        textvariable=sched_monthday,
        width=5,
    ).pack(anchor=tk.W)

    status_sched = ttk.Label(sf, text="")
    status_sched.pack(anchor=tk.W, pady=8)

    def refresh_sched_status():
        ex = query_task_exists()
        status_sched.config(
            text=f"מצב משימה במתזמן: {'קיימת' if ex else 'לא נמצאה'}"
        )

    def save_schedule():
        data = load_config()
        data["categories"] = {k: v.get() for k, v in cat_vars.items()}
        data.setdefault("options", {})
        data["options"]["backup_manifest_before_run"] = backup_manifest.get()
        wd = get_weekday()
        data["schedule"] = {
            "enabled": sched_enabled.get(),
            "mode": sched_mode.get(),
            "hour": sched_hour.get(),
            "minute": sched_minute.get(),
            "weekday": wd,
            "monthday": sched_monthday.get(),
        }
        save_config(data)
        ok, msg = install_schedule(data["schedule"])
        if ok:
            messagebox.showinfo("תזמון", msg)
        else:
            messagebox.showerror("תזמון", msg)
        refresh_sched_status()

    def clear_schedule():
        data = load_config()
        data["schedule"] = data.get("schedule", {})
        data["schedule"]["enabled"] = False
        sched_enabled.set(False)
        save_config(data)
        ok, msg = remove_schedule()
        messagebox.showinfo("תזמון", msg)
        refresh_sched_status()

    ttk.Button(sf, text="שמור והחל תזמון", command=save_schedule).pack(
        anchor=tk.W, pady=4
    )
    ttk.Button(sf, text="הסר תזמון", command=clear_schedule).pack(anchor=tk.W)

    refresh_sched_status()

    ttk.Label(
        sf,
        text=(
            "הערה: ניקוי מתוזמן משתמש באותן סימונים כמו בלשונית «ניקוי». "
            "שמרו את הבחירה לפני הפעלת התזמון."
        ),
        wraplength=640,
    ).pack(anchor=tk.W, pady=(16, 0))

    root.mainloop()
