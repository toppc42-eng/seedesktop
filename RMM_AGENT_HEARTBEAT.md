# RMM — `POST /api/agent_heartbeat` (SeeDesktop client ↔ VPS)

מסמך עבור מפתחי סוכן/שרת. הלקוח (Flutter) שולח דופק לפי המפרט הזה.

## 1. נקודת קצה וחובה בכל קריאה

- **Method / path:** `POST /api/agent_heartbeat`
- **Content-Type:** `application/json`
- **שדות חובה בגוף:**
  - **`agent_id`** — מחרוזת; ללא רווחים (בשרת: trim ואז הסרת רווחים). חייב להתאים ל־**מזהה הסוכן** ב־UI.
  - **`license_key`** — מפתח הרישיון (הלקוח **לא** שולח דופק בלי מפתח שמור).
- **מומלץ בכל דופק:** `computer_name`, `os_version`, `status` (`online` / `in_session`).

## 2. שדות שטוחים — סנכרון עם שורת הסיכום ב־UI

בכל heartbeat לשלוח במפורש (מחרוזות קצרות, UTF-8):

| שדה | דוגמה |
|-----|--------|
| `cpu_usage` | `"23%"` |
| `ram_usage` | `"6.5 GB / 7.7 GB (84%)"` (אחוז = שימוש) |
| `disk_free` | `"134GB free of 238GB (57%)"` (אחוז = פנוי מסך הכולל) |

**חומרה עשירה (אופציונלי אך מומלץ):**

| שדה | הערות |
|-----|--------|
| `cpu_model` | שם/מזהה מעבד |
| `ram_gb` | מספר (למשל `7.7`) |
| `ram_slots` | טקסט תצוגה (למשל `2/4` או מחרוזת מ־`ram_slots_usage`) |
| `disk_info` | מערך אובייקטים (כמו ב־`hw_health.disk_info`) |
| `smart_status` | Windows: מ־PowerShell / דיסק פיזי, כשזמין |

## 3. `hw_health`

- לשלוח כ־**אובייקט JSON** (המבנה אצל SeeDesktop מגיע מ־Rust `hardware_health::get_hardware_health()` דרך `mainGetSysMetrics()`).
- **המלצה:** גם `hw_health` **וגם** השדות השטוחים למעלה — כך ה־UI וה־API תמיד מסונכרנים גם אם השרת מנסה לגזור ערכים מ־`hw_health` בלבד.

## 4. תדירות וזמן

- הלקוח שולח דופק בקירוב כל **45 שניות** (טווח מומלץ 30–60 שניות ל־`last_seen` / חלון "מחובר").

## 5. צד Flutter

- בניית הגוף: `flutter/lib/utils/agent_heartbeat_manager.dart` — `AgentHeartbeatManager._performHeartbeatOnce`, פונקציית העזר `applyHeartbeatFlatTelemetryFromSysMetrics`.
- פרסור תשובת `get_all_agents`: `AgentInfo.fromJson` קורא `cpu_usage`, `ram_usage`, `disk_free`, `cpu_model`, `hw_health`, וכו'.

## 6. דוגמת JSON בשורה אחת (העתק-הדבק)

```text
{"agent_id":"9123456789","license_key":"YOUR_LICENSE_KEY","computer_name":"PC-01","os_version":"windows Microsoft Windows 11 Pro","status":"online","cpu_usage":"23%","ram_usage":"6.5 GB / 7.7 GB (84%)","disk_free":"134GB free of 238GB (57%)","cpu_model":"Intel(R) Core(TM) i7-9700 CPU @ 3.00GHz","ram_gb":7.7,"ram_slots":"2/4","smart_status":"Healthy","hw_health":{"cpu_name":"…","disks":[],"disk_info":[],"temp_status":"unknown","fan_status":"unknown","recommended_actions":[]}}
```

(השדות ב־`hw_health` בפועל ארוכים יותר; השאר את המבנה כפי שהלקוח שולח.)

## 7. אבטחה

- **אל** לרשום `license_key` מלא בלוגים בדיבוג — הלקוח מסתיר אותו ב־`debugPrint`.
