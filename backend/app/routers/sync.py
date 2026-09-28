"""HTTP-фолбэк реального времени для сетей, режущих WebSocket.

Пока оператор/маршрутизатор душит Upgrade/long-lived соединения,
клиент ходит сюда обычной HTTP-периодикой:
- POST /api/sync/pull — забрать накопленное (ключи, сообщения);
- POST /api/sync/send — отправить событие (ключи, сообщения, запросы).
Та же валидация, что у WS: белый список типов, проверка целей,
подстановка sender. Очередь переживает рестарты, ключи живут 7 суток.
"""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import db
from app.config import settings  # noqa: F401 (единообразие конфига)
from app.deps import current_user
from app.ws_manager import message_bus

router = APIRouter(prefix="/api/sync", tags=["sync"])

ALLOWED = {
    "message",
    "edit",
    "delete",
    "typing",
    "call_offer",
    "call_answer",
    "call_ice",
    "call_hangup",
    "delivered",
    "read",
    "room_key",
    "room_key_request",
}


class SendIn(BaseModel):
    event: dict


@router.post("/pull")
async def pull(user: dict = Depends(current_user)):
    events = await message_bus.drain(user["id"])
    return {"events": events}


@router.post("/send")
async def send(body: SendIn, user: dict = Depends(current_user)):
    from app.main import _validated_targets

    event = dict(body.event or {})
    etype = event.get("type")
    if etype not in ALLOWED:
        raise HTTPException(status_code=422, detail="Тип события запрещён")
    event["to"] = _validated_targets(user, event.get("to") or [])
    event["sender"] = {"id": user["id"], "username": user["username"]}
    await message_bus.relay(user["id"], event)
    return {"ok": True}


@router.get("/pending_count")
async def pending_count(user: dict = Depends(current_user)):
    row = db.query_one(
        "SELECT COUNT(*) AS c FROM pending_events WHERE user_id = ?",
        (user["id"],),
    )
    return {"pending": (row["c"] if row else 0)}
