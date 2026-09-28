import asyncio

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import crypto, db
from app.config import settings
from app.deps import current_user, require_role
from app.federation import s2s_client
from app.ws_manager import message_bus

router = APIRouter(prefix="/api/admin", tags=["admin"])


class BanIn(BaseModel):
    device_fingerprint: str
    reason: str = ""


class UnbanIn(BaseModel):
    device_fingerprint: str


class AppealResolveIn(BaseModel):
    action: str  # accept | reject


class FederationLinkIn(BaseModel):
    domain: str
    name: str = ""


class FederationUnlinkIn(BaseModel):
    domain: str


class FederationModeIn(BaseModel):
    mode: str  # closed | allowlist | open


@router.post("/ban")
async def ban(body: BanIn, admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    fph = crypto.device_fingerprint_hash(body.device_fingerprint.strip())
    existing = db.query_one("SELECT id FROM server_blacklist WHERE device_fingerprint = ?", (fph,))
    if not existing:
        db.execute(
            "INSERT INTO server_blacklist (device_fingerprint, reason, banned_by, banned_at) VALUES (?, ?, ?, ?)",
            (fph, body.reason.strip()[:255], admin["id"], db.now()),
        )
    db.execute("UPDATE users SET banned = 1 WHERE device_fingerprint = ?", (fph,))
    user = db.query_one("SELECT id FROM users WHERE device_fingerprint = ?", (fph,))
    if user:
        await message_bus.terminate_user(user["id"])
    for peer in db.query("SELECT * FROM server_registry WHERE active = 1"):
        await s2s_client.ban_notify(peer, fph)
    return {"ok": True, "banned": bool(user)}


@router.post("/unban")
def unban(body: UnbanIn, admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    fph = crypto.device_fingerprint_hash(body.device_fingerprint.strip())
    db.execute("DELETE FROM server_blacklist WHERE device_fingerprint = ?", (fph,))
    db.execute("UPDATE users SET banned = 0 WHERE device_fingerprint = ?", (fph,))
    return {"ok": True}


@router.get("/blacklist")
def blacklist(admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    rows = db.query(
        """
        SELECT b.device_fingerprint, b.reason, b.banned_at, u.username
        FROM server_blacklist b LEFT JOIN users u ON u.device_fingerprint = b.device_fingerprint
        ORDER BY b.banned_at DESC
        """
    )
    return {"blacklist": rows}


@router.get("/appeals")
def appeals(admin: dict = Depends(current_user), status: str = "pending"):
    require_role(admin, "SUPER_ADMIN")
    rows = db.query(
        "SELECT * FROM appeals WHERE status = ? ORDER BY created_at ASC", (status,)
    )
    return {"appeals": rows}


@router.post("/appeals/{appeal_id}/resolve")
def resolve_appeal(appeal_id: int, body: AppealResolveIn, admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    appeal = db.query_one("SELECT * FROM appeals WHERE id = ?", (appeal_id,))
    if not appeal:
        raise HTTPException(status_code=404, detail="Апелляция не найдена")
    if body.action not in ("accept", "reject"):
        raise HTTPException(status_code=422, detail="Действие: accept или reject")
    db.execute(
        "UPDATE appeals SET status = ? WHERE id = ?",
        ("resolved" if body.action == "accept" else "rejected", appeal_id),
    )
    if body.action == "accept":
        db.execute("DELETE FROM server_blacklist WHERE device_fingerprint = ?", (appeal["device_fingerprint"],))
        db.execute("UPDATE users SET banned = 0 WHERE device_fingerprint = ?", (appeal["device_fingerprint"],))
    return {"ok": True}


@router.get("/dashboard")
def dashboard(admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    users = db.query_one("SELECT COUNT(*) AS c FROM users")
    spaces = db.query_one("SELECT COUNT(*) AS c FROM spaces")
    peers = db.query_one("SELECT COUNT(*) AS c FROM server_registry WHERE active = 1")
    pending_appeals = db.query_one("SELECT COUNT(*) AS c FROM appeals WHERE status = 'pending'")
    return {
        "users": users["c"],
        "spaces": spaces["c"],
        "peers": peers["c"],
        "pending_appeals": pending_appeals["c"],
        "online": message_bus.online_count,
    }


@router.post("/federation/link")
async def federation_link(body: FederationLinkIn, admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    domain = body.domain.strip().lower()
    if not domain or "/" in domain or ":" in domain:
        raise HTTPException(status_code=422, detail="Некорректный домен сервера")
    if domain == settings.server_domain.lower():
        raise HTTPException(status_code=422, detail="Нельзя связать сервер с самим собой")
    ok, message = await s2s_client.link(domain, body.name.strip()[:64])
    if not ok:
        raise HTTPException(status_code=502, detail=f"Не удалось связать сервер: {message}")
    return {"ok": True, "domain": domain}


@router.get("/federation/peers")
def federation_peers(admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    return {"peers": db.query("SELECT domain, name, linked_at, active FROM server_registry ORDER BY linked_at")}


@router.post("/federation/unlink")
def federation_unlink(body: FederationUnlinkIn, admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    db.execute("DELETE FROM server_registry WHERE domain = ?", (body.domain.strip().lower(),))
    return {"ok": True}


class ServerProfileIn(BaseModel):
    name: str = ""
    city: str = ""
    country: str = ""


@router.get("/server/profile")
def server_profile_get(admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    return {"name": settings.server_name, "city": settings.server_city, "country": settings.server_country}


@router.post("/server/profile")
def server_profile_set(body: ServerProfileIn, admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    from pathlib import Path

    name = body.name.strip()[:64]
    city = body.city.strip()[:64]
    country = body.country.strip()[:64]
    if name:
        settings.server_name = name
    settings.server_city = city
    settings.server_country = country
    from app.config import BASE_DIR

    env_path = BASE_DIR / ".env"
    try:
        text = env_path.read_text(encoding="utf-8") if env_path.exists() else ""
    except OSError:
        text = ""
    import re

    def _set(key: str, val: str, src: str) -> str:
        if re.search(rf"(?m)^{key}=", src):
            return re.sub(rf"(?m)^{key}=.*$", f"{key}={val}", src)
        return src.rstrip("\n") + f"\n{key}={val}\n"

    if name:
        text = _set("SERVER_NAME", name, text)
    text = _set("SERVER_CITY", city, text)
    text = _set("SERVER_COUNTRY", country, text)
    env_path.write_text(text, encoding="utf-8")
    return {"ok": True, "name": settings.server_name, "city": settings.server_city, "country": settings.server_country}


@router.get("/updates/status")
def updates_status(admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    from app import updater as _updater

    return _updater.check()


@router.post("/updates/pull")
def updates_pull(admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    from app import updater as _updater

    return _updater.pull()


@router.get("/federation/mode")
def federation_mode_get(admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    return {"mode": settings.federation_mode}


@router.post("/federation/mode")
def federation_mode_set(body: FederationModeIn, admin: dict = Depends(current_user)):
    require_role(admin, "SUPER_ADMIN")
    mode = body.mode.strip().lower()
    if mode not in ("closed", "allowlist", "open"):
        raise HTTPException(status_code=422, detail="Режим: closed | allowlist | open")
    settings.federation_mode = mode
    # Персистим в .env, чтобы пережил рестарт.
    from pathlib import Path

    from app.config import BASE_DIR

    env_path = BASE_DIR / ".env"
    try:
        text = env_path.read_text(encoding="utf-8") if env_path.exists() else ""
    except OSError:
        text = ""
    import re

    if re.search(r"(?m)^FEDERATION_MODE=", text):
        text = re.sub(r"(?m)^FEDERATION_MODE=.*$", f"FEDERATION_MODE={mode}", text)
    else:
        text = text.rstrip("\n") + f"\nFEDERATION_MODE={mode}\n"
    env_path.write_text(text, encoding="utf-8")
    return {"ok": True, "mode": mode}
