import asyncio
import time

from starlette.websockets import WebSocket

from app import db
from app.config import settings


class MessageBus:
    def __init__(self, ttl_seconds: int) -> None:
        self._ttl = ttl_seconds
        self._clients: dict[int, set[WebSocket]] = {}
        self._pending: dict[int, dict[str, tuple[dict, float]]] = {}
        self._federation_forward = None

    def set_federation_forward(self, fn) -> None:
        self._federation_forward = fn

    @property
    def online_count(self) -> int:
        return sum(len(s) for s in self._clients.values())

    async def register(self, user_id: int, ws: WebSocket) -> None:
        self._clients.setdefault(user_id, set()).add(ws)

    async def drain(self, user_id: int) -> list:
        """Забрать накопленные события (HTTP-фолбэк, когда WS режут Dirk)."""
        import json as _json
        import time as _time
        rows = db.query(
            'SELECT msg_id, event_json, expires_at FROM pending_events WHERE user_id = ?',
            (user_id,),
        )
        now_ts = _time.time()
        out = []
        for r in rows:
            try:
                event = _json.loads(r['event_json'])
            except Exception:
                event = None
            db.execute(
                'DELETE FROM pending_events WHERE user_id = ? AND msg_id = ?',
                (user_id, r['msg_id']),
            )
            if not event or r['expires_at'] < now_ts:
                continue
            out.append(event)
        return out

    async def flush_for(self, user_id: int) -> None:
        """Доставка накопленных сообщений ТОЛЬКО по явному запросу клиента
        (sync_ready). Фоновая проверка соединений не «съедает» буфер."""
        import json as _json
        import logging as _l
        rows = db.query(
            'SELECT msg_id, event_json, expires_at FROM pending_events WHERE user_id = ?',
            (user_id,),
        )
        _l.warning("ROOMDBG flush_for uid=%s n=%s", user_id, len(rows))
        now_ts = time.time()
        for r in rows:
            try:
                event = _json.loads(r['event_json'])
            except Exception:
                event = None
            db.execute(
                'DELETE FROM pending_events WHERE user_id = ? AND msg_id = ?',
                (user_id, r['msg_id']),
            )
            if not event or r['expires_at'] < now_ts:
                continue
            await self._deliver(user_id, event)

    async def unregister(self, user_id: int, ws: WebSocket) -> None:
        socks = self._clients.get(user_id)
        if not socks:
            return
        socks.discard(ws)
        if not socks:
            self._clients.pop(user_id, None)

    async def terminate_user(self, user_id: int) -> None:
        for ws in list(self._clients.get(user_id, ())):
            try:
                await ws.send_json({"type": "banned"})
                await ws.close(code=4001, reason="BANNED")
            except Exception:
                pass
        self._clients.pop(user_id, None)

    async def _flush_pending(self, user_id: int) -> None:
        bucket = self._pending.pop(user_id, {})
        now_ts = time.time()
        for event, expires in bucket.values():
            if expires < now_ts:
                continue
            for ws in list(self._clients.get(user_id, ())):
                try:
                    await ws.send_json(event)
                except Exception:
                    pass

    async def _deliver(self, user_id: int, event: dict) -> None:
        for ws in list(self._clients.get(user_id, ())):
            try:
                await ws.send_json(event)
            except Exception:
                pass

    async def _route_user(self, user_id: int, event: dict, msg_id: str | None) -> None:
        if user_id in self._clients:
            await self._deliver(user_id, event)
            return
        if msg_id:
            # Ключи темы — долгоживущие (7 суток): участник заберёт,
            # когда появится, хоть через неделю. Чаты — обычный TTL.
            ttl = 7 * 86400 if event.get("type") in ("room_key", "room_key_request") else self._ttl
            ttl = 7 * 86400 if event.get("type") in ("room_key", "room_key_request") else self._ttl
            import json as _store_json
            sql = 'INSERT INTO pending_events (user_id, msg_id, event_json, expires_at) VALUES (?, ?, ?, ?) ON CONFLICT(user_id, msg_id) DO UPDATE SET event_json=excluded.event_json, expires_at=excluded.expires_at'
            try:
                db.execute(sql, (user_id, msg_id, _store_json.dumps(event, ensure_ascii=False), time.time() + ttl))
            except Exception:
                pass

    async def relay(self, sender_id: int, event: dict) -> None:
        import logging as _rl; _rl.warning("ROOMDBG in type=%s from=%s to=%s", event.get("type"), sender_id, event.get("to"))
        import logging as _l
        if event.get("type") in ("room_key", "room_key_request"):
            _l.warning("ROOMDBG type=%s from=%s to=%s",
                       event.get("type"), sender_id, event.get("to"))
        msg_id = event.get("msg_id")
        targets = event.get("to") or []
        for target in targets:
            kind, _, rest = target.partition(":")
            if kind == "user":
                await self._route_user(int(rest), event, msg_id)
            elif kind == "space":
                members = db.query(
                    "SELECT user_id FROM space_members WHERE space_id = ?", (int(rest),)
                )
                for m in members:
                    if m["user_id"] != sender_id:
                        await self._route_user(m["user_id"], event, msg_id)
            elif kind == "topic":
                try:
                    tid = int(rest)
                except ValueError:
                    continue
                mem = db.query_one(
                    "SELECT can_post FROM topic_members WHERE topic_id = ? AND user_id = ?",
                    (tid, sender_id),
                )
                if not mem or not mem["can_post"]:
                    # Хозяин сервера — полный контроль, пишет везде.
                    role = db.query_one(
                        "SELECT role FROM users WHERE id = ?", (sender_id,)
                    )
                    if not role or role["role"] != "SUPER_ADMIN":
                        continue
                members = db.query(
                    "SELECT user_id FROM topic_members WHERE topic_id = ?", (tid,)
                )
                for m in members:
                    if m["user_id"] != sender_id:
                        await self._route_user(m["user_id"], event, msg_id)
            elif kind == "remote":
                domain, _, uid = rest.partition(":")
                fwd = dict(event)
                fwd["to"] = [f"user:{uid}"]
                if domain == settings.server_domain or not self._federation_forward:
                    await self._route_user(int(uid), fwd, msg_id)
                else:
                    await self._federation_forward(domain, fwd)
            elif kind == "server" and self._federation_forward:
                await self._federation_forward(rest, event)

    async def schedule(self, sender_id: int, event: dict) -> None:
        at = float(event.get("at") or 0)
        delay = at - time.time()
        if delay <= 0:
            await self.relay(sender_id, event)
            return

        async def _fire():
            await asyncio.sleep(delay)
            await self.relay(sender_id, event)

        asyncio.get_event_loop().create_task(_fire())


message_bus = MessageBus(settings.message_ttl_seconds)
