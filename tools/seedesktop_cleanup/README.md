# SeeDesktop Cleanup

כלי ניקוי Windows עצמאי (ממשק בעברית) שנארז לצד SeeDesktop: קבצי Temp, מטמונים, DNS, תזמון יומי/שבועי/חודשי דרך **משימות Windows** (`schtasks`).

## פיתוח

```powershell
cd tools\seedesktop_cleanup
py -m pip install -r requirements.txt
py app_entry.py
```

## בניית EXE (ללא Python במחשב היעד)

```powershell
.\build_exe.ps1
```

הפלט: `dist\SeeDesktopCleanup.exe`

הרצה שקטה (מתזמן):

```text
SeeDesktopCleanup.exe --auto-run
```

הגדרות נשמרות ב־`%LOCALAPPDATA%\SeeDesktopCleanup\settings.json`. לוג אוטומטי: `last_auto_run.log`.

אפשרות **manifest לפני ניקוי**: קובץ טקסט תחת `SeeDesktopCleanup\manifests\` (סיכום פעולות ונתיבים מייצגים — לא רשימת כל הקבצים).

## קטגוריות מתקדמות (סיכום)

| קטגוריה | הערות |
|--------|--------|
| **DISM /StartComponentCleanup** | מנקה רכיבי WinSxS; עלול להיות איטי; לעיתים נדרש **מנהל**. לא מחליף `cleanmgr` — לניקוי דיסק מלא אפשר להריץ ידנית `cleanmgr` או הגדרות אחסון ב‑Windows. |
| **מטמון Microsoft Store** | תתי־תיקיות בטוחים יחסית תחת `Packages\...\LocalState` וכו׳. |
| **$Windows.~BT** | סיכון גבוה — שטח שדרוג; אל תפעילו במהלך/לפני שדרוג מתוכנן. |
| **יומני אירועים (wevtutil)** | לרוב דורש מנהל; מוחק יומנים קלאסיים (Application, System, Setup). |
| **Prefetch** | מאט טעינה ראשונה של אפליקציות עד בנייה מחדש של התחזיות. |
| **Spotify / Teams / OneDrive / Discord** | נתיבי מטמון/יומנים ידועים; סגרו את האפליקציה לפני. |
| **פרטיות (דפדפן)** | Cookie + Local Storage ב‑Chromium; עוגיות ב‑Firefox — **לא** קבצי סיסמאות (`Login Data` / `logins.json`). |
| **היסטוריית גלישה** | מסומן בנפרד, מסוכן — סגרו דפדפן לפני. |

**לא מיושם:** ניקוי «שאריות התקנה» ברישום וב־Program Files (דורש רשימה לבנה); ISO זמניים מחוץ לנתיבים קבועים — השתמשו בזהירות ידנית.

## הרשאות

חלק מהניקויים (למשל Temp של Windows, **DISM**, **wevtutil**, **Prefetch**) עשויים לדרוש **הרצה כמנהל** כדי לפעול במלואם.

## אינטגרציה מרחוק (SeeDesktop / מסוף)

ניתן להריץ את אותו כלי מהמחשב המרוחק (לא חובה להטמיע בתוך ה־EXE הראשי):

```powershell
& "$env:ProgramFiles\SeeDesktop\SeeDesktopCleanup.exe"
# או עם ארגומנט מתזמן:
& "C:\Path\To\SeeDesktopCleanup.exe" --auto-run
```

לפעולות שדורשות הרמה (DISM / wevtutil), השתמשו ב‑PowerShell מורם או `Start-Process -Verb RunAs` לפי מדיניות הארגון.

## רישיון

חלק ממוצר SeeDesktop; השתמש באחריותך על פי מדיניות הארגון.
