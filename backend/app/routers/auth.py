import secrets

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import crypto, db
from app.config import settings
from app.deps import create_session, current_user

router = APIRouter(prefix="/api/auth", tags=["auth"])


class InviteValidateIn(BaseModel):
    code: str
    device_fingerprint: str


class LoginIn(BaseModel):
    device_fingerprint: str


class LogoutIn(BaseModel):
    token: str


def _new_username(role: str) -> str:
    base = settings.admin_username if role == "SUPER_ADMIN" else f"user_{secrets.token_hex(4)}"
    candidate = base
    n = 1
    while db.query_one("SELECT id FROM users WHERE username = ?", (candidate,)):
        candidate = f"{base}_{n}"
        n += 1
    return candidate


def _ensure_private_space(user_id: int) -> None:
    existing = db.query_one("SELECT id FROM spaces WHERE name = 'Личный' AND owner_id = ?", (user_id,))
    if not existing:
        space_id = db.execute(
            "INSERT INTO spaces (name, description, owner_id, created_at) VALUES (?, ?, ?, ?)",
            ("Личный", "Личное пространство владельца", user_id, db.now()),
        )
        db.execute(
            "INSERT INTO space_members (space_id, user_id, joined_at) VALUES (?, ?, ?)",
            (space_id, user_id, db.now()),
        )


@router.post("/invite/validate")
def validate_invite(body: InviteValidateIn):
    fingerprint = body.device_fingerprint.strip()
    if not fingerprint:
        raise HTTPException(status_code=422, detail="Отсутствует идентификатор устройства")
    if db.is_blacklisted(fingerprint):
        raise HTTPException(status_code=403, detail="Устройство заблокировано администратором")

    existing = db.fingerprint_lookup(fingerprint)
    if existing:
        token = create_session(existing["id"])
        db.touch_last_seen(existing["id"])
        return {"token": token, "user": db.public_profile(existing, settings.server_domain)}

    code = body.code.strip().upper()
    invite = db.query_one("SELECT * FROM invites WHERE code = ?", (code,))
    if not invite:
        raise HTTPException(status_code=404, detail="Неверный код приглашения")
    if invite["used_at"] is not None:
        raise HTTPException(status_code=409, detail="Код приглашения уже использован")

    role = invite["role_granted"] if invite["role_granted"] in db.ROLES else "STANDARD_USER"
    username = _new_username(role)
    recovery = crypto.new_invite_code()
    user_id = db.execute(
        """
        INSERT INTO users (username, display_name, role, device_fingerprint, recovery_code, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (
            username,
            username,
            role,
            crypto.device_fingerprint_hash(fingerprint),
            crypto.sha256_hex("rec::" + recovery),
            db.now(),
        ),
    )
    db.execute(
        "UPDATE invites SET used_by = ?, used_at = ? WHERE id = ?",
        (user_id, db.now(), invite["id"]),
    )

    if role == "SUPER_ADMIN":
        _ensure_private_space(user_id)

    if invite["space_id"] is not None:
        db.execute(
            "INSERT OR IGNORE INTO space_members (space_id, user_id, joined_at) VALUES (?, ?, ?)",
            (invite["space_id"], user_id, db.now()),
        )

    token = create_session(user_id)
    user = db.query_one("SELECT * FROM users WHERE id = ?", (user_id,))
    return {
        "token": token,
        "user": db.public_profile(user, settings.server_domain),
        "space_id": invite["space_id"],
        "recovery_code": recovery,
    }


class RecoverIn(BaseModel):
    code: str
    device_fingerprint: str


@router.post("/recover")
def recover(body: RecoverIn):
    fingerprint = body.device_fingerprint.strip()
    if not fingerprint:
        raise HTTPException(status_code=422, detail="Отсутствует идентификатор устройства")
    if db.is_blacklisted(fingerprint):
        raise HTTPException(status_code=403, detail="Устройство заблокировано администратором")
    code = body.code.strip().upper()
    if not code:
        raise HTTPException(status_code=422, detail="Введите код восстановления")
    user = db.query_one(
        "SELECT * FROM users WHERE recovery_code = ?",
        (crypto.sha256_hex("rec::" + code),),
    )
    if not user:
        raise HTTPException(status_code=404, detail="Неверный код восстановления")
    if user["banned"]:
        raise HTTPException(status_code=403, detail="Устройство заблокировано администратором")
    try:
        db.execute(
            "UPDATE users SET device_fingerprint = ? WHERE id = ?",
            (crypto.device_fingerprint_hash(fingerprint), user["id"]),
        )
    except Exception:
        # Отпечаток уже занят другим пользователем (клонированные данные
        # приложения): сначала сбрось данные приложения, потом входи.
        # Код при этом НЕ сгорает (ротация ниже не выполнена).
        raise HTTPException(
            status_code=409,
            detail="Это устройство уже привязано к другому аккаунту (перенос данных?). Очистите данные приложения и повторите.",
        )
    # Код одноразовый: выпускаем новый только после успеха, старый умирает.
    new_code = crypto.new_invite_code()
    db.execute(
        "UPDATE users SET recovery_code = ? WHERE id = ?",
        (crypto.sha256_hex("rec::" + new_code), user["id"]),
    )
    token = create_session(user["id"])
    db.touch_last_seen(user["id"])
    updated = db.query_one("SELECT * FROM users WHERE id = ?", (user["id"],))
    return {
        "token": token,
        "user": db.public_profile(updated, settings.server_domain),
        "recovery_code": new_code,
    }


@router.post("/login")
def login(body: LoginIn):
    fingerprint = body.device_fingerprint.strip()
    if not fingerprint:
        raise HTTPException(status_code=422, detail="Отсутствует идентификатор устройства")
    if db.is_blacklisted(fingerprint):
        raise HTTPException(status_code=403, detail="Устройство заблокировано администратором")
    user = db.fingerprint_lookup(fingerprint)
    if not user:
        raise HTTPException(status_code=404, detail="Учётная запись не найдена на этом устройстве")
    token = create_session(user["id"])
    db.touch_last_seen(user["id"])
    return {"token": token, "user": db.public_profile(user, settings.server_domain)}


@router.post("/logout")
def logout(body: LogoutIn):
    db.execute(
        "DELETE FROM sessions WHERE token_hash = ?",
        (crypto.session_token_hash(body.token),),
    )
    return {"ok": True}


@router.get("/me")
def me(user: dict = Depends(current_user)):
    return db.public_profile(user, settings.server_domain)
