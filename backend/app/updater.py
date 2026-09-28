"""Подтяжка обновлений APK с GitHub Releases для раздачи своим клиентам.

Сервер — зеркало: хозяин решает, когда обновлять своих (стабильность),
клиенты ходят только на свой сервер и GitHub не касаются.
Проверка: GET api.github.com/repos/{repo}/releases/latest (нужен
User-Agent, иначе 403). Сборка парсится из тега (build-48 / v0.1.0+48).
Скачивание — стрим с лимитом размера, текущий APK бэкапится.
Без GITHUB_REPO в конфиге — всё выключено.
"""

import asyncio
import json
import logging
import re
import shutil
import urllib.error
import urllib.request
from pathlib import Path

from app.config import settings

log = logging.getLogger("node.updater")

MAX_APK_BYTES = 500 * 1024 * 1024
_last_check: dict = {}


def _api_get(url: str, timeout: int = 20) -> dict:
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "prostranstvo-messenger-updater",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _build_from_tag(tag: str) -> int:
    m = re.search(r"(\d+)\s*$", tag or "")
    return int(m.group(1)) if m else 0


def _update_json_path() -> Path:
    return Path(settings.uploads_dir).parent / "update.json"


def current_build() -> int:
    try:
        data = json.loads(_update_json_path().read_text(encoding="utf-8"))
        return int(data.get("build", 0))
    except Exception:
        return 0


def check() -> dict:
    """Сверить локальный build с последним релизом. Только чтение."""
    repo = settings.github_repo.strip()
    if not repo:
        return {"ok": False, "error": "GITHUB_REPO не задан"}
    try:
        rel = _api_get(f"https://api.github.com/repos/{repo}/releases/latest")
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"GitHub API: HTTP {e.code}"}
    except Exception as e:
        return {"ok": False, "error": f"GitHub недоступен: {e}"}
    apk_url = ""
    for a in rel.get("assets") or []:
        name = (a.get("name") or "").lower()
        if name.endswith(".apk") and a.get("browser_download_url"):
            apk_url = a["browser_download_url"]
            break
    latest = _build_from_tag(rel.get("tag_name", ""))
    cur = current_build()
    result = {
        "ok": True,
        "current_build": cur,
        "latest_build": latest,
        "latest_tag": rel.get("tag_name", ""),
        "apk_url": apk_url,
        "update_available": bool(apk_url) and latest > cur,
        "notes": (rel.get("body") or "")[:500],
    }
    _last_check.clear()
    _last_check.update(result)
    return result


def pull() -> dict:
    """Скачать APK релиза и выложить в раздачу (с бэкапом текущего)."""
    st = check()
    if not st.get("ok"):
        return st
    if not st.get("update_available"):
        return {"ok": True, "pulled": False, "reason": "уже актуально"}
    uploads = Path(settings.uploads_dir)
    uploads.mkdir(parents=True, exist_ok=True)
    tmp = uploads / "app-release.apk.download"
    try:
        req = urllib.request.Request(
            st["apk_url"],
            headers={"User-Agent": "prostranstvo-messenger-updater"},
        )
        with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "wb") as fh:
            shutil.copyfileobj(resp, fh, 1 << 20)
            if tmp.stat().st_size > MAX_APK_BYTES:
                tmp.unlink(missing_ok=True)
                return {"ok": False, "error": "APK больше лимита"}
    except Exception as e:
        tmp.unlink(missing_ok=True)
        return {"ok": False, "error": f"Скачивание: {e}"}
    cur_file = uploads / "app-release.apk"
    if cur_file.exists():
        bak = uploads / f"app-release-build{st['current_build']}.bak"
        shutil.copyfile(cur_file, bak)
    tmp.replace(cur_file)
    data = {
        "version": "0.1.0",
        "build": st["latest_build"],
        "apk": "/uploads/app-release.apk",
        "notes": st.get("notes", ""),
    }
    _update_json_path().write_text(
        json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    log.warning("UPDATE pulled: build %s (tag %s)", st["latest_build"], st["latest_tag"])
    return {"ok": True, "pulled": True, "build": st["latest_build"]}


async def _poll_loop() -> None:
    interval = max(1, settings.update_check_hours) * 3600
    while True:
        try:
            st = await asyncio.to_thread(check)
            if st.get("update_available"):
                log.warning(
                    "UPDATE AVAILABLE: %s (local %s)",
                    st.get("latest_tag"), st.get("current_build"),
                )
                if settings.auto_update_pull:
                    r = await asyncio.to_thread(pull)
                    log.warning("AUTO PULL: %s", r)
        except Exception as e:
            log.warning("update poll: %s", e)
        await asyncio.sleep(interval)


def start_background() -> None:
    if not settings.github_repo.strip() or not settings.update_check_enabled:
        return
    asyncio.get_running_loop().create_task(_poll_loop())
    log.info("update checker on: %s", settings.github_repo)
