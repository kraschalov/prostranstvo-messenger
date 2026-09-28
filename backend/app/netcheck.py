"""Самодиагностика сети узла: белый/серый IP, NAT. Только stdlib.

Клиент (и владелец) узнаёт одной строкой, доступен ли сервер из интернета:
white_direct (белый на интерфейсе), white_behind_nat (белый за NAT —
нужен проброс порта), cgnat (серый, входящие невозможны — нужен туннель),
private_nat (за NAT без белого адреса).
Достижимость конкретного порта изнутри не проверить (hairpin врёт) —
доказательством служит успешное подключение клиента.
"""

import ipaddress
import os
import socket
import struct
import time

STUN_HOSTS = [
    ("stun.l.google.com", 19302),
    ("stun1.l.google.com", 19302),
]
STUN_TIMEOUT = 3.0

_cache: dict = {"at": 0.0, "result": None}
CACHE_TTL = 300.0


def _lan_ip() -> str:
    """IP физического интерфейса (не VPN-туннеля): STUN обязательно ходит
    через него, чтобы reflexive-адрес был домашним, а VPN-egress нигде
    не фигурировал."""
    import subprocess
    try:
        out = subprocess.run(
            ["ip", "-4", "-o", "addr", "show", "enp2s0"],
            capture_output=True, text=True, timeout=5,
        ).stdout
        m = __import__("re").search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
        if m:
            return m.group(1)
    except Exception:
        pass
    return ""


def _local_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except OSError:
        return ""
    finally:
        s.close()


def _stun_reflexive(host: str, port: int) -> str:
    txn = os.urandom(12)
    req = struct.pack("!HHI12s", 0x0001, 0, 0x2112A442, txn)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(STUN_TIMEOUT)
    try:
        lan = _lan_ip()
        if lan:
            s.bind((lan, 0))
        s.sendto(req, (host, port))
        data, _ = s.recvfrom(2048)
    except OSError:
        return ""
    finally:
        s.close()
    if len(data) < 20:
        return ""
    mtype, mlen, magic, rtxn = struct.unpack("!HHI12s", data[:20])
    if mtype != 0x0101 or magic != 0x2112A442 or rtxn != txn:
        return ""
    off = 20
    while off + 4 <= len(data):
        atype, alen = struct.unpack("!HH", data[off:off + 4])
        val = data[off + 4:off + 4 + alen]
        if atype == 0x0020 and len(val) >= 8 and val[1] == 0x01:
            xport = struct.unpack("!H", val[2:4])[0] ^ 0x2112
            xip = bytes(b ^ m for b, m in zip(val[4:8], struct.pack("!I", 0x2112A442)))
            return str(ipaddress.IPv4Address(xip))
        off += 4 + ((alen + 3) // 4) * 4
    return ""


def _verdict(local: str, reflexive: str) -> str:
    if not reflexive:
        return "stun_failed"
    if local and reflexive == local:
        return "white_direct"
    try:
        ip = ipaddress.ip_address(reflexive)
    except ValueError:
        return "stun_failed"
    if ip in ipaddress.ip_network("100.64.0.0/10"):
        return "cgnat"
    if ip.is_private:
        return "private_nat"
    return "white_behind_nat"


_ADVICE = {
    "white_direct": "Белый IP на интерфейсе. Открой порт в firewall — и сервер доступен.",
    "white_behind_nat": "Белый IP за NAT. Пробрось порт на роутере (и/или включи DDNS).",
    "cgnat": "Серый IP (CGNAT): входящие невозможны. Нужен туннель наружу (WireGuard до VPS / Cloudflare Tunnel). DDNS не поможет.",
    "private_nat": "За NAT без белого адреса. Нужен туннель наружу.",
    "stun_failed": "STUN не ответил (нет UDP наружу?). Проверь firewall.",
}


def check() -> dict:
    now = time.time()
    if _cache["result"] and now - _cache["at"] < CACHE_TTL:
        return _cache["result"]
    local = _local_ip()
    reflexive = ""
    for host, port in STUN_HOSTS:
        reflexive = _stun_reflexive(host, port)
        if reflexive:
            break
    verdict = _verdict(local, reflexive)
    result = {
        "local_ip": local,
        "public_ip": reflexive,
        "verdict": verdict,
        "advice": _ADVICE[verdict],
    }
    _cache.update(at=now, result=result)
    return result
