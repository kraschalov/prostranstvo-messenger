import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, UploadFile

from app import db
from app.config import settings
from app.deps import current_user

router = APIRouter(prefix="/api/upload", tags=["upload"])

ALLOWED_EXT = {".jpg", ".jpeg", ".png", ".webp", ".gif"}
MAX_SIZE = 8 * 1024 * 1024  # 8 MB

# Вложения в чаты: любой тип файла, до 50 МБ.
CHAT_MAX_SIZE = 50 * 1024 * 1024  # 50 MB


def _save_image(upload: UploadFile, field: str, user: dict) -> dict:
    ext = Path(upload.filename or "").suffix.lower()
    if ext not in ALLOWED_EXT:
        raise HTTPException(status_code=422, detail="Формат не поддерживается (jpg/png/webp/gif)")
    data = upload.file.read()
    if len(data) > MAX_SIZE:
        raise HTTPException(status_code=422, detail="Файл больше 8 МБ")
    upload_dir = Path(settings.uploads_dir)
    upload_dir.mkdir(parents=True, exist_ok=True)
    name = f"u{user['id']}_{field}_{uuid.uuid4().hex[:12]}{ext}"
    (upload_dir / name).write_bytes(data)
    url = f"{settings.public_base_url}/uploads/{name}"
    return {"path": f"/uploads/{name}", "url": url}


@router.post("/chat")
def upload_chat_file(file: UploadFile, user: dict = Depends(current_user)):
    """Загрузка вложения для сообщения чата. Любой тип файла до 50 МБ.
    Возвращает метаданные для отправки в зашифрованном конверте сообщения."""
    if not file.filename or not file.filename.strip():
        raise HTTPException(status_code=422, detail="Пустое имя файла")
    upload_dir = Path(settings.uploads_dir)
    upload_dir.mkdir(parents=True, exist_ok=True)
    # Читаем с ограничением размера.
    data = file.file.read(CHAT_MAX_SIZE + 1)
    if len(data) > CHAT_MAX_SIZE:
        raise HTTPException(status_code=413, detail="Файл больше 50 МБ")
    name = f"m{user['id']}_{uuid.uuid4().hex[:16]}_{file.filename.replace(' ', '_')}"
    (upload_dir / name).write_bytes(data)
    from mimetypes import guess_type
    mime = guess_type(file.filename)[0] or "application/octet-stream"
    return {
        "file_id": name,
        "name": file.filename,
        "size": len(data),
        "mime": mime,
        "url": f"{settings.public_base_url}/uploads/{name}",
    }


@router.post("/avatar")
def upload_avatar(file: UploadFile, user: dict = Depends(current_user)):
    result = _save_image(file, "avatar", user)
    db.execute("UPDATE users SET photo_path = ? WHERE id = ?", (result["path"], user["id"]))
    return {"ok": True, "photo_path": result["path"], "url": result["url"]}


@router.post("/cover")
def upload_cover(file: UploadFile, user: dict = Depends(current_user)):
    result = _save_image(file, "cover", user)
    db.execute("UPDATE users SET cover_path = ? WHERE id = ?", (result["path"], user["id"]))
    return {"ok": True, "cover_path": result["path"], "url": result["url"]}
