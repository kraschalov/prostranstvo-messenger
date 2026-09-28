"""Каталог серверов: сервер сам тянет servers.json с GitHub по HTTPS
и раздаёт клиентам из кэша. Клиенты на GitHub не ходят — их адреса
GitHub не видит. Обновление ленивое: при запросе старее N часов.
"""
import json
import logging
import time
import urllib.request
from pathlib import Path

from app.config import settings

log = logging.getLogger("node.directory")


def _cache_path() -> Path:
    return Path(settings.uploads_dir).parent / "servers-cache.json"


def get() -> dict:
    url = settings.servers_catalog_url
    if not url:
        return {"ok": False, "error": "каталог не настроен", "servers": []}
    cp = _cache_path()
    ttl = max(1, settings.servers_catalog_hours) * 3600
    if cp.exists() and time.time() - cp.stat().st_mtime < ttl:
        try:
            data = json.loads(cp.read_text(encoding="utf-8"))
            return {"ok": True, "servers": data.get("servers", []), "cached": True}
        except Exception:
            pass
    try:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "prostranstvo-messenger-directory",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=20) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        servers = data.get("servers", []) if isinstance(data, dict) else []
        cp.write_text(
            json.dumps({"servers": servers}, ensure_ascii=False),
            encoding="utf-8",
        )
        return {"ok": True, "servers": servers, "cached": False}
    except Exception as e:
        log.warning("directory fetch: %s", e)
        if cp.exists():
            try:
                data = json.loads(cp.read_text(encoding="utf-8"))
                return {
                    "ok": True,
                    "servers": data.get("servers", []),
                    "cached": True,
                    "stale": True,
                }
            except Exception:
                pass
        return {"ok": False, "error": f"каталог недоступен: {e}", "servers": []}
