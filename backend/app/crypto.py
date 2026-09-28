import hashlib
import hmac
import secrets
import string

INVITE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def sha256_hex(data: str) -> str:
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def sha256_b64(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def device_fingerprint_hash(fingerprint: str) -> str:
    return sha256_hex("dfp::" + fingerprint.strip())


def session_token_hash(token: str) -> str:
    return sha256_hex("sess::" + token)


def new_token() -> str:
    return secrets.token_urlsafe(32)


def new_invite_code() -> str:
    groups = []
    for _ in range(4):
        groups.append("".join(secrets.choice(INVITE_ALPHABET) for _ in range(4)))
    return "-".join(groups)


def hmac_sign(secret: str, message: str) -> str:
    return hmac.new(secret.encode("utf-8"), message.encode("utf-8"), hashlib.sha256).hexdigest()


def hmac_verify(secret: str, message: str, signature: str) -> bool:
    expected = hmac_sign(secret, message)
    return hmac.compare_digest(expected, signature or "")
