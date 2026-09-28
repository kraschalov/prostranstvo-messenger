import asyncio
import json
import time
import urllib.error
import urllib.request

from app import crypto, db
from app.config import settings

TS_WINDOW_SECONDS = 300


class S2SClient:
    def __init__(self, domain: str, timeout: int) -> None:
        self.domain = domain
        self.timeout = timeout

    @staticmethod
    def _message_for(path: str, ts: str, nonce: str, digest: str) -> str:
        return f"POST|{path}|{ts}|{nonce}|{digest}"

    def _signed_headers(self, peer: dict, path: str, body: bytes) -> dict:
        ts = str(int(time.time()))
        nonce = crypto.new_token()[:16]
        digest = crypto.sha256_b64(body)
        sig = crypto.hmac_sign(peer["shared_secret"], self._message_for(path, ts, nonce, digest))
        return {
            "X-S2S-Domain": self.domain,
            "X-S2S-Timestamp": ts,
            "X-S2S-Nonce": nonce,
            "X-S2S-Signature": sig,
            "Content-Type": "application/json",
        }

    def _post(self, peer: dict, path: str, payload: dict) -> dict:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            f"https://{peer['domain']}{path}",
            data=body,
            headers=self._signed_headers(peer, path, body),
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = resp.read().decode("utf-8")
                return {"ok": True, "status": resp.status, "body": json.loads(data)}
        except urllib.error.HTTPError as e:
            return {"ok": False, "status": e.code, "body": {}}
        except Exception as e:
            return {"ok": False, "status": 0, "body": {}, "error": str(e)}

    def _active_peers(self) -> list[dict]:
        return db.query(
            "SELECT * FROM server_registry WHERE active = 1 ORDER BY linked_at ASC"
        )

    async def relay(self, peer: dict, event: dict) -> dict:
        return await asyncio.to_thread(self._post, peer, "/s2s/relay", event)

    async def lookup(self, peer: dict, username: str, origin_domain: str) -> dict:
        return await asyncio.to_thread(
            self._post, peer, "/s2s/lookup", {"username": username, "origin_domain": origin_domain}
        )

    async def dating_search(self, peer: dict, filters: dict, origin_domain: str) -> dict:
        return await asyncio.to_thread(
            self._post,
            peer,
            "/s2s/dating_search",
            {"filters": filters, "origin_domain": origin_domain},
        )

    async def ban_notify(self, peer: dict, fingerprint_hash: str) -> dict:
        return await asyncio.to_thread(
            self._post, peer, "/s2s/ban_notify", {"device_fingerprint": fingerprint_hash}
        )

    async def link(self, peer_domain: str, name: str) -> tuple[bool, str]:
        peer = db.query_one("SELECT * FROM server_registry WHERE domain = ?", (peer_domain,))
        secret = peer["shared_secret"] if peer else crypto.new_token()
        payload = {"domain": self.domain, "name": name, "secret": secret}
        result = await asyncio.to_thread(
            self._post_raw, peer_domain, "/s2s/link_request", payload
        )
        if not result["ok"]:
            return False, result.get("error") or f"HTTP {result['status']}"
        db.execute(
            """
            INSERT INTO server_registry (domain, name, shared_secret, linked_at, active)
            VALUES (?, ?, ?, ?, 1)
            ON CONFLICT(domain) DO UPDATE SET
              name = excluded.name,
              shared_secret = excluded.shared_secret,
              linked_at = excluded.linked_at,
              active = 1
            """,
            (peer_domain, name, secret, time.time()),
        )
        return True, "linked"

    def _post_raw(self, peer_domain: str, path: str, payload: dict) -> dict:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            f"https://{peer_domain}{path}",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                data = resp.read().decode("utf-8")
                return {"ok": True, "status": resp.status, "body": json.loads(data)}
        except urllib.error.HTTPError as e:
            return {"ok": False, "status": e.code, "body": {}}
        except Exception as e:
            return {"ok": False, "status": 0, "body": {}, "error": str(e)}


def verify_s2s_request(peer_domain: str, path: str, headers: dict, body: bytes) -> bool:
    peer = db.query_one(
        "SELECT * FROM server_registry WHERE domain = ? AND active = 1", (peer_domain,)
    )
    if not peer:
        return False
    try:
        ts = int(headers.get("x-s2s-timestamp", "0"))
    except ValueError:
        return False
    if abs(time.time() - ts) > TS_WINDOW_SECONDS:
        return False
    nonce = headers.get("x-s2s-nonce", "")
    digest = crypto.sha256_b64(body)
    signature = headers.get("x-s2s-signature", "")
    message = S2SClient._message_for(path, str(ts), nonce, digest)
    return crypto.hmac_verify(peer["shared_secret"], message, signature)


s2s_client = S2SClient(settings.server_domain, settings.s2s_timeout_seconds)
