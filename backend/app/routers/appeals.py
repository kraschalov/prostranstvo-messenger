from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app import crypto, db
from app.config import settings

router = APIRouter(prefix="/api", tags=["appeals"])


class AppealIn(BaseModel):
    device_fingerprint: str
    message: str


@router.post("/appeals")
def submit_appeal(body: AppealIn):
    fingerprint = body.device_fingerprint.strip()
    if not fingerprint:
        raise HTTPException(status_code=422, detail="Отсутствует идентификатор устройства")
    fph = crypto.device_fingerprint_hash(fingerprint)
    blacklisted = db.query_one(
        "SELECT id FROM server_blacklist WHERE device_fingerprint = ?", (fph,)
    )
    if not blacklisted:
        raise HTTPException(status_code=403, detail="Устройство не заблокировано")

    message = body.message.strip()
    if not (10 <= len(message) <= 2000):
        raise HTTPException(status_code=422, detail="Текст обращения: 10–2000 символов")

    last = db.query_one(
        "SELECT MAX(created_at) AS last FROM appeals WHERE device_fingerprint = ?", (fph,)
    )
    interval = settings.appeal_interval_days * 86400
    if last["last"] and (db.now() - last["last"]) < interval:
        raise HTTPException(
            status_code=429,
            detail=f"Новое обращение можно отправить не раньше чем через {settings.appeal_interval_days} дней",
        )

    db.execute(
        "INSERT INTO appeals (device_fingerprint, message, status, created_at) VALUES (?, ?, 'pending', ?)",
        (fph, message, db.now()),
    )
    return {"ok": True}
