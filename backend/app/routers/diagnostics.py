import hashlib
import json
import time
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import db
from app import netcheck
from app.config import settings
from app.deps import current_user

router = APIRouter(prefix="/api/diag", tags=["diagnostics"])


class LogsIn(BaseModel):
    device: str = ""
    version: str = ""
    logs: str = ""
    comment: str = ""


@router.post("/logs")
def upload_logs(body: LogsIn, user: dict = Depends(current_user)):
    """Приём диагностических логов с клиента (тестовый режим).
    Сохраняет в data/diag/<user_id>_<ts>.log. НЕ содержит сообщений чатов —
    только служебный лог приложения (звонки, ошибки, версия)."""
    if not body.logs.strip():
        raise HTTPException(status_code=422, detail="Пустой лог")
    diag_dir = Path(settings.uploads_dir).parent / "diag"
    diag_dir.mkdir(parents=True, exist_ok=True)
    fname = f"u{user['id']}_{int(time.time())}_{body.device[:8]}.log"
    comment_block = (
        f"# comment:\n{body.comment}\n# /comment\n"
        if body.comment.strip()
        else ""
    )
    (diag_dir / fname).write_text(
        f"# device={body.device}\n# version={body.version}\n# user={user['username']}\n"
        f"# ts={time.time()}\n{comment_block}{body.logs}\n",
        encoding="utf-8",
    )
    return {"ok": True, "saved": fname}


_apk_hash_cache: dict = {}


def _apk_sha256(apk_rel: str) -> str:
    """SHA-256 файла APK из uploads (для сверки клиентом до установки).
    Кэш по (имя, размер, mtime) — файл 110МБ, хешировать каждый раз дорого."""
    name = apk_rel.strip("/").split("/")[-1]
    if not name or ".." in name:
        return ""
    f = Path(settings.uploads_dir) / name
    try:
        st = f.stat()
    except OSError:
        return ""
    key = (name, st.st_size, st.st_mtime)
    hit = _apk_hash_cache.get("key")
    if hit and hit[0] == key:
        return hit[1]
    h = hashlib.sha256()
    with open(f, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    digest = h.hexdigest()
    _apk_hash_cache.clear()
    _apk_hash_cache["key"] = (key, digest)
    return digest


@router.get("/update")
def check_update():
    """Информация о доступном обновлении APK. Файл update.json в data/:
    {"version": "0.1.0", "build": 2, "apk": "/uploads/app-release.apk", "notes": "..."}.
    Если файла нет — обновлений нет."""
    upd = Path(settings.uploads_dir).parent / "update.json"
    if not upd.exists():
        return {"update": False}
    try:
        data = json.loads(upd.read_text(encoding="utf-8"))
        apk_rel = data.get("apk", "")
        return {
            "update": True,
            "version": data.get("version", ""),
            "build": data.get("build", 0),
            "apk": apk_rel,
            "notes": data.get("notes", ""),
            "sha256": _apk_sha256(apk_rel),
        }
    except Exception:
        return {"update": False}


@router.get("/netcheck")
def netcheck_info(user: dict = Depends(current_user)):
    """Самодиагностика сети: белый/серый IP, NAT. Только для залогиненных
    (адрес узла — не публичные данные)."""
    return netcheck.check()
