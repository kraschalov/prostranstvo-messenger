import sqlite3
import threading
import time
from pathlib import Path

from app.config import settings
from app.crypto import device_fingerprint_hash

_lock = threading.RLock()
_conn: sqlite3.Connection | None = None

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL DEFAULT '',
  gender TEXT NOT NULL DEFAULT 'unknown',
  birth_date TEXT NOT NULL DEFAULT '',
  age INTEGER NOT NULL DEFAULT 0,
  city TEXT NOT NULL DEFAULT '',
  goal TEXT NOT NULL DEFAULT '',
  interests TEXT NOT NULL DEFAULT '',
  bio TEXT NOT NULL DEFAULT '',
  photo_path TEXT NOT NULL DEFAULT '',
  role TEXT NOT NULL DEFAULT 'STANDARD_USER',
  device_fingerprint TEXT NOT NULL UNIQUE,
  dating_switch INTEGER NOT NULL DEFAULT 0,
  federated_search INTEGER NOT NULL DEFAULT 1,
  cross_server_messages INTEGER NOT NULL DEFAULT 1,
  public_key TEXT NOT NULL DEFAULT '',
  recovery_code TEXT NOT NULL DEFAULT '',
  banned INTEGER NOT NULL DEFAULT 0,
  created_at REAL NOT NULL,
  last_seen REAL NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS spaces (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at REAL NOT NULL,
  isolated INTEGER NOT NULL DEFAULT 0,
  visible INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS topics (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  owner_id INTEGER NOT NULL,
  privacy TEXT NOT NULL DEFAULT 'closed',
  scope TEXT NOT NULL DEFAULT 'server',
  invite_policy TEXT NOT NULL DEFAULT 'owner',
  visibility TEXT NOT NULL DEFAULT 'hidden',
  default_can_post INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS pending_events (
  user_id INTEGER NOT NULL,
  msg_id TEXT NOT NULL,
  event_json TEXT NOT NULL,
  expires_at REAL NOT NULL,
  PRIMARY KEY (user_id, msg_id)
);
CREATE TABLE IF NOT EXISTS topic_members (
  topic_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  can_post INTEGER NOT NULL DEFAULT 1,
  can_invite INTEGER NOT NULL DEFAULT 0,
  joined_at REAL NOT NULL,
  PRIMARY KEY (topic_id, user_id)
);
CREATE TABLE IF NOT EXISTS space_members (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  space_id INTEGER NOT NULL REFERENCES spaces(id) ON DELETE CASCADE,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  joined_at REAL NOT NULL,
  UNIQUE(space_id, user_id)
);

CREATE TABLE IF NOT EXISTS invites (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  code TEXT NOT NULL UNIQUE,
  space_id INTEGER REFERENCES spaces(id) ON DELETE CASCADE,
  created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
  role_granted TEXT NOT NULL DEFAULT 'STANDARD_USER',
  used_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
  used_at REAL,
  created_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  created_at REAL NOT NULL,
  expires_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS server_registry (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  domain TEXT NOT NULL UNIQUE,
  name TEXT NOT NULL DEFAULT '',
  shared_secret TEXT NOT NULL,
  linked_at REAL NOT NULL,
  active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS server_blacklist (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_fingerprint TEXT NOT NULL UNIQUE,
  reason TEXT NOT NULL DEFAULT '',
  banned_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
  banned_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS appeals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_fingerprint TEXT NOT NULL,
  message TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at REAL NOT NULL
);
"""

ROLES = ("STANDARD_USER", "FAMILY_MEMBER", "SUPER_ADMIN")
ROLE_RANK = {"STANDARD_USER": 1, "FAMILY_MEMBER": 2, "SUPER_ADMIN": 3}


def init_db() -> None:
    global _conn
    Path(settings.db_path).parent.mkdir(parents=True, exist_ok=True)
    _conn = sqlite3.connect(settings.db_path, check_same_thread=False)
    _conn.row_factory = sqlite3.Row
    _conn.execute("PRAGMA journal_mode=WAL")
    _conn.execute("PRAGMA foreign_keys=ON")
    _conn.executescript(SCHEMA)
    _migrate()
    _conn.commit()


def _migrate() -> None:
    cols = [r[1] for r in _conn.execute("PRAGMA table_info(users)").fetchall()]
    if "recovery_code" not in cols:
        _conn.execute("ALTER TABLE users ADD COLUMN recovery_code TEXT NOT NULL DEFAULT ''")
    if "cover_path" not in cols:
        _conn.execute("ALTER TABLE users ADD COLUMN cover_path TEXT NOT NULL DEFAULT ''")
    tcols = [r[1] for r in _conn.execute("PRAGMA table_info(topics)").fetchall()]
    if "visibility" not in tcols:
        _conn.execute("ALTER TABLE topics ADD COLUMN visibility TEXT NOT NULL DEFAULT 'hidden'")
        # Миграция старой модели (privacy+scope) на новую (privacy x visibility):
        # closed -> закрытая/скрыта; server_open -> открытая/инсайд;
        # project_open -> открытая/везде.
        _conn.execute("UPDATE topics SET visibility = 'inside' WHERE privacy = 'server_open'")
        _conn.execute("UPDATE topics SET visibility = 'everywhere' WHERE privacy = 'project_open'")
        _conn.execute("UPDATE topics SET privacy = 'open' WHERE privacy IN ('server_open', 'project_open')")

    inv_cols = [r[1] for r in _conn.execute("PRAGMA table_info(invites)").fetchall()]
    # Срок действия инвайта (created_at + 72h) и момент скачивания APK
    # по ссылке (одноразовое: NULL = ещё не скачивали).
    if "expires_at" not in inv_cols:
        _conn.execute("ALTER TABLE invites ADD COLUMN expires_at REAL")
    if "apk_consumed_at" not in inv_cols:
        _conn.execute("ALTER TABLE invites ADD COLUMN apk_consumed_at REAL")
    # Токен первого скачивания: выдаётся первому устройству в cookie,
    # чтобы в течение срока действия ссылки (72ч) оно могло повторно
    # скачивать (докачка при обрыве), а другие устройства — нет.
    if "apk_token" not in inv_cols:
        _conn.execute("ALTER TABLE invites ADD COLUMN apk_token TEXT")

    sp_cols = [r[1] for r in _conn.execute("PRAGMA table_info(spaces)").fetchall()]
    # Изоляция пространства: члены не создают свои пространства, не видят
    # чужих и не могут включить видимость в Общем. Включается создателем.
    if "isolated" not in sp_cols:
        _conn.execute("ALTER TABLE spaces ADD COLUMN isolated INTEGER NOT NULL DEFAULT 0")
    # Видимость пользователя в «Общем» пространстве (глобально).
    if "visible" not in sp_cols:
        _conn.execute("ALTER TABLE spaces ADD COLUMN visible INTEGER NOT NULL DEFAULT 0")


def execute(sql: str, params: tuple = ()) -> int:
    with _lock:
        cur = _conn.execute(sql, params)
        _conn.commit()
        return cur.lastrowid


def query(sql: str, params: tuple = ()) -> list[dict]:
    with _lock:
        return [dict(r) for r in _conn.execute(sql, params).fetchall()]


def query_one(sql: str, params: tuple = ()) -> dict | None:
    rows = query(sql, params)
    return rows[0] if rows else None


def now() -> float:
    return time.time()


def fingerprint_lookup(fingerprint: str) -> dict | None:
    fph = device_fingerprint_hash(fingerprint)
    return query_one("SELECT * FROM users WHERE device_fingerprint = ?", (fph,))


def is_blacklisted(fingerprint: str) -> bool:
    fph = device_fingerprint_hash(fingerprint)
    return query_one("SELECT id FROM server_blacklist WHERE device_fingerprint = ?", (fph,)) is not None


def touch_last_seen(user_id: int) -> None:
    execute("UPDATE users SET last_seen = ? WHERE id = ?", (now(), user_id))


def public_profile(user: dict, domain: str) -> dict:
    return {
        "id": user["id"],
        "username": user["username"],
        "handle": f"@{user['username']}@{domain}",
        "display_name": user["display_name"],
        "gender": user["gender"],
        "age": user["age"],
        "city": user["city"],
        "goal": user["goal"],
        "interests": [t.strip() for t in (user["interests"] or "").split(",") if t.strip()],
        "bio": user["bio"],
        "photo_path": user["photo_path"],
        "cover_path": user["cover_path"],
        "role": user["role"],
        "public_key": user["public_key"],
        "server": domain,
        # Онлайн = был активен в последние 2 минуты (last_seen обновляется
        # при подключении WS и запросах). bool(last_seen) раньше показывал
        # «онлайн» вечно — даже через час после выхода.
        "online": _is_online(user["last_seen"]),
        "dating_switch": bool(user["dating_switch"]),
        "federated_search": bool(user["federated_search"]),
        "cross_server_messages": bool(user["cross_server_messages"]),
    }


def _is_online(last_seen: float | None) -> bool:
    if not last_seen:
        return False
    return (time.time() - last_seen) < 120
