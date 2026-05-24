# Deploy to VPS as license_server.py (or merge routes into your existing app).
# CRITICAL: On the server, backup first:
#   cp license_server.py license_server.py.bak_$(date +%Y%m%d_%H%M)
#
# After deploying: restart your license API service, e.g.:
#   sudo systemctl restart license_api
#   # or: sudo supervisorctl restart license_api
#
# ── Seat-based floating license model ──
#
#   Seats (allowed_connections)  = max distinct machines the key allows
#   Machines connected           = unique hardware_ids in the sessions array
#   My sessions                  = sessions owned by the requesting hardware_id
#
#   A hardware_id that already occupies a seat may open unlimited remote
#   sessions without consuming additional seats.

from __future__ import annotations

import json
import logging
import os
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timezone

from flask import Flask, jsonify, request

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("license_server")

# ---------------------------------------------------------------------------
# GeoIP (stdlib only)
# ---------------------------------------------------------------------------

def get_country_from_ip(ip: str) -> str:
    if ip in ("127.0.0.1", "::1", "localhost"):
        return "Local"
    try:
        import urllib.request
        with urllib.request.urlopen(
            f"http://ip-api.com/json/{ip}", timeout=2
        ) as resp:
            return json.loads(resp.read().decode()).get("country", "Unknown")
    except Exception:
        return "Unknown"


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

STALE_SESSION_SECONDS = int(os.environ.get("STALE_SESSION_SECONDS", "90"))
WATCHDOG_INTERVAL_SECONDS = int(os.environ.get("WATCHDOG_INTERVAL_SECONDS", "60"))
TEMP_RMM_INHERIT_SECONDS = int(os.environ.get("TEMP_RMM_INHERIT_SECONDS", "3600"))

# ---------------------------------------------------------------------------
# In-memory stores
# ---------------------------------------------------------------------------

SESSIONS: dict[str, dict] = {}
LICENSE_SEATS: dict[str, int] = {}   # license_key → allowed seats (learned from client payloads)
TEMP_RMM_GRANTS: dict[str, dict] = {}  # target peer key -> temporary PRO-RMM inheritance
_sessions_lock = threading.Lock()

# Jumbo Mail credits per WordPress / cloud account email
JUMBO_CREDITS_DB_PATH = os.environ.get(
    "JUMBO_CREDITS_DB",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "jumbo_credits.db"),
)
_jumbo_credits_lock = threading.Lock()

app = Flask(__name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _client_ip() -> str:
    return (
        request.headers.get("X-Forwarded-For") or request.remote_addr or ""
    ).split(",")[0].strip()


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _now_epoch() -> float:
    return time.time()


def _normalize_peer_key(peer_id: str, target_pc: str) -> str:
    """Collapse '380156890', '380156890@relay', and numeric target_pc to one key."""
    raw = (peer_id or "").strip() or (target_pc or "").strip()
    if not raw:
        return ""
    at = raw.find("@")
    if at > 0:
        before = raw[:at].replace(" ", "")
        if before.isdigit():
            return before
    digits_only = raw.replace(" ", "")
    if digits_only.isdigit():
        return digits_only
    return raw.casefold()


def _peer_key_of(row: dict) -> str:
    return _normalize_peer_key(
        (row.get("peer_id") or "").strip(),
        (row.get("target_pc") or "").strip(),
    )


def _is_pro_rmm_license(license_key: str) -> bool:
    return (license_key or "").strip().upper().startswith("SD-PRORMM-")


def _mask_license_key(license_key: str) -> str:
    t = (license_key or "").strip()
    if not t:
        return ""
    if len(t) <= 12:
        return t[:4] + "****"
    return f"{t[:12]}****{t[-4:]}"


def _rebuild_label(computer_name: str, remote_hostname: str, target_pc: str) -> str:
    right = (remote_hostname or "").strip() or (target_pc or "").strip() or "Unknown"
    return f"{computer_name} -> {right}"


# ---------------------------------------------------------------------------
# Seat limit resolution
# ---------------------------------------------------------------------------

def _resolve_seats(data: dict) -> int:
    """
    Max distinct machines (seats) allowed by the license.
    -1 or 0 → unlimited (bypass enforcement).

    Priority:
      1. Explicit value in this request payload (and persist it)
      2. Previously learned value for the same license_key
      3. Env var LICENSE_DEFAULT_SEATS
      4. Fallback 999
    """
    license_key = (data.get("license_key") or "").strip()

    # 1. Check the current request payload.
    for k in ("allowed_connections", "max_connections", "max_stations"):
        v = data.get(k)
        if v is None:
            continue
        try:
            n = int(v)
            if n <= 0:
                if license_key:
                    LICENSE_SEATS[license_key] = -1
                return -1
            if license_key:
                LICENSE_SEATS[license_key] = n
            return n
        except (TypeError, ValueError):
            continue

    # 2. Previously stored value for this license.
    if license_key and license_key in LICENSE_SEATS:
        return LICENSE_SEATS[license_key]

    # 3. Env var.
    env = os.environ.get("LICENSE_DEFAULT_SEATS", "").strip()
    if env:
        try:
            n = int(env)
            if n <= 0:
                return -1
            return n
        except (TypeError, ValueError):
            pass

    return 999


def _is_unlimited(seats: int) -> bool:
    return seats <= 0


# ---------------------------------------------------------------------------
# Session queries  (callers must hold _sessions_lock)
# ---------------------------------------------------------------------------

def _sessions_for_license(license_key: str) -> list[dict]:
    lk = license_key.strip()
    if not lk:
        return list(SESSIONS.values())
    return [s for s in SESSIONS.values()
            if (s.get("license_key") or "").strip() == lk]


def _unique_hardware_ids(license_key: str) -> set[str]:
    """Distinct hardware_ids = machines connected (= seats consumed)."""
    lk = license_key.strip()
    hw_set: set[str] = set()
    for s in SESSIONS.values():
        if lk and (s.get("license_key") or "").strip() != lk:
            continue
        hw = (s.get("hardware_id") or "").strip()
        if hw:
            hw_set.add(hw)
    return hw_set


def _find_existing(license_key: str, hardware_id: str, peer_key: str) -> str | None:
    """Find session_id for an existing (hw + peer) combo under this license."""
    if not hardware_id:
        return None
    lk = license_key.strip()
    hw = hardware_id.strip()

    if peer_key:
        placeholder: str | None = None
        for sid, row in SESSIONS.items():
            if (row.get("license_key") or "").strip() != lk:
                continue
            if (row.get("hardware_id") or "").strip() != hw:
                continue
            stored = _peer_key_of(row)
            if stored == peer_key:
                return sid
            if not stored:
                placeholder = placeholder or sid
        if placeholder:
            return placeholder
        return None

    for sid, row in SESSIONS.items():
        if (row.get("license_key") or "").strip() != lk:
            continue
        if (row.get("hardware_id") or "").strip() != hw:
            continue
        if not _peer_key_of(row):
            return sid
    return None


def _my_session_count(license_key: str, hardware_id: str) -> int:
    """Sessions owned by this specific machine."""
    lk = license_key.strip()
    hw = hardware_id.strip()
    if not hw:
        return 0
    return sum(
        1 for s in SESSIONS.values()
        if (s.get("license_key") or "").strip() == lk
        and (s.get("hardware_id") or "").strip() == hw
    )


def _grant_temp_rmm_for_target(peer_key: str, license_key: str, hardware_id: str) -> None:
    if not peer_key or not _is_pro_rmm_license(license_key):
        return
    now = _now_epoch()
    TEMP_RMM_GRANTS[peer_key] = {
        "target_peer_key": peer_key,
        "granted_by_hardware_id": (hardware_id or "").strip(),
        "granted_by_license_key_masked": _mask_license_key(license_key),
        "granted_at": _now_iso(),
        "granted_at_epoch": now,
        "expires_at_epoch": now + max(60, TEMP_RMM_INHERIT_SECONDS),
        "ttl_seconds": max(60, TEMP_RMM_INHERIT_SECONDS),
    }


def _has_live_prormm_session_for_target(peer_key: str) -> bool:
    return _find_live_prormm_controller_for_target(peer_key) is not None


def _find_live_prormm_controller_for_target(peer_key: str) -> dict | None:
    """Return the session row for any live PRO-RMM controller targeting this peer."""
    if not peer_key:
        return None
    for row in SESSIONS.values():
        if _peer_key_of(row) != peer_key:
            continue
        lk = (row.get("license_key") or "").strip()
        if _is_pro_rmm_license(lk):
            return row
    return None


def _revoke_temp_rmm_if_stale(peer_key: str) -> None:
    if not peer_key:
        return
    grant = TEMP_RMM_GRANTS.get(peer_key)
    if not grant:
        return
    if not _has_live_prormm_session_for_target(peer_key):
        TEMP_RMM_GRANTS.pop(peer_key, None)


# ---------------------------------------------------------------------------
# Metrics:  Seats / Machines connected / My sessions
# ---------------------------------------------------------------------------

def _build_metrics(license_key: str, hardware_id: str, seats: int) -> dict:
    machines = len(_unique_hardware_ids(license_key))
    my = _my_session_count(license_key, hardware_id)
    seats_label = str(seats) if not _is_unlimited(seats) else "Unlimited"
    return {
        "seats": seats,
        "machines_connected": machines,
        "my_sessions": my,
        "connection_status": f"{seats_label}/{machines}/{my}",
        # Legacy field names the Flutter client reads:
        "allowed_connections": seats,
        "active_stations": machines,
        "active_connections": machines,
    }


# ---------------------------------------------------------------------------
# Merge follow-up payload into existing session
# ---------------------------------------------------------------------------

def _merge_payload(row: dict, data: dict) -> None:
    for field in ("computer_name", "target_pc", "peer_id",
                  "remote_hostname", "remote_username",
                  "app_version", "remote_ip"):
        val = (data.get(field) or "").strip()
        if val:
            row[field] = val

    row["ip_address"] = _client_ip()
    row["country"] = get_country_from_ip(row["ip_address"])
    row["last_seen"] = _now_iso()
    row["last_seen_epoch"] = _now_epoch()
    row["label"] = _rebuild_label(
        row.get("computer_name") or "Unknown",
        row.get("remote_hostname") or "",
        row.get("target_pc") or "",
    )


# ---------------------------------------------------------------------------
# Build a brand-new session row
# ---------------------------------------------------------------------------

def _new_session(data: dict) -> tuple[str, dict]:
    license_key = (data.get("license_key") or "").strip()
    hardware_id = (data.get("hardware_id") or "").strip()
    computer_name = (data.get("computer_name") or "").strip() or "Unknown"
    target_pc = (data.get("target_pc") or "").strip() or "Unknown"
    peer_id = (data.get("peer_id") or "").strip()
    connected_at = (data.get("connected_at") or "").strip()
    remote_hostname = (data.get("remote_hostname") or "").strip()
    remote_username = (data.get("remote_username") or "").strip()
    app_version = (data.get("app_version") or "").strip()
    remote_ip_client = (data.get("remote_ip") or "").strip()

    ip_address = _client_ip()
    country = get_country_from_ip(ip_address)
    session_id = str(uuid.uuid4())

    row = {
        "session_id": session_id,
        "license_key": license_key,
        "hardware_id": hardware_id,
        "computer_name": computer_name,
        "target_pc": target_pc,
        "peer_id": peer_id,
        "connected_at": connected_at or _now_iso(),
        "remote_hostname": remote_hostname,
        "remote_username": remote_username,
        "remote_ip": remote_ip_client,
        "app_version": app_version,
        "ip_address": ip_address,
        "country": country,
        "label": _rebuild_label(computer_name, remote_hostname, target_pc),
        "unlicensed": not bool(license_key),
        "last_seen": _now_iso(),
        "last_seen_epoch": _now_epoch(),
    }
    return session_id, row


# ---------------------------------------------------------------------------
# Core upsert + seat-based enforcement
# ---------------------------------------------------------------------------

def _start_session_core(data: dict):
    license_key = (data.get("license_key") or "").strip()
    hardware_id = (data.get("hardware_id") or "").strip()
    peer_key = _normalize_peer_key(
        (data.get("peer_id") or "").strip(),
        (data.get("target_pc") or "").strip(),
    )

    if not hardware_id:
        return jsonify({
            "status": "error",
            "message": "hardware_id is required.",
        }), 400

    seats = _resolve_seats(data)

    with _sessions_lock:
        # ── 1. Upsert: exact (hw + peer) already tracked? ──
        existing_sid = _find_existing(license_key, hardware_id, peer_key)
        if existing_sid:
            _merge_payload(SESSIONS[existing_sid], data)
            _grant_temp_rmm_for_target(peer_key, license_key, hardware_id)
            metrics = _build_metrics(license_key, hardware_id, seats)
            return jsonify({
                "status": "success",
                "session_id": existing_sid,
                "message": "Session updated.",
                **metrics,
            }), 200

        # ── 2. Seat enforcement ──
        # Does this hardware_id already occupy a seat?
        hw_set = _unique_hardware_ids(license_key)
        already_has_seat = hardware_id in hw_set

        if not already_has_seat and not _is_unlimited(seats):
            if len(hw_set) >= seats:
                metrics = _build_metrics(license_key, hardware_id, seats)
                return jsonify({
                    "status": "error",
                    "message": "Seat limit reached.",
                    **metrics,
                }), 403

        # ── 3. Insert new session ──
        session_id, row = _new_session(data)
        SESSIONS[session_id] = row
        _grant_temp_rmm_for_target(peer_key, license_key, hardware_id)
        metrics = _build_metrics(license_key, hardware_id, seats)

    return jsonify({
        "status": "success",
        "session_id": session_id,
        "message": "Session started.",
        **metrics,
    }), 200


# ===========================================================================
# Routes
# ===========================================================================

@app.route("/api/start_session", methods=["POST"])
def start_session():
    data = request.get_json(silent=True) or {}
    resp, code = _start_session_core(data)
    return resp, code


@app.route("/api/start_unlicensed_session", methods=["POST"])
def start_unlicensed_session():
    data = request.get_json(silent=True) or {}
    data["license_key"] = ""
    resp, code = _start_session_core(data)
    return resp, code


# ---------------------------------------------------------------------------
# Heartbeat — refresh last_seen for all sessions owned by this hardware_id
# ---------------------------------------------------------------------------

@app.route("/api/heartbeat", methods=["POST"])
def heartbeat():
    """
    Optional rich payload from See Desktop / Rust agent (see hbbs_http/sync.rs):
      hw_health — object with optional cpu_model, ram_gb, ram_slots_used,
      ram_slots_total, disk_info (list of {model, disk_type}), plus temps/disks, etc.
    """
    data = request.get_json(silent=True) or {}
    hardware_id = (data.get("hardware_id") or "").strip()
    license_key = (data.get("license_key") or "").strip()
    hw_health = data.get("hw_health")

    touched = 0
    now = _now_iso()
    epoch = _now_epoch()
    with _sessions_lock:
        for row in SESSIONS.values():
            if hardware_id and (row.get("hardware_id") or "").strip() != hardware_id:
                continue
            if license_key and (row.get("license_key") or "").strip() != license_key:
                continue
            row["last_seen"] = now
            row["last_seen_epoch"] = epoch
            if hardware_id and isinstance(hw_health, dict):
                row["hw_health"] = hw_health
            touched += 1
            # While this PRO-RMM controller session stays alive (heartbeats
            # keep landing here), the target peer must keep inheriting
            # PRO-RMM. Refresh the temporary inheritance grant on every
            # heartbeat so it never expires mid-session — the user must only
            # lose inheritance when they actually disconnect from the target.
            row_license = (row.get("license_key") or "").strip()
            if _is_pro_rmm_license(row_license):
                row_peer_key = _peer_key_of(row)
                if row_peer_key:
                    _grant_temp_rmm_for_target(
                        row_peer_key,
                        row_license,
                        (row.get("hardware_id") or "").strip(),
                    )

    seats = _resolve_seats(data)
    with _sessions_lock:
        metrics = _build_metrics(license_key, hardware_id, seats)

    return jsonify({
        "status": "success",
        "touched": touched,
        **metrics,
    })


# ---------------------------------------------------------------------------
# Explicit disconnect — by hardware_id + peer_id (preferred) or session_id
# ---------------------------------------------------------------------------

@app.route("/api/release_connection", methods=["POST"])
def release_connection():
    data = request.get_json(silent=True) or {}
    hardware_id = (data.get("hardware_id") or "").strip()
    peer_id = (data.get("peer_id") or "").strip()
    target_pc = (data.get("target_pc") or "").strip()
    session_id = (data.get("session_id") or "").strip()
    license_key = (data.get("license_key") or "").strip()

    removed = 0
    released_peer_keys: set[str] = set()
    with _sessions_lock:
        peer_key = _normalize_peer_key(peer_id, target_pc)
        if hardware_id and peer_key:
            to_del = [
                sid for sid, row in SESSIONS.items()
                if (row.get("hardware_id") or "").strip() == hardware_id
                and _peer_key_of(row) == peer_key
                and (not license_key
                     or (row.get("license_key") or "").strip() == license_key)
            ]
            for sid in to_del:
                released_peer_keys.add(_peer_key_of(SESSIONS.get(sid, {})))
                del SESSIONS[sid]
                removed += 1

        if removed == 0 and session_id and session_id in SESSIONS:
            released_peer_keys.add(_peer_key_of(SESSIONS.get(session_id, {})))
            del SESSIONS[session_id]
            removed = 1

        for pk in released_peer_keys:
            _revoke_temp_rmm_if_stale(pk)

        seats = _resolve_seats(data)
        metrics = _build_metrics(license_key, hardware_id, seats)

    return jsonify({
        "status": "success",
        "released_count": removed,
        **metrics,
    })


# ---------------------------------------------------------------------------
# Active sessions query
# ---------------------------------------------------------------------------

@app.route("/api/get_active_sessions", methods=["POST"])
def get_active_sessions():
    data = request.get_json(silent=True) or {}
    license_key = (data.get("license_key") or "").strip()
    hardware_id = (data.get("hardware_id") or "").strip()
    seats = _resolve_seats(data)

    with _sessions_lock:
        sessions_list = _sessions_for_license(license_key or None)
        metrics = _build_metrics(license_key, hardware_id, seats)

    return jsonify({
        "status": "success",
        "sessions": sessions_list,
        **metrics,
    })


@app.route("/api/get_temporary_rmm_inheritance", methods=["POST"])
def get_temporary_rmm_inheritance():
    data = request.get_json(silent=True) or {}
    peer_id = (data.get("peer_id") or "").strip()
    target_pc = (data.get("target_pc") or "").strip()
    peer_key = _normalize_peer_key(peer_id, target_pc)
    if not peer_key:
        return jsonify({
            "status": "error",
            "message": "peer_id or target_pc is required.",
            "effective_rmm": False,
        }), 400

    now = _now_epoch()
    with _sessions_lock:
        # ── Truth source: a live PRO-RMM controller session targeting this peer ──
        #
        # Inheritance must follow the actual remote session, not a fixed
        # wall-clock TTL on the grant record. The previous implementation
        # expired the grant after TEMP_RMM_INHERIT_SECONDS even though the
        # controller was still heartbeating — that caused the target machine
        # to "revert to its own license" mid-session once an hour had passed.
        #
        # New behavior: as long as the server still sees a live PRO-RMM
        # session aimed at this peer (kept alive by the controller's
        # heartbeats / cleared on disconnect or by the stale-session
        # watchdog), the target inherits PRO-RMM. The grant record is
        # auto-recovered if missing (e.g. process restart) and its expiry
        # is bumped on every poll so any consumer that watches
        # `expires_in_seconds` keeps seeing a fresh window.
        controller = _find_live_prormm_controller_for_target(peer_key)
        grant = TEMP_RMM_GRANTS.get(peer_key)

        if controller is None:
            if grant is not None:
                TEMP_RMM_GRANTS.pop(peer_key, None)
            return jsonify({
                "status": "success",
                "effective_rmm": False,
            })

        controller_license = (controller.get("license_key") or "").strip()
        controller_hwid = (controller.get("hardware_id") or "").strip()

        if grant is None:
            _grant_temp_rmm_for_target(peer_key, controller_license, controller_hwid)
            grant = TEMP_RMM_GRANTS.get(peer_key) or {}
        else:
            ttl = max(60, TEMP_RMM_INHERIT_SECONDS)
            grant["expires_at_epoch"] = now + ttl
            grant["ttl_seconds"] = ttl
            if not grant.get("granted_by_hardware_id") and controller_hwid:
                grant["granted_by_hardware_id"] = controller_hwid
            if not grant.get("granted_by_license_key_masked") and controller_license:
                grant["granted_by_license_key_masked"] = _mask_license_key(controller_license)
            TEMP_RMM_GRANTS[peer_key] = grant

        left = int(max(0, grant.get("expires_at_epoch", 0) - now))
        return jsonify({
            "status": "success",
            "effective_rmm": True,
            "source": "temporary_inheritance",
            "target_peer_key": peer_key,
            "granted_by_hardware_id": grant.get("granted_by_hardware_id", ""),
            "granted_by_license_key_masked": grant.get("granted_by_license_key_masked", ""),
            "expires_in_seconds": left,
            "expires_at_epoch": grant.get("expires_at_epoch", 0),
            "granted_at": grant.get("granted_at", ""),
        })


# ===========================================================================
# Jumbo Mail credits (pay-as-you-go per user_email)
# ===========================================================================

def _jumbo_credits_connect() -> sqlite3.Connection:
    conn = sqlite3.connect(JUMBO_CREDITS_DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    return conn


def _jumbo_credits_init_db() -> None:
    with _jumbo_credits_lock:
        conn = _jumbo_credits_connect()
        try:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS user_jumbo_credits (
                    user_email TEXT PRIMARY KEY NOT NULL,
                    jumbo_credits INTEGER NOT NULL DEFAULT 0
                )
                """
            )
            conn.commit()
        finally:
            conn.close()


def _extract_user_email_from_request() -> str:
    data = request.get_json(silent=True) or {}
    email = (data.get("user_email") or data.get("email") or "").strip()
    if email:
        return email
    return (request.args.get("user_email") or request.args.get("email") or "").strip()


def _get_jumbo_credits_balance(user_email: str) -> int:
    em = (user_email or "").strip().lower()
    if not em:
        return 0
    with _jumbo_credits_lock:
        conn = _jumbo_credits_connect()
        try:
            row = conn.execute(
                "SELECT jumbo_credits FROM user_jumbo_credits WHERE user_email = ?",
                (em,),
            ).fetchone()
            return int(row["jumbo_credits"]) if row else 0
        finally:
            conn.close()


def _consume_jumbo_credit_atomic(user_email: str) -> tuple[bool, int, str]:
    em = (user_email or "").strip().lower()
    if not em:
        return False, 0, "user_email is required."

    with _jumbo_credits_lock:
        conn = _jumbo_credits_connect()
        current = 0
        try:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute(
                "SELECT jumbo_credits FROM user_jumbo_credits WHERE user_email = ?",
                (em,),
            ).fetchone()
            current = int(row["jumbo_credits"]) if row else 0
            if current <= 0:
                conn.execute("ROLLBACK")
                return False, 0, "Out of Jumbo Credits."

            new_balance = current - 1
            conn.execute(
                "UPDATE user_jumbo_credits SET jumbo_credits = ? WHERE user_email = ?",
                (new_balance, em),
            )
            conn.commit()
            return True, new_balance, "Credit consumed."
        except Exception as exc:
            try:
                conn.execute("ROLLBACK")
            except Exception:
                pass
            log.exception("consume_jumbo_credit failed for %s", em)
            return False, current, str(exc)
        finally:
            conn.close()


_jumbo_credits_init_db()

# ---------------------------------------------------------------------------
# Cloud OTP + contacts auth (shared DB)
# ---------------------------------------------------------------------------

CLOUD_OTP_TTL_SECONDS = int(os.environ.get("CLOUD_OTP_TTL_SECONDS", "600"))
CLOUD_AUTH_TOKEN_TTL_SECONDS = int(
    os.environ.get("CLOUD_AUTH_TOKEN_TTL_SECONDS", str(30 * 24 * 3600))
)
_cloud_otp_lock = threading.Lock()
_pending_cloud_otp: dict[str, dict] = {}  # email -> {otp, expires_at_epoch}

# ---------------------------------------------------------------------------
# Cloud contacts (per user_email + remote_id)
# ---------------------------------------------------------------------------

CLOUD_CONTACTS_DB_PATH = os.environ.get(
    "CLOUD_CONTACTS_DB",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud_contacts.db"),
)
_cloud_contacts_lock = threading.Lock()


def _cloud_contacts_connect() -> sqlite3.Connection:
    conn = sqlite3.connect(CLOUD_CONTACTS_DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def _cloud_contacts_init_db() -> None:
    with _cloud_contacts_lock:
        conn = _cloud_contacts_connect()
        try:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS cloud_contacts (
                    user_email TEXT NOT NULL,
                    remote_id TEXT NOT NULL,
                    alias_name TEXT NOT NULL,
                    group_name TEXT NOT NULL DEFAULT '',
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (user_email, remote_id)
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS cloud_auth_tokens (
                    auth_token TEXT PRIMARY KEY,
                    user_email TEXT NOT NULL,
                    expires_at_epoch REAL NOT NULL
                )
                """
            )
            cols = {
                row[1]
                for row in conn.execute("PRAGMA table_info(cloud_contacts)")
            }
            if "group_name" not in cols:
                conn.execute(
                    "ALTER TABLE cloud_contacts ADD COLUMN group_name TEXT NOT NULL DEFAULT ''"
                )
            if "os" not in cols:
                conn.execute(
                    "ALTER TABLE cloud_contacts ADD COLUMN os TEXT NOT NULL DEFAULT ''"
                )
            if "hostname" not in cols:
                conn.execute(
                    "ALTER TABLE cloud_contacts ADD COLUMN hostname TEXT NOT NULL DEFAULT ''"
                )
            if "groups" not in cols:
                conn.execute(
                    "ALTER TABLE cloud_contacts ADD COLUMN groups TEXT NOT NULL DEFAULT '[]'"
                )
            conn.execute(
                """
                UPDATE cloud_contacts
                SET groups = json_array(group_name)
                WHERE trim(COALESCE(group_name, '')) != ''
                  AND (trim(COALESCE(groups, '')) = '' OR groups = '[]')
                """
            )
            conn.commit()
        finally:
            conn.close()


def _extract_cloud_auth_token() -> str:
    auth = (request.headers.get("Authorization") or "").strip()
    if auth.lower().startswith("bearer "):
        token = auth[7:].strip()
        if token:
            return token
    header_token = (
        (request.headers.get("auth_token") or "")
        or (request.headers.get("X-Auth-Token") or "")
    ).strip()
    if header_token:
        return header_token
    data = request.get_json(silent=True) or {}
    body_token = (data.get("auth_token") or "").strip()
    if body_token:
        return body_token
    return (request.args.get("auth_token") or "").strip()


def _cloud_auth_store_token(email: str, token: str) -> None:
    em = _normalize_contact_email(email)
    if not em or not token:
        return
    expires = _now_epoch() + CLOUD_AUTH_TOKEN_TTL_SECONDS
    now = _now_epoch()
    with _cloud_contacts_lock:
        conn = _cloud_contacts_connect()
        try:
            # Keep other devices signed in; only prune expired rows for this user.
            conn.execute(
                "DELETE FROM cloud_auth_tokens WHERE user_email = ? AND expires_at_epoch <= ?",
                (em, now),
            )
            conn.execute(
                """
                INSERT OR REPLACE INTO cloud_auth_tokens (auth_token, user_email, expires_at_epoch)
                VALUES (?, ?, ?)
                """,
                (token, em, expires),
            )
            conn.commit()
        finally:
            conn.close()


def _cloud_auth_email_for_token(token: str) -> str | None:
    if not token:
        return None
    now = _now_epoch()
    with _cloud_contacts_lock:
        conn = _cloud_contacts_connect()
        try:
            row = conn.execute(
                """
                SELECT user_email, expires_at_epoch FROM cloud_auth_tokens
                WHERE auth_token = ?
                """,
                (token,),
            ).fetchone()
            if not row:
                return None
            if float(row["expires_at_epoch"]) <= now:
                conn.execute(
                    "DELETE FROM cloud_auth_tokens WHERE auth_token = ?",
                    (token,),
                )
                conn.commit()
                return None
            return _normalize_contact_email(row["user_email"])
        finally:
            conn.close()


def _cloud_contacts_require_auth(requested_email: str):
    token = _extract_cloud_auth_token()
    if not token:
        return (
            jsonify({"status": "error", "message": "Unauthorized"}),
            401,
        )
    auth_email = _cloud_auth_email_for_token(token)
    if not auth_email:
        return (
            jsonify({"status": "error", "message": "Unauthorized"}),
            401,
        )
    req_email = _normalize_contact_email(requested_email)
    if req_email and auth_email != req_email:
        return (
            jsonify({"status": "error", "message": "Forbidden"}),
            403,
        )
    return None


@app.route("/api/cloud/request_otp", methods=["POST"])
def cloud_request_otp():
    data = request.get_json(silent=True) or {}
    email = _normalize_contact_email(data.get("email") or "")
    if not email:
        return jsonify({"status": "error", "message": "email is required."}), 400
    import random

    otp = f"{random.randint(0, 999999):06d}"
    expires = _now_epoch() + CLOUD_OTP_TTL_SECONDS
    with _cloud_otp_lock:
        _pending_cloud_otp[email] = {"otp": otp, "expires_at_epoch": expires}
    log.info("Cloud OTP for %s: %s (dev/server log only)", email, otp)
    return jsonify({"status": "success"}), 200


@app.route("/api/cloud/verify_otp", methods=["POST"])
def cloud_verify_otp():
    data = request.get_json(silent=True) or {}
    email = _normalize_contact_email(data.get("email") or "")
    otp = (data.get("otp") or "").strip()
    if not email or len(otp) != 6:
        return jsonify({"status": "error", "message": "Invalid email or OTP."}), 400
    with _cloud_otp_lock:
        pending = _pending_cloud_otp.get(email)
        if not pending or pending.get("otp") != otp:
            return jsonify({"status": "error", "message": "Invalid OTP."}), 401
        if pending.get("expires_at_epoch", 0) <= _now_epoch():
            _pending_cloud_otp.pop(email, None)
            return jsonify({"status": "error", "message": "OTP expired."}), 401
        _pending_cloud_otp.pop(email, None)
    token = uuid.uuid4().hex
    _cloud_auth_store_token(email, token)
    return jsonify(
        {
            "status": "success",
            "auth_token": token,
            "user": {"email": email, "display_name": email},
        }
    ), 200


def _normalize_contact_email(email: str) -> str:
    return (email or "").strip().lower()


def _parse_groups_from_payload(data: dict) -> list[str]:
    """Accept `groups` (array) or legacy `group_name` (string, comma-separated)."""
    raw = data.get("groups")
    out: list[str] = []
    if isinstance(raw, list):
        for item in raw:
            g = str(item or "").strip()
            if g and g not in out:
                out.append(g)
        return out
    if isinstance(raw, str) and raw.strip():
        try:
            decoded = json.loads(raw)
            if isinstance(decoded, list):
                for item in decoded:
                    g = str(item or "").strip()
                    if g and g not in out:
                        out.append(g)
                return out
        except Exception:
            pass
    legacy = (data.get("group_name") or request.args.get("group_name") or "").strip()
    if legacy:
        for part in legacy.replace(";", ",").split(","):
            g = part.strip()
            if g and g not in out:
                out.append(g)
    return out


def _decode_stored_groups(groups_json: str, legacy_group_name: str) -> list[str]:
    out: list[str] = []
    raw = (groups_json or "").strip()
    if raw:
        try:
            decoded = json.loads(raw)
            if isinstance(decoded, list):
                for item in decoded:
                    g = str(item or "").strip()
                    if g and g not in out:
                        out.append(g)
        except Exception:
            pass
    if not out:
        legacy = (legacy_group_name or "").strip()
        if legacy:
            for part in legacy.replace(";", ",").split(","):
                g = part.strip()
                if g and g not in out:
                    out.append(g)
    return out


def _encode_groups(groups: list[str]) -> str:
    return json.dumps(groups, ensure_ascii=False)


def _contact_row_to_api(row) -> dict:
    groups = _decode_stored_groups(
        row["groups"] if "groups" in row.keys() else "[]",
        row["group_name"] or "",
    )
    return {
        "remote_id": row["remote_id"],
        "alias_name": row["alias_name"],
        "groups": groups,
        "os": row["os"] or "",
        "hostname": row["hostname"] or "",
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def _contacts_from_request() -> tuple[str, str, str, list[str], str, str]:
    data = request.get_json(silent=True) or {}
    email = _normalize_contact_email(
        data.get("user_email") or data.get("email")
        or request.args.get("user_email")
        or request.args.get("email")
        or ""
    )
    remote_id = (data.get("remote_id") or request.args.get("remote_id") or "").strip()
    alias_name = (data.get("alias_name") or request.args.get("alias_name") or "").strip()
    groups = _parse_groups_from_payload(data)
    os_name = (data.get("os") or request.args.get("os") or "").strip()
    hostname = (data.get("hostname") or request.args.get("hostname") or "").strip()
    return email, remote_id, alias_name, groups, os_name, hostname


@app.route("/api/contacts", methods=["GET"])
def list_cloud_contacts():
    email = _normalize_contact_email(
        request.args.get("user_email") or request.args.get("email") or ""
    )
    if not email:
        return jsonify({
            "status": "error",
            "message": "user_email is required.",
            "contacts": [],
        }), 400
    auth_err = _cloud_contacts_require_auth(email)
    if auth_err is not None:
        return auth_err
    with _cloud_contacts_lock:
        conn = _cloud_contacts_connect()
        try:
            rows = conn.execute(
                """
                SELECT remote_id, alias_name, group_name, groups, os, hostname, created_at, updated_at
                FROM cloud_contacts
                WHERE user_email = ?
                ORDER BY alias_name COLLATE NOCASE ASC
                """,
                (email,),
            ).fetchall()
            contacts = [_contact_row_to_api(r) for r in rows]
        finally:
            conn.close()
    return jsonify({"status": "success", "contacts": contacts}), 200


@app.route("/api/contacts", methods=["POST"])
def upsert_cloud_contact():
    email, remote_id, alias_name, groups, os_name, hostname = _contacts_from_request()
    if not email or not remote_id or not alias_name:
        return jsonify({
            "status": "error",
            "message": "user_email, remote_id, and alias_name are required.",
        }), 400
    auth_err = _cloud_contacts_require_auth(email)
    if auth_err is not None:
        return auth_err
    now = _now_epoch()
    with _cloud_contacts_lock:
        conn = _cloud_contacts_connect()
        try:
            row = conn.execute(
                """
                SELECT created_at FROM cloud_contacts
                WHERE user_email = ? AND remote_id = ?
                """,
                (email, remote_id),
            ).fetchone()
            created = float(row["created_at"]) if row else now
            groups_json = _encode_groups(groups)
            legacy_group = groups[0] if groups else ""
            conn.execute(
                """
                INSERT INTO cloud_contacts
                    (user_email, remote_id, alias_name, group_name, groups, os, hostname, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_email, remote_id) DO UPDATE SET
                    alias_name = excluded.alias_name,
                    group_name = excluded.group_name,
                    groups = excluded.groups,
                    os = excluded.os,
                    hostname = excluded.hostname,
                    updated_at = excluded.updated_at
                """,
                (
                    email,
                    remote_id,
                    alias_name,
                    legacy_group,
                    groups_json,
                    os_name,
                    hostname,
                    created,
                    now,
                ),
            )
            conn.commit()
        finally:
            conn.close()
    return jsonify({"status": "success"}), 200


@app.route("/api/contacts", methods=["DELETE"])
def delete_cloud_contact():
    email, remote_id, _alias, _groups, _os, _host = _contacts_from_request()
    if not email or not remote_id:
        return jsonify({
            "status": "error",
            "message": "user_email and remote_id are required.",
        }), 400
    auth_err = _cloud_contacts_require_auth(email)
    if auth_err is not None:
        return auth_err
    with _cloud_contacts_lock:
        conn = _cloud_contacts_connect()
        try:
            conn.execute(
                "DELETE FROM cloud_contacts WHERE user_email = ? AND remote_id = ?",
                (email, remote_id),
            )
            conn.commit()
        finally:
            conn.close()
    return jsonify({"status": "success"}), 200


_cloud_contacts_init_db()


@app.route("/api/get_jumbo_credits", methods=["GET", "POST"])
def get_jumbo_credits():
    user_email = _extract_user_email_from_request()
    if not user_email:
        return jsonify({
            "status": "error",
            "message": "user_email is required.",
            "jumbo_credits": 0,
        }), 400

    balance = _get_jumbo_credits_balance(user_email)
    return jsonify({
        "status": "success",
        "user_email": user_email,
        "jumbo_credits": balance,
    }), 200


@app.route("/api/consume_jumbo_credit", methods=["POST"])
def consume_jumbo_credit():
    user_email = _extract_user_email_from_request()
    if not user_email:
        return jsonify({
            "status": "error",
            "message": "user_email is required.",
            "jumbo_credits": 0,
        }), 400

    ok, balance, message = _consume_jumbo_credit_atomic(user_email)
    if not ok:
        return jsonify({
            "status": "error",
            "message": message,
            "jumbo_credits": balance,
        }), 402

    return jsonify({
        "status": "success",
        "message": message,
        "jumbo_credits": balance,
    }), 200


# ===========================================================================
# Stale Session Watchdog — background thread
# ===========================================================================

def _watchdog_loop():
    """Remove sessions whose last_seen_epoch is older than STALE_SESSION_SECONDS."""
    while True:
        time.sleep(WATCHDOG_INTERVAL_SECONDS)
        cutoff = _now_epoch() - STALE_SESSION_SECONDS
        now = _now_epoch()
        with _sessions_lock:
            stale = [
                sid for sid, row in SESSIONS.items()
                if row.get("last_seen_epoch", 0) < cutoff
            ]
            affected_peer_keys: set[str] = set()
            for sid in stale:
                row = SESSIONS.pop(sid, {})
                affected_peer_keys.add(_peer_key_of(row))
                log.info(
                    "Watchdog removed stale session %s (hw=%s peer=%s last_seen=%s)",
                    sid,
                    row.get("hardware_id", "?"),
                    row.get("peer_id", "?"),
                    row.get("last_seen", "?"),
                )
            if stale:
                log.info("Watchdog cleaned %d stale session(s). Active: %d",
                         len(stale), len(SESSIONS))
            for pk in affected_peer_keys:
                _revoke_temp_rmm_if_stale(pk)

            expired_grants = [
                key for key, g in TEMP_RMM_GRANTS.items()
                if g.get("expires_at_epoch", 0) <= now
            ]
            for key in expired_grants:
                TEMP_RMM_GRANTS.pop(key, None)


_watchdog_thread = threading.Thread(target=_watchdog_loop, daemon=True)
_watchdog_thread.start()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
