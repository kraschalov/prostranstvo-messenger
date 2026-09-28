import asyncio
import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from starlette.websockets import WebSocketState

from app import crypto, db
from app.config import settings
from app.federation import s2s_client
from app.routers import admin, appeals, auth, diagnostics, invites, profile, s2s, search, servers, spaces, sync, topics, upload
from app.ws_manager import message_bus

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger("node")


def _bootstrap_admin() -> None:
    code = settings.admin_bootstrap_code.strip().upper()
    if not code:
        return
    if db.query_one("SELECT id FROM users WHERE role = 'SUPER_ADMIN' LIMIT 1"):
        return
    if db.query_one("SELECT id FROM invites WHERE code = ?", (code,)):
        return
    db.execute(
        "INSERT INTO invites (code, space_id, created_by, role_granted, created_at) VALUES (?, NULL, NULL, 'SUPER_ADMIN', ?)",
        (code, db.now()),
    )
    logger.info("Создан код первого входа для SUPER_ADMIN: %s", code)


async def _federation_forward(domain: str, event: dict) -> None:
    peer = db.query_one(
        "SELECT * FROM server_registry WHERE lower(domain) = lower(?) AND active = 1", (domain,)
    )
    if not peer:
        logger.warning("Попытка пересылки на несвязанный сервер: %s", domain)
        return
    await s2s_client.relay(peer, {"event": event})


@asynccontextmanager
async def lifespan(app: FastAPI):
    db.init_db()
    _bootstrap_admin()
    message_bus.set_federation_forward(_federation_forward)
    # Директория загрузок для статической раздачи файлов (аватары, обложки).
    from pathlib import Path

    Path(settings.uploads_dir).mkdir(parents=True, exist_ok=True)
    app.mount("/uploads", StaticFiles(directory=settings.uploads_dir), name="uploads")
    from app import updater as _updater

    _updater.start_background()
    logger.info("Нода %s запущена на порту %s", settings.server_domain, settings.port)
    yield


app = FastAPI(
    title="Passenger Life — федеративный мессенджер",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def _dbg_update_host(request, call_next):
    if request.url.path == "/api/diag/update":
        logger.warning(
            "DBGUPDATE host=%s client=%s",
            request.headers.get("host"),
            request.client.host if request.client else "?",
        )
    return await call_next(request)

app.include_router(auth.router)
app.include_router(profile.router)
app.include_router(search.router)
app.include_router(spaces.router)
app.include_router(admin.router)
app.include_router(appeals.router)
app.include_router(s2s.router)
app.include_router(upload.router)
app.include_router(topics.router)
app.include_router(sync.router)
app.include_router(servers.router)
app.include_router(diagnostics.router)
app.include_router(invites.router)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "domain": settings.server_domain,
        "online": message_bus.online_count,
        "ts": time.time(),
    }


@app.get("/api/server_info")
def server_info():
    """Публичная информация для клиентов: режим федерации, TURN
    (вместо хардкода в APK), URL манифеста обновлений."""
    return {
        "domain": settings.server_domain,
        "name": settings.server_name,
        "city": settings.server_city,
        "country": settings.server_country,
        "federation_mode": settings.federation_mode,
        "turn": {
            "enabled": settings.turn_enabled,
            "host": settings.turn_host,
            "port": settings.turn_port,
            "user": settings.turn_user,
            "pass": settings.turn_pass,
        },
        "update_manifest_url": settings.update_manifest_url,
        "public_base_url": settings.public_base_url,
    }


def _authenticate_ws(token: str, fingerprint: str) -> dict | None:
    if not token or not fingerprint:
        return None
    session = db.query_one(
        "SELECT * FROM sessions WHERE token_hash = ?",
        (crypto.session_token_hash(token),),
    )
    if not session or session["expires_at"] < db.now():
        return None
    user = db.query_one("SELECT * FROM users WHERE id = ?", (session["user_id"],))
    if not user or user["device_fingerprint"] != crypto.device_fingerprint_hash(fingerprint):
        return None
    return user


def _validated_targets(sender: dict, targets: list) -> list:
    result = []
    for target in targets:
        if not isinstance(target, str):
            continue
        kind, _, rest = target.partition(":")
        if kind == "user" and rest.isdigit():
            result.append(target)
        elif kind == "space" and rest.isdigit():
            member = db.query_one(
                "SELECT id FROM space_members WHERE space_id = ? AND user_id = ?",
                (int(rest), sender["id"]),
            )
            if member:
                result.append(target)
        elif kind == "remote":
            domain, _, uid = rest.partition(":")
            if domain and uid.isdigit():
                result.append(target)
        elif kind == "topic" and rest.isdigit():
            member = db.query_one(
                "SELECT user_id FROM topic_members WHERE topic_id = ? AND user_id = ?",
                (int(rest), sender["id"]),
            )
            if member:
                result.append(target)
        elif kind == "server" and rest:
            result.append(target)
    return result


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    token = websocket.query_params.get("token", "")
    fingerprint = websocket.query_params.get("device", "")
    user = _authenticate_ws(token, fingerprint)
    if not user:
        await websocket.close(code=4003, reason="UNAUTHORIZED")
        return
    if user["banned"] or db.is_blacklisted(fingerprint):
        await websocket.close(code=4001, reason="BANNED")
        return

    await websocket.accept()
    await message_bus.register(user["id"], websocket)
    logger.warning("WSDBG connect uid=%s", user["id"])
    db.touch_last_seen(user["id"])
    logger.info("Подключение: @%s (%s)", user["username"], settings.server_domain)
    try:
        while True:
            event = await websocket.receive_json()
            if not isinstance(event, dict) or "type" not in event:
                continue

            if user["banned"] or db.is_blacklisted(fingerprint):
                await websocket.send_json({"type": "banned"})
                await websocket.close(code=4001, reason="BANNED")
                break

            etype = event["type"]
            if etype in (
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
            ):
                event["to"] = _validated_targets(user, event.get("to") or [])
                event["sender"] = {"id": user["id"], "username": user["username"]}
                await message_bus.relay(user["id"], event)
                if etype in ("message", "call_offer", "call_answer", "call_hangup"):
                    logger.info("Релей %s от @%s id=%s -> %s", etype, user["username"], event.get("msg_id"), event.get("to"))
                elif etype == "call_ice":
                    cand = event.get("candidate") or {}
                    logger.info("Релей call_ice от @%s cand=%s -> %s", user["username"], str(cand)[:120], event.get("to"))
                elif etype in ("delivered", "read"):
                    logger.info("Релей %s от @%s id=%s -> %s", etype, user["username"], event.get("msg_id"), event.get("to"))
            elif etype == "schedule":
                event["sender"] = {"id": user["id"], "username": user["username"]}
                await message_bus.schedule(user["id"], event)
            elif etype == "ping":
                # Активное WS-соединение = «онлайн»: обновляем last_seen на
                # каждый ping, иначе статус гаснет через 120с даже при
                # открытом приложении (last_seen трогался только при
                # подключении/запросах).
                db.touch_last_seen(user["id"])
                await websocket.send_json({"type": "pong"})
            elif etype == "sync_ready":
                await message_bus.flush_for(user["id"])
            else:
                logger.debug("Неизвестный тип события от %s: %s", user["username"], etype)
    except WebSocketDisconnect:
        pass
    except Exception as exc:
        logger.debug("Ошибка WS-сессии %s: %s", user["username"], exc)
    finally:
        await message_bus.unregister(user["id"], websocket)
        logger.warning("WSDBG disconnect uid=%s", user["id"])
        if websocket.client_state != WebSocketState.DISCONNECTED:
            try:
                await websocket.close(code=1000)
            except Exception:
                pass
