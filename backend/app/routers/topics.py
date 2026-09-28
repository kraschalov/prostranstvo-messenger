"""Темы (групповые комнаты). Вариант А: общий ключ комнаты, сервер —
глухой ретранслятор (шифртекст), членство и права — здесь.

Создание: SUPER_ADMIN и FAMILY_MEMBER. Гости создавать не могут.
Приватность: closed (только по инвайтам), server_open (видны всем
сервера), project_open (видны в федерации; релей чужим серверам —
следующий этап, пока ведёт себя как server_open).
Приглашать: owner всегда; участники — если invite_policy=members
и личный can_invite=1. Права на участника: can_post, can_invite, role.
"""

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import db
from app.config import settings
from app.deps import current_user, require_role

router = APIRouter(prefix="/api/topics", tags=["topics"])


class TopicCreate(BaseModel):
    name: str
    description: str = ""
    privacy: str = "closed"
    scope: str = "server"
    visibility: str = "hidden"


class TopicUpdate(BaseModel):
    name: str | None = None
    description: str | None = None
    privacy: str | None = None
    scope: str | None = None
    invite_policy: str | None = None
    default_can_post: bool | None = None
    visibility: str | None = None


class TopicInvite(BaseModel):
    username: str


class TopicRights(BaseModel):
    can_post: bool | None = None
    can_invite: bool | None = None
    role: str | None = None


def _topic(topic_id: int) -> dict:
    t = db.query_one("SELECT * FROM topics WHERE id = ?", (topic_id,))
    if not t:
        raise HTTPException(status_code=404, detail="Тема не найдена")
    return t


def _membership(topic_id: int, user_id: int) -> dict | None:
    return db.query_one(
        "SELECT * FROM topic_members WHERE topic_id = ? AND user_id = ?",
        (topic_id, user_id),
    )


def _is_owner(t: dict, user: dict) -> bool:
    return user["role"] == "SUPER_ADMIN" or t["owner_id"] == user["id"]


def _require_member(topic_id: int, user: dict) -> dict:
    m = _membership(topic_id, user["id"])
    if not m and user["role"] != "SUPER_ADMIN":
        raise HTTPException(status_code=403, detail="Вы не участник темы")
    return m or {}


@router.post("")
def create_topic(body: TopicCreate, user: dict = Depends(current_user)):
    require_role(user, "FAMILY_MEMBER")
    name = body.name.strip()[:64]
    if not name:
        raise HTTPException(status_code=422, detail="Название темы пустое")
    if body.privacy not in ("closed", "open"):
        raise HTTPException(status_code=422, detail="Приватность: closed | open")
    vis = (body.visibility or "hidden").strip().lower()
    if vis not in ("hidden", "inside", "everywhere", "outside_only"):
        vis = "hidden"
    scope = body.scope.strip().lower() if body.scope else "server"
    if scope not in ("server", "project"):
        scope = "server"
    db.execute(
        """INSERT INTO topics
           (name, description, owner_id, privacy, scope, visibility, invite_policy, default_can_post, created_at)
           VALUES (?, ?, ?, ?, ?, ?, 'owner', 1, ?)""",
        (name, body.description.strip()[:255], user["id"], body.privacy, scope, vis, db.now()),
    )
    row = db.query_one("SELECT id FROM topics WHERE owner_id = ? ORDER BY id DESC LIMIT 1", (user["id"],))
    db.execute(
        """INSERT OR IGNORE INTO topic_members
           (topic_id, user_id, role, can_post, can_invite, joined_at)
           VALUES (?, ?, 'owner', 1, 1, ?)""",
        (row["id"], user["id"], db.now()),
    )
    return {"ok": True, "id": row["id"]}


@router.get("")
def list_my_topics(user: dict = Depends(current_user)):
    rows = db.query(
        """SELECT t.*, tm.role AS my_role FROM topics t
           JOIN topic_members tm ON tm.topic_id = t.id AND tm.user_id = ?
           ORDER BY t.created_at DESC""",
        (user["id"],),
    )
    return {"topics": rows}


@router.get("/open")
def list_open_topics(user: dict = Depends(current_user)):
    """Темы с видимостью: server_open/project_open. Для блока «Темы»."""
    rows = db.query(
        """SELECT t.*, u.display_name AS owner_name,
                  (SELECT COUNT(*) FROM topic_members tm WHERE tm.topic_id = t.id) AS member_count
           FROM topics t LEFT JOIN users u ON u.id = t.owner_id
           WHERE t.visibility IN ('inside', 'everywhere')
           ORDER BY t.name"""
    )
    return {"topics": rows}


@router.get("/{topic_id}")
def get_topic(topic_id: int, user: dict = Depends(current_user)):
    t = _topic(topic_id)
    m = _membership(topic_id, user["id"])
    if not m and t["privacy"] == "closed" and not _is_owner(t, user):
        raise HTTPException(status_code=403, detail="Закрытая тема")
    return {"topic": dict(t), "membership": dict(m) if m else None}


@router.put("/{topic_id}")
def update_topic(topic_id: int, body: TopicUpdate, user: dict = Depends(current_user)):
    t = _topic(topic_id)
    if not _is_owner(t, user):
        raise HTTPException(status_code=403, detail="Только владелец темы")
    sets, params = [], []
    if body.name is not None and body.name.strip():
        sets.append("name = ?")
        params.append(body.name.strip()[:64])
    if body.description is not None:
        sets.append("description = ?")
        params.append(body.description.strip()[:255])
    if body.privacy is not None:
        if body.privacy not in ("closed", "open"):
            raise HTTPException(status_code=422, detail="Приватность: closed | open")
        sets.append("privacy = ?")
        params.append(body.privacy)
    if body.scope is not None:
        sets.append("scope = ?")
        params.append("project" if body.scope == "project" else "server")
    if body.invite_policy is not None:
        if body.invite_policy not in ("owner", "members"):
            raise HTTPException(status_code=422, detail="invite_policy: owner | members")
        sets.append("invite_policy = ?")
        params.append(body.invite_policy)
        if body.invite_policy == "members":
            db.execute(
                "UPDATE topic_members SET can_invite = 1 WHERE topic_id = ?",
                (topic_id,),
            )
    if body.default_can_post is not None:
        sets.append("default_can_post = ?")
        params.append(1 if body.default_can_post else 0)
    if body.visibility is not None:
        v = body.visibility.strip().lower()
        if v not in ("hidden", "inside", "everywhere", "outside_only"):
            raise HTTPException(status_code=422, detail="Видимость: hidden | inside | everywhere | outside_only")
        sets.append("visibility = ?")
        params.append(v)
    if sets:
        db.execute(f"UPDATE topics SET {', '.join(sets)} WHERE id = ?", (*params, topic_id))
    return {"ok": True}


@router.post("/{topic_id}/members")
def invite_member(topic_id: int, body: TopicInvite, user: dict = Depends(current_user)):
    t = _topic(topic_id)
    m = _membership(topic_id, user["id"])
    allowed = _is_owner(t, user) or (
        t["invite_policy"] == "members" and m and m["can_invite"]
    )
    if not allowed:
        raise HTTPException(status_code=403, detail="Приглашать не разрешено")
    target = db.query_one(
        "SELECT * FROM users WHERE lower(username) = lower(?) AND banned = 0",
        (body.username.strip(),),
    )
    if not target:
        raise HTTPException(status_code=404, detail="Пользователь не найден на этом сервере")
    db.execute(
        """INSERT OR IGNORE INTO topic_members
           (topic_id, user_id, role, can_post, can_invite, joined_at)
           VALUES (?, ?, 'member', ?, 0, ?)""",
        (topic_id, target["id"], t["default_can_post"], db.now()),
    )
    return {"ok": True, "user_id": target["id"]}


@router.post("/{topic_id}/members/{uid}")
def set_rights(topic_id: int, uid: int, body: TopicRights, user: dict = Depends(current_user)):
    t = _topic(topic_id)
    if not _is_owner(t, user):
        raise HTTPException(status_code=403, detail="Только владелец темы")
    if not _membership(topic_id, uid):
        raise HTTPException(status_code=404, detail="Не участник темы")
    sets, params = [], []
    if body.can_post is not None:
        sets.append("can_post = ?")
        params.append(1 if body.can_post else 0)
    if body.can_invite is not None:
        sets.append("can_invite = ?")
        params.append(1 if body.can_invite else 0)
    if body.role is not None:
        if body.role not in ("moderator", "member"):
            raise HTTPException(status_code=422, detail="role: moderator | member")
        sets.append("role = ?")
        params.append(body.role)
    if sets:
        db.execute(
            f"UPDATE topic_members SET {', '.join(sets)} WHERE topic_id = ? AND user_id = ?",
            (*params, topic_id, uid),
        )
    return {"ok": True}


@router.delete("/{topic_id}/members/{uid}")
def kick_member(topic_id: int, uid: int, user: dict = Depends(current_user)):
    t = _topic(topic_id)
    if not _is_owner(t, user):
        raise HTTPException(status_code=403, detail="Только владелец темы")
    if uid == t["owner_id"]:
        # Хозяин сервера забирает тему себе вместе с исключением создателя.
        if user["role"] != "SUPER_ADMIN":
            raise HTTPException(status_code=403, detail="Владельца исключить нельзя")
        db.execute("UPDATE topics SET owner_id = ? WHERE id = ?", (user["id"],))
    db.execute("DELETE FROM topic_members WHERE topic_id = ? AND user_id = ?", (topic_id, uid))
    return {"ok": True}


@router.post("/{topic_id}/join")
def join_topic(topic_id: int, user: dict = Depends(current_user)):
    t = _topic(topic_id)
    if t["privacy"] != "open":
        raise HTTPException(status_code=403, detail="Закрытая тема — нужно приглашение")
    db.execute(
        """INSERT OR IGNORE INTO topic_members
           (topic_id, user_id, role, can_post, can_invite, joined_at)
           VALUES (?, ?, 'member', ?, 0, ?)""",
        (topic_id, user["id"], t["default_can_post"], db.now()),
    )
    return {"ok": True}


@router.post("/{topic_id}/leave")
def leave_topic(topic_id: int, user: dict = Depends(current_user)):
    _topic(topic_id)
    db.execute("DELETE FROM topic_members WHERE topic_id = ? AND user_id = ?", (topic_id, user["id"]))
    return {"ok": True}


@router.get("/{topic_id}/members")
def topic_members(topic_id: int, user: dict = Depends(current_user)):
    t = _topic(topic_id)
    m = _membership(topic_id, user["id"])
    if not m and t["privacy"] == "closed" and not _is_owner(t, user):
        raise HTTPException(status_code=403, detail="Закрытая тема")
    rows = db.query(
        """SELECT u.id, u.username, u.display_name, u.public_key, tm.role, tm.can_post, tm.can_invite
           FROM topic_members tm JOIN users u ON u.id = tm.user_id
           WHERE tm.topic_id = ?""",
        (topic_id,),
    )
    return {"members": rows}
