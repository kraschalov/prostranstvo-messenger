from datetime import date

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import db
from app.config import settings
from app.deps import current_user

router = APIRouter(prefix="/api/profile", tags=["profile"])

VALID_GENDERS = {"male", "female", "other", "unknown"}


class ProfileUpdate(BaseModel):
    username: str | None = None
    display_name: str | None = None
    gender: str | None = None
    birth_date: str | None = None
    age: int | None = None
    city: str | None = None
    goal: str | None = None
    interests: list[str] | None = None
    bio: str | None = None
    photo_path: str | None = None
    cover_path: str | None = None
    public_key: str | None = None
    dating_switch: bool | None = None
    federated_search: bool | None = None
    cross_server_messages: bool | None = None


def _compute_age(birth_date: str) -> int:
    try:
        d = date.fromisoformat(birth_date)
        today = date.today()
        return today.year - d.year - ((today.month, today.day) < (d.month, d.day))
    except ValueError:
        return 0


def _private(profile: dict, user: dict) -> dict:
    profile.update(
        {
            "dating_switch": bool(user["dating_switch"]),
            "federated_search": bool(user["federated_search"]),
            "cross_server_messages": bool(user["cross_server_messages"]),
        }
    )
    return profile


@router.get("/me")
def get_me(user: dict = Depends(current_user)):
    return _private(db.public_profile(user, settings.server_domain), user)


@router.get("/{user_id}")
def get_profile_by_id(user_id: int, user: dict = Depends(current_user)):
    target = db.query_one("SELECT * FROM users WHERE id = ?", (user_id,))
    if not target:
        raise HTTPException(status_code=404, detail="Пользователь не найден")
    return db.public_profile(target, settings.server_domain)


@router.put("/me")
def update_me(body: ProfileUpdate, user: dict = Depends(current_user)):
    fields = {}
    if body.username is not None:
        username = body.username.strip().lstrip("@")
        if not (3 <= len(username) <= 32) or not all(c.isalnum() or c in "_.-" for c in username):
            raise HTTPException(status_code=422, detail="Ник: 3–32 символа, латиница/цифры/_.-")
        clash = db.query_one("SELECT id FROM users WHERE username = ? AND id != ?", (username, user["id"]))
        if clash:
            raise HTTPException(status_code=409, detail="Этот ник уже занят")
        fields["username"] = username
    if body.display_name is not None:
        fields["display_name"] = body.display_name.strip()[:64]
    if body.gender is not None:
        if body.gender not in VALID_GENDERS:
            raise HTTPException(status_code=422, detail="Недопустимый пол")
        fields["gender"] = body.gender
    if body.birth_date is not None and body.birth_date.strip():
        if not _compute_age(body.birth_date):
            raise HTTPException(status_code=422, detail="Некорректная дата рождения")
        fields["birth_date"] = body.birth_date
        fields["age"] = _compute_age(body.birth_date)
    if body.age is not None:
        if not 14 <= body.age <= 120:
            raise HTTPException(status_code=422, detail="Некорректный возраст")
        fields["age"] = body.age
    if body.city is not None:
        fields["city"] = body.city.strip()[:64]
    if body.goal is not None:
        fields["goal"] = body.goal.strip()[:64]
    if body.interests is not None:
        tags = [t.strip() for t in body.interests if t.strip()][:20]
        fields["interests"] = ",".join(tags)
    if body.bio is not None:
        fields["bio"] = body.bio.strip()[:512]
    if body.photo_path is not None:
        fields["photo_path"] = body.photo_path.strip()[:255]
    if body.cover_path is not None:
        fields["cover_path"] = body.cover_path.strip()[:255]
    if body.public_key is not None:
        if len(body.public_key.strip()) > 2048:
            raise HTTPException(status_code=422, detail="Некорректный ключ шифрования")
        fields["public_key"] = body.public_key.strip()
    if body.dating_switch is not None:
        fields["dating_switch"] = 1 if body.dating_switch else 0
    if body.federated_search is not None:
        fields["federated_search"] = 1 if body.federated_search else 0
    if body.cross_server_messages is not None:
        fields["cross_server_messages"] = 1 if body.cross_server_messages else 0

    if not fields:
        raise HTTPException(status_code=422, detail="Нет полей для обновления")

    sets = ", ".join(f"{k} = ?" for k in fields)
    db.execute(f"UPDATE users SET {sets} WHERE id = ?", (*fields.values(), user["id"]))
    updated = db.query_one("SELECT * FROM users WHERE id = ?", (user["id"],))
    return _private(db.public_profile(updated, settings.server_domain), updated)
