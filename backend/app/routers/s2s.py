from fastapi import APIRouter, Request, HTTPException
from pydantic import BaseModel

from app import crypto, db
from app.config import settings
from app.federation import verify_s2s_request
from app.ws_manager import message_bus

router = APIRouter(prefix="/s2s", tags=["s2s"])

DATING_LIMIT = 50


class LinkRequest(BaseModel):
    domain: str
    name: str = ""
    secret: str


class LookupIn(BaseModel):
    username: str
    origin_domain: str


class DatingIn(BaseModel):
    filters: dict
    origin_domain: str


class RelayIn(BaseModel):
    event: dict


class BanNotifyIn(BaseModel):
    device_fingerprint: str


def _check_s2s(request: Request, body: bytes) -> str:
    if settings.federation_mode == "closed":
        raise HTTPException(status_code=403, detail="Федерация отключена")
    domain = (request.headers.get("x-s2s-domain") or "").strip().lower()
    if not domain:
        raise HTTPException(status_code=401, detail="Отсутствует домен отправителя")
    if not verify_s2s_request(domain, request.url.path, dict(request.headers), body):
        raise HTTPException(status_code=401, detail="Недействительная подпись S2S")
    return domain


@router.post("/link_request")
def link_request(body: LinkRequest):
    if settings.federation_mode == "closed":
        raise HTTPException(status_code=403, detail="Федерация отключена")
    if settings.federation_mode == "allowlist":
        raise HTTPException(
            status_code=403,
            detail="Спаривание только вручную (админ)",
        )
    domain = body.domain.strip().lower()
    if not domain:
        raise HTTPException(status_code=422, detail="Некорректный домен")
    if not body.secret or len(body.secret) < 16:
        raise HTTPException(status_code=422, detail="Слабый секрет рукопожатия")
    db.execute(
        """
        INSERT INTO server_registry (domain, name, shared_secret, linked_at, active)
        VALUES (?, ?, ?, ?, 1)
        ON CONFLICT(domain) DO UPDATE SET
          name = excluded.name,
          shared_secret = excluded.shared_secret,
          linked_at = excluded.linked_at,
          active = 1
        """,
        (domain, body.name.strip()[:64], body.secret, db.now()),
    )
    return {"ok": True, "domain": settings.server_domain}


@router.post("/lookup")
async def lookup(body: LookupIn, request: Request):
    body_bytes = await request.body()
    _check_s2s(request, body_bytes)
    # Поиск по нику. ВАЖНО: сравнение в Python, а не через SQL lower() —
    # SQLite lower() не понимает кириллицу и ломает поиск кириллических ников.
    needle = body.username.strip().lstrip("@").lower()
    local = None
    for row in db.query(
        "SELECT * FROM users WHERE banned = 0 AND federated_search = 1"
    ):
        if row["username"].lower() == needle:
            local = row
            break
    return {"profile": db.public_profile(local, settings.server_domain) if local else None}


@router.post("/dating_search")
async def dating_search(body: DatingIn, request: Request):
    body_bytes = await request.body()
    _check_s2s(request, body_bytes)
    f = body.filters or {}
    clauses = ["banned = 0", "dating_switch = 1"]
    params: list = []
    if f.get("gender"):
        clauses.append("gender = ?")
        params.append(f["gender"])
    if f.get("age_min") is not None:
        clauses.append("age >= ?")
        params.append(f["age_min"])
    if f.get("age_max") is not None:
        clauses.append("age <= ?")
        params.append(f["age_max"])
    if f.get("city"):
        # Фильтрация по городу в Python: SQLite lower() не понимает кириллицу.
        pass
    tags = f.get("tags") or []
    rows = db.query(
        f"SELECT * FROM users WHERE {' AND '.join(clauses)} ORDER BY last_seen DESC LIMIT ?",
        (*params, DATING_LIMIT * 4),
    )
    city = f.get("city")
    if city:
        rows = [
            r
            for r in rows
            if str(city).strip().lower() == (r.get("city") or "").strip().lower()
        ]
    if tags:
        text_rows = [(r, (r.get("interests") or "").lower()) for r in rows]
        rows = [
            r
            for r, text in text_rows
            if any(str(t).strip().lower() and (str(t).strip().lower() in text) for t in tags[:10])
        ]
    return {
        "profiles": [db.public_profile(r, settings.server_domain) for r in rows[:DATING_LIMIT]]
    }


@router.post("/relay")
async def relay(body: RelayIn, request: Request):
    body_bytes = await request.body()
    origin = _check_s2s(request, body_bytes)
    event = body.event or {}
    if not isinstance(event, dict) or "type" not in event:
        raise HTTPException(status_code=422, detail="Некорректное событие")
    targets = event.get("to") or []
    delivered = 0
    for target in targets:
        kind, _, rest = target.partition(":")
        if kind == "user":
            await message_bus._route_user(int(rest), event, event.get("msg_id"))
            delivered += 1
        elif kind == "space":
            for m in db.query("SELECT user_id FROM space_members WHERE space_id = ?", (int(rest),)):
                await message_bus._route_user(m["user_id"], event, event.get("msg_id"))
                delivered += 1
    return {"ok": True, "origin": origin, "delivered": delivered}


@router.post("/ban_notify")
async def ban_notify(body: BanNotifyIn, request: Request):
    body_bytes = await request.body()
    origin = _check_s2s(request, body_bytes)
    existing = db.query_one(
        "SELECT id FROM server_blacklist WHERE device_fingerprint = ?", (body.device_fingerprint,)
    )
    if not existing:
        db.execute(
            "INSERT INTO server_blacklist (device_fingerprint, reason, banned_by, banned_at) VALUES (?, ?, NULL, ?)",
            (body.device_fingerprint, f"Федеральный бан от {origin}", db.now()),
        )
    db.execute("UPDATE users SET banned = 1 WHERE device_fingerprint = ?", (body.device_fingerprint,))
    return {"ok": True}
