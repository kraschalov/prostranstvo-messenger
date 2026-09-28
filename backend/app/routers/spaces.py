from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import crypto, db
from app.config import settings
from app.deps import current_user, require_role

router = APIRouter(prefix="/api/spaces", tags=["spaces"])


class SpaceCreate(BaseModel):
    name: str
    description: str = ""


class SpaceUpdate(BaseModel):
    name: str | None = None
    description: str | None = None


class MemberAdd(BaseModel):
    username: str


class InviteCreate(BaseModel):
    role: str = "STANDARD_USER"


@router.get("")
def list_spaces(user: dict = Depends(current_user)):
    if user["role"] == "SUPER_ADMIN":
        rows = db.query("SELECT * FROM spaces ORDER BY created_at DESC")
    else:
        rows = db.query(
            """
            SELECT s.* FROM spaces s
            WHERE s.owner_id = ? OR EXISTS (
              SELECT 1 FROM space_members sm WHERE sm.space_id = s.id AND sm.user_id = ?
            )
            ORDER BY s.created_at DESC
            """,
            (user["id"], user["id"]),
        )
    return {"spaces": rows}


@router.get("/open")
def list_open_spaces(user: dict = Depends(current_user)):
    """Пространства с включённой видимостью («открытые»): видны всем,
    в том числе не состоящим в них. Для блока «Открытые пространства»."""
    rows = db.query(
        """
        SELECT s.id, s.name, s.description, s.owner_id, s.isolated, s.visible,
               u.display_name AS owner_name, u.username AS owner_username,
               (SELECT COUNT(*) FROM space_members sm WHERE sm.space_id = s.id) AS member_count
        FROM spaces s
        LEFT JOIN users u ON u.id = s.owner_id
        WHERE s.visible = 1
        ORDER BY s.name
        """
    )
    return {"spaces": rows}


@router.get("/mine")
def list_my_spaces(user: dict = Depends(current_user)):
    """Пространства пользователя: где он владелец ИЛИ участник. Для блока
    «Мои пространства» (админ видит только свои, не все сервера)."""
    rows = db.query(
        """
        SELECT s.* FROM spaces s
        WHERE s.owner_id = ?
           OR EXISTS (SELECT 1 FROM space_members sm WHERE sm.space_id = s.id AND sm.user_id = ?)
        ORDER BY s.created_at DESC
        """,
        (user["id"], user["id"]),
    )
    return {"spaces": rows}


@router.post("")
def create_space(body: SpaceCreate, user: dict = Depends(current_user)):
    require_role(user, "FAMILY_MEMBER")
    # Участник изолированного пространства, не являющийся его владельцем,
    # не может создавать свои пространства — он приглашён для конкретной
    # изолированной задачи. Владелец изолированного пространства сохраняет
    # право создавать другие пространства.
    if user["role"] != "SUPER_ADMIN":
        confined = db.query_one(
            """
            SELECT s.id FROM space_members sm
            JOIN spaces s ON s.id = sm.space_id
            WHERE sm.user_id = ? AND s.isolated = 1 AND s.owner_id != ?
            LIMIT 1
            """,
            (user["id"], user["id"]),
        )
        if confined:
            raise HTTPException(
                status_code=403,
                detail="Вы приглашены в изолированное пространство — создание своих пространств недоступно",
            )
    name = body.name.strip()
    if not (1 <= len(name) <= 64):
        raise HTTPException(status_code=422, detail="Название пространства: 1–64 символа")
    if user["role"] == "FAMILY_MEMBER":
        owned = db.query_one(
            "SELECT COUNT(*) AS c FROM spaces WHERE owner_id = ?", (user["id"],)
        )
        if owned["c"] >= settings.max_family_spaces:
            raise HTTPException(
                status_code=403,
                detail=f"Член семьи может создать не более {settings.max_family_spaces} пространств",
            )
    # Видимость пространства независима от межпространственности владельца.
    # Новое пространство создаётся закрытым; владелец включает «Видимость
    # в общем» явно через set_space_settings.
    visible = 0
    space_id = db.execute(
        "INSERT INTO spaces (name, description, owner_id, created_at, visible) VALUES (?, ?, ?, ?, ?)",
        (name, body.description.strip()[:255], user["id"], db.now(), visible),
    )
    db.execute(
        "INSERT INTO space_members (space_id, user_id, joined_at) VALUES (?, ?, ?)",
        (space_id, user["id"], db.now()),
    )
    return db.query_one("SELECT * FROM spaces WHERE id = ?", (space_id,))


@router.get("/{space_id}/members")
def list_members(space_id: int, user: dict = Depends(current_user)):
    space = db.query_one("SELECT * FROM spaces WHERE id = ?", (space_id,))
    if not space:
        raise HTTPException(status_code=404, detail="Пространство не найдено")
    is_inside = user["role"] == "SUPER_ADMIN" or db.query_one(
        "SELECT 1 FROM space_members WHERE space_id = ? AND user_id = ?",
        (space_id, user["id"]),
    )
    if is_inside:
        rows = db.query(
            """
            SELECT u.id, u.username, u.display_name, u.role, u.last_seen
            FROM space_members sm JOIN users u ON u.id = sm.user_id
            WHERE sm.space_id = ?
            """,
            (space_id,),
        )
        return {"members": rows, "open": bool(space["visible"])}
    # Открытое пространство видно со стороны, но только «инсайдеры»
    # (dating_switch = 1) — те, кто включил межпространственность.
    if not space["visible"]:
        raise HTTPException(status_code=403, detail="Вы не состоите в этом пространстве")
    rows = db.query(
        """
        SELECT u.id, u.username, u.display_name, u.role, u.last_seen
        FROM space_members sm JOIN users u ON u.id = sm.user_id
        WHERE sm.space_id = ? AND u.dating_switch = 1
        """,
        (space_id,),
    )
    return {"members": rows, "open": True}


def _require_owner(space_id: int, user: dict) -> None:
    """Право на изменение пространства/участников: владелец или SUPER_ADMIN."""
    if user["role"] == "SUPER_ADMIN":
        return
    space = db.query_one("SELECT * FROM spaces WHERE id = ?", (space_id,))
    if not space:
        raise HTTPException(status_code=404, detail="Пространство не найдено")
    if space["owner_id"] != user["id"]:
        raise HTTPException(status_code=403, detail="Только владелец пространства может это делать")


@router.put("/{space_id}")
def update_space(space_id: int, body: SpaceUpdate, user: dict = Depends(current_user)):
    """Изменение названия/описания пространства владельцем."""
    space = db.query_one("SELECT * FROM spaces WHERE id = ?", (space_id,))
    if not space:
        raise HTTPException(status_code=404, detail="Пространство не найдено")
    _require_owner(space_id, user)
    name = (body.name if body.name is not None else space["name"]).strip()
    desc = (body.description if body.description is not None else space["description"]).strip()[:255]
    if not (1 <= len(name) <= 64):
        raise HTTPException(status_code=422, detail="Название пространства: 1–64 символа")
    db.execute(
        "UPDATE spaces SET name = ?, description = ? WHERE id = ?",
        (name, desc, space_id),
    )
    return db.query_one("SELECT * FROM spaces WHERE id = ?", (space_id,))


@router.post("/{space_id}/members")
def add_member(space_id: int, body: MemberAdd, user: dict = Depends(current_user)):
    """Добавление участника в пространство по никнейму (должен быть
    зарегистрирован на этом сервере)."""
    space = db.query_one("SELECT * FROM spaces WHERE id = ?", (space_id,))
    if not space:
        raise HTTPException(status_code=404, detail="Пространство не найдено")
    _require_owner(space_id, user)
    target = db.query_one(
        "SELECT * FROM users WHERE lower(username) = lower(?) AND banned = 0",
        (body.username.strip(),),
    )
    if not target:
        raise HTTPException(status_code=404, detail="Пользователь не найден на этом сервере")
    if target["id"] == space["owner_id"]:
        raise HTTPException(status_code=403, detail="Владелец уже является участником")
    db.execute(
        "INSERT OR IGNORE INTO space_members (space_id, user_id, joined_at) VALUES (?, ?, ?)",
        (space_id, target["id"], db.now()),
    )
    return {"ok": True, "user_id": target["id"], "username": target["username"]}


@router.delete("/{space_id}/members/{user_id}")
async def remove_member(space_id: int, user_id: int, user: dict = Depends(current_user)):
    """Удаление участника из пространства с ПОЛНЫМ блоком доступа к
    приложению: аккаунт банится (fingerprint в blacklist + banned=1),
    активные сессии завершаются."""
    space = db.query_one("SELECT * FROM spaces WHERE id = ?", (space_id,))
    if not space:
        raise HTTPException(status_code=404, detail="Пространство не найдено")
    _require_owner(space_id, user)
    if user_id == space["owner_id"]:
        raise HTTPException(status_code=403, detail="Нельзя удалить владельца пространства")
    if user_id == user["id"] and user["role"] != "SUPER_ADMIN":
        raise HTTPException(status_code=403, detail="Нельзя удалить самого себя")
    member = db.query_one(
        "SELECT id FROM space_members WHERE space_id = ? AND user_id = ?",
        (space_id, user_id),
    )
    if member:
        db.execute(
            "DELETE FROM space_members WHERE space_id = ? AND user_id = ?",
            (space_id, user_id),
        )
    target = db.query_one("SELECT id, device_fingerprint, banned FROM users WHERE id = ?", (user_id,))
    if target:
        fph = target["device_fingerprint"]
        db.execute(
            "INSERT OR IGNORE INTO server_blacklist (device_fingerprint, reason, banned_by, banned_at) VALUES (?, ?, ?, ?)",
            (fph, f"Удалён из пространства «{space['name']}»", user["id"], db.now()),
        )
        db.execute("UPDATE users SET banned = 1 WHERE id = ?", (user_id,))
        from app.ws_manager import message_bus
        await message_bus.terminate_user(user_id)
    return {"ok": True}


@router.post("/{space_id}/invites")
def create_invite(space_id: int, body: InviteCreate, user: dict = Depends(current_user)):
    space = db.query_one("SELECT * FROM spaces WHERE id = ?", (space_id,))
    if not space:
        raise HTTPException(status_code=404, detail="Пространство не найдено")
    _membership(space_id, user)

    if user["role"] != "SUPER_ADMIN":
        if space["owner_id"] != user["id"]:
            raise HTTPException(status_code=403, detail="Приглашать могут только владельцы пространства")
        if body.role in ("FAMILY_MEMBER", "SUPER_ADMIN"):
            raise HTTPException(status_code=403, detail="Вы не можете выдавать этот уровень доступа")

    role = body.role if body.role in db.ROLES else "STANDARD_USER"
    code = crypto.new_invite_code()
    expires_at = db.now() + settings.invite_ttl_hours * 3600
    db.execute(
        "INSERT INTO invites (code, space_id, created_by, role_granted, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)",
        (code, space_id, user["id"], role, db.now(), expires_at),
    )
    return {
        "code": code,
        "role": role,
        "space_id": space_id,
        "server": settings.server_domain,
        "expires_at": expires_at,
    }


## ---- «Общее» пространство ----
@router.get("/common")
def common_space(user: dict = Depends(current_user)):
    """Люди из всех пространств сервера с включённой видимостью
    (spaces.visible = 1). Пользователи из изолированных пространств не
    могут включить видимость и не видят чужих."""
    rows = db.query(
        """
        SELECT u.id, u.username, u.display_name, u.photo_path, u.role
        FROM users u
        JOIN space_members sm ON sm.user_id = u.id
        JOIN spaces s ON s.id = sm.space_id
        WHERE s.visible = 1 AND u.banned = 0
        """
    )
    seen = set()
    result = []
    for r in rows:
        if r["id"] in seen:
            continue
        seen.add(r["id"])
        result.append(r)
    return {"members": result}


class SpaceSettings(BaseModel):
    isolated: bool | None = None
    visible: bool | None = None


@router.put("/{space_id}/settings")
def set_space_settings(space_id: int, body: SpaceSettings, user: dict = Depends(current_user)):
    """- isolated (включает создатель): члены не создают свои пространства,
      не видят чужих, не могут включить видимость в Общем.
    - visible: показывать пространство в «Открытых пространствах».
      Меняет только владелец пространства (или SUPER_ADMIN)."""
    space = db.query_one("SELECT * FROM spaces WHERE id = ?", (space_id,))
    if not space:
        raise HTTPException(status_code=404, detail="Пространство не найдено")
    updated = False
    if body.isolated is not None:
        _require_owner(space_id, user)
        db.execute(
            "UPDATE spaces SET isolated = ? WHERE id = ?",
            (1 if body.isolated else 0, space_id),
        )
        updated = True
    if body.visible is not None:
        # Видимость меняет только владелец пространства (или SUPER_ADMIN).
        _require_owner(space_id, user)
        db.execute(
            "UPDATE spaces SET visible = ? WHERE id = ?",
            (1 if body.visible else 0, space_id),
        )
        updated = True
    if not updated:
        raise HTTPException(status_code=422, detail="Нет изменений")
    return db.query_one("SELECT * FROM spaces WHERE id = ?", (space_id,))


def _membership(space_id: int, user: dict) -> None:
    if user["role"] == "SUPER_ADMIN":
        return
    member = db.query_one(
        "SELECT id FROM space_members WHERE space_id = ? AND user_id = ?",
        (space_id, user["id"]),
    )
    if not member:
        raise HTTPException(status_code=403, detail="Вы не состоите в этом пространстве")
