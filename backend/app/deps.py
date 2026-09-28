from fastapi import Header, HTTPException

from app import crypto, db
from app.config import settings


def current_user(
    authorization: str = Header(default=""),
    x_device_fingerprint: str = Header(default=""),
) -> dict:
    if authorization.startswith("Bearer "):
        token = authorization[len("Bearer "):].strip()
    else:
        token = ""
    if not token or not x_device_fingerprint:
        raise HTTPException(status_code=401, detail="Требуется авторизация")
    session = db.query_one(
        "SELECT * FROM sessions WHERE token_hash = ?",
        (crypto.session_token_hash(token),),
    )
    if not session or session["expires_at"] < db.now():
        raise HTTPException(status_code=401, detail="Сессия истекла, войдите заново")
    user = db.query_one("SELECT * FROM users WHERE id = ?", (session["user_id"],))
    if not user or user["device_fingerprint"] != crypto.device_fingerprint_hash(x_device_fingerprint):
        raise HTTPException(status_code=401, detail="Устройство не привязано к сессии")
    if user["banned"]:
        raise HTTPException(status_code=403, detail="Устройство заблокировано администратором")
    return user


def require_role(user: dict, role: str) -> dict:
    if db.ROLE_RANK.get(user["role"], 0) < db.ROLE_RANK.get(role, 0):
        raise HTTPException(status_code=403, detail="Недостаточно прав")
    return user


def create_session(user_id: int) -> str:
    token = crypto.new_token()
    db.execute(
        "INSERT INTO sessions (user_id, token_hash, created_at, expires_at) VALUES (?, ?, ?, ?)",
        (user_id, crypto.session_token_hash(token), db.now(), db.now() + settings.session_ttl_seconds),
    )
    return token
