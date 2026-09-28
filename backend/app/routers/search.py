import asyncio

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel

from app import db
from app.config import settings
from app.deps import current_user
from app.federation import S2SClient, s2s_client

router = APIRouter(prefix="/api/search", tags=["search"])

DATING_LIMIT = 50


class DatingFilter(BaseModel):
    gender: str | None = None
    age_min: int | None = None
    age_max: int | None = None
    city: str | None = None
    tags: list[str] | None = None


def _matches_city(row: dict, city: str) -> bool:
    # Сравнение в Python: SQLite lower() не понимает кириллицу.
    return city.strip().lower() == (row.get("city") or "").strip().lower()


def _matches_tags(row: dict, tags: list[str]) -> bool:
    # Совпадение по интересам (подстрока) — регистронезависимо через Python.
    text = (row.get("interests") or "").lower()
    return any((t or "").strip().lower() and (t.strip().lower() in text) for t in tags)


def _dating_where(f: DatingFilter) -> tuple[str, list]:
    # Себя тоже показываем (владелец хочет видеть себя в инсайдерах).
    clauses = ["banned = 0", "dating_switch = 1"]
    params: list = []
    if f.gender:
        clauses.append("gender = ?")
        params.append(f.gender)
    if f.age_min is not None:
        clauses.append("age >= ?")
        params.append(f.age_min)
    if f.age_max is not None:
        clauses.append("age <= ?")
        params.append(f.age_max)
    # city/tags фильтруются в Python (SQL отсутствует): см. _apply_dating_filters.
    if f.city:
        # Плейсхолдер не используется, но оставляем пару no-op для явности.
        pass
    if f.tags:
        # no-op; фильтрация в Python ниже.
        pass
    return " AND ".join(clauses), params


def _apply_dating_filters(rows: list[dict], f: DatingFilter) -> list[dict]:
    result = rows
    if f.city:
        result = [r for r in result if _matches_city(r, f.city)]
    if f.tags:
        result = [r for r in result if _matches_tags(r, f.tags)]
    return result


@router.get("/by_username")
async def search_by_username(
    q: str = Query(min_length=1, max_length=64),
    user: dict = Depends(current_user),
):
    query = q.strip().lstrip("@")
    domain = None
    if "@" in query:
        query, domain = query.rsplit("@", 1)
    query_lower = query.lower()

    if domain and domain.lower() != settings.server_domain.lower():
        peer = db.query_one("SELECT * FROM server_registry WHERE lower(domain) = lower(?) AND active = 1", (domain,))
        if not peer:
            raise HTTPException(status_code=404, detail="Сервер не связан с этой сетью")
        result = await s2s_client.lookup(peer, query, settings.server_domain)
        if result["ok"] and result["body"].get("profile"):
            return {"profile": result["body"]["profile"], "origin": domain}
        raise HTTPException(status_code=404, detail="Пользователь не найден")

    # Локальный поиск по нику. ВАЖНО: сравнение в Python, а НЕ через SQL
    # `lower(username) = lower(?)` — SQLite lower() не работает для кириллицы
    # (возвращает строку без изменений), из-за чего поиск кириллических ников
    # всегда давал 404 («Пользователь не найден»).
    local = None
    for row in db.query("SELECT * FROM users WHERE banned = 0"):
        if row["username"].lower() == query_lower:
            local = row
            break
    if local:
        if not local["federated_search"] and local["id"] != user["id"]:
            raise HTTPException(status_code=403, detail="Пользователь скрыт из поиска")
        return {"profile": db.public_profile(local, settings.server_domain), "origin": settings.server_domain}

    peers = db.query("SELECT * FROM server_registry WHERE active = 1")
    if not peers:
        raise HTTPException(status_code=404, detail="Пользователь не найден")

    async def try_peer(peer):
        result = await s2s_client.lookup(peer, query, settings.server_domain)
        return peer["domain"], result

    results = await asyncio.gather(*(try_peer(p) for p in peers))
    for origin, result in results:
        if result["ok"] and result["body"].get("profile"):
            return {"profile": result["body"]["profile"], "origin": origin}
    raise HTTPException(status_code=404, detail="Пользователь не найден ни на одном сервере")


@router.post("/dating")
async def dating_search(f: DatingFilter, user: dict = Depends(current_user)):
    if not user["dating_switch"]:
        raise HTTPException(status_code=403, detail="Включите «Ищу знакомства» в настройках профиля")
    where, params = _dating_where(f)
    rows = db.query(
        f"SELECT * FROM users WHERE {where} ORDER BY last_seen DESC LIMIT ?",
        (*params, DATING_LIMIT * 4),
    )
    # city/tags отфильтровываем в Python (SQLite lower() не понимает кириллицу).
    rows = _apply_dating_filters(rows, f)[:DATING_LIMIT]
    import logging as _logging
    _logging.warning("DATINGDBG user=%s filters=%s local_n=%s", user["id"], f.model_dump(), len(rows))
    local = [db.public_profile(r, settings.server_domain) for r in rows]

    peers = db.query("SELECT * FROM server_registry WHERE active = 1")

    async def remote(peer):
        result = await s2s_client.dating_search(peer, f.model_dump(), settings.server_domain)
        if not result["ok"] or not result["body"].get("profiles"):
            return []
        return result["body"]["profiles"]

    remote_profiles: list = []
    if peers:
        merged = await asyncio.gather(*(remote(p) for p in peers))
        remote_profiles = [p for batch in merged for p in batch]

    return {"profiles": local + remote_profiles, "origin": settings.server_domain}
