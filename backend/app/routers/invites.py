import html
import secrets
from pathlib import Path
from urllib.parse import urlparse

from fastapi import APIRouter, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse

from app import db
from app.config import settings

router = APIRouter(prefix="/i", tags=["invites"])

APK_FILENAME = "app-release.apk"
INVITE_COOKIE = "__invite_tok"


def _lookup(code: str) -> dict | None:
    return db.query_one("SELECT * FROM invites WHERE code = ?", (code.strip().upper(),))


def _apk_path() -> Path:
    return Path(settings.uploads_dir) / APK_FILENAME


def _invite_state(invite: dict) -> tuple[str, str]:
    """Возвращает (status, message) для инвайта.

    Инвайт «использован навсегда» — только если активирован (used_at)
    или истёк срок. Сам факт скачивания APK (apk_consumed_at) НЕ делает
    ссылку мёртвой: владелец токена может доскачивать до expires_at,
    а другие устройства блокируются в download_apk.
    """
    expired = invite["expires_at"] is not None and db.now() > invite["expires_at"]
    if expired:
        return "expired", "Срок действия ссылки истёк"
    if invite["used_at"] is not None:
        return "used", "Приглашение уже использовано — доступ закрыт"
    return "ok", "ok"


def _page(title: str, body: str, *, refresh_to: str | None = None) -> str:
    auto = ""
    if refresh_to:
        auto = f'<meta http-equiv="refresh" content="0; url={html.escape(refresh_to, quote=True)}">'
    return f"""<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{auto}
<title>Пространство — приглашение</title>
<style>
  body {{ font-family: -apple-system, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #e2e8f0; display:flex; align-items:center; justify-content:center; min-height:100vh; margin:0; }}
  .card {{ background:#1e293b; border-radius:16px; padding:32px; max-width:420px; text-align:center; box-shadow:0 10px 40px rgba(0,0,0,.5); }}
  h1 {{ margin-top:0; font-size:22px; }}
  p {{ color:#94a3b8; line-height:1.6; }}
  .btn {{ display:inline-block; margin-top:12px; background:#3b82f6; color:#fff; padding:12px 20px; border-radius:8px; text-decoration:none; font-weight:600; }}
  .err {{ color:#f87171; font-weight:600; font-size:18px; }}
  .alert {{ margin-top:20px; background:#7f1d1d; border:2px solid #f87171; border-radius:12px; padding:16px; text-align:left; }}
  .alert b {{ color:#fca5a5; font-size:14px; }}
  .alert ol {{ margin:8px 0 0 18px; padding:0; color:#fecaca; line-height:1.7; font-size:13px; }}
</style>
</head>
<body>
<div class="card">
  {body}
</div>
</body>
</html>"""


@router.get("/{code}", response_class=HTMLResponse)
def invite_landing(code: str, request: Request):
    invite = _lookup(code)
    if not invite:
        return HTMLResponse(_page("Ссылка недоступна", '<h1 class="err">Ссылка не найдена</h1><p>Проверьте правильность ссылки или попросите новое приглашение.</p>'), status_code=404)
    state, msg = _invite_state(invite)
    if state != "ok":
        return HTMLResponse(_page("Приглашение недоступно", f'<h1 class="err">{html.escape(msg)}</h1><p>Попросите приглашение заново.</p>'), status_code=403 if state == "used" else 410)
    dl = f"/{router.prefix.strip('/')}/{html.escape(code, quote=True)}/download"
    # Deep link для установленного приложения: protoapp://join?code=X&server=HOST[:PORT]
    parsed = urlparse(str(request.base_url))
    server_host = parsed.netloc
    deeplink = f"protoapp://join?code={code}&server={server_host}"
    body = (
        f'<h1>Вы приглашены в «Пространство»</h1>'
        f'<p>Если приложение ещё не установлено — скачайте его по кнопке ниже.</p>'
        f'<a class="btn" style="background:#16a34a" href="{html.escape(dl, quote=True)}">Скачать приложение</a>'
        f'<div class="alert">'
        f'<b>⚠️ ВАЖНО! Особое внимание!</b>'
        f'<ol>'
        f'<li>Скачайте и установите приложение (кнопка выше).</li>'
        f'<li>Вернитесь на эту страницу и нажмите кнопку <b>«Первая авторизация»</b> (ниже).</li>'
        f'<li>Приложение откроется само — адрес сервера и код приглашения заполнятся автоматически.</li>'
        f'<li>Ничего вводить руками не нужно.</li>'
        f'</ol>'
        f'</div>'
        f'<a class="btn" style="background:#3b82f6; margin-top:20px" href="{html.escape(deeplink, quote=True)}">Первая авторизация</a>'
        f'<p style="font-size:12px; margin-top:16px">Если приложение уже установлено — нажимайте сразу кнопку «Первая авторизация».</p>'
    )
    return HTMLResponse(_page("Пространство — приглашение", body, refresh_to=dl))


@router.get("/{code}/download")
def download_apk(code: str, request: Request):
    invite = _lookup(code)
    if not invite:
        return JSONResponse({"error": "invite_not_found", "message": "Ссылка не найдена"}, status_code=404)
    state, msg = _invite_state(invite)
    if state != "ok":
        status = 403 if state == "used" else 410
        return JSONResponse({"error": f"invite_{state}", "message": msg}, status_code=status)
    apk = _apk_path()
    if not apk.exists():
        return JSONResponse({"error": "apk_missing", "message": "Приложение временно недоступно"}, status_code=503)

    consumed = invite["apk_consumed_at"]
    stored_token = invite["apk_token"] or ""
    client_token = request.cookies.get(INVITE_COOKIE) or ""

    def _apk_response() -> FileResponse:
        return FileResponse(
            str(apk),
            media_type="application/vnd.android.package-archive",
            filename=f"prostranstvo-{invite['code']}.apk",
        )

    # Fix: первое обращение Download Manager без cookie не должно банить.
    # Разрешаем скачивание любому устройству пока invite не использован (used_at is NULL).
    # Токен ставим только для докачки тем же устройством, но не блокируем новые.
    if consumed is None:
        token = secrets.token_urlsafe(24)
        db.execute(
            "UPDATE invites SET apk_consumed_at = ?, apk_token = ? WHERE id = ?",
            (db.now(), token, invite["id"]),
        )
        resp = _apk_response()
        resp.set_cookie(
            INVITE_COOKIE,
            token,
            max_age=settings.invite_ttl_hours * 3600,
            httponly=True,
        )
        return resp
    # Уже потреблен - разрешаем всем пока не used_at (регистрация не завершена)
    return _apk_response()


@router.get("/{code}/status")
def invite_status(code: str):
    invite = _lookup(code)
    if not invite:
        return JSONResponse({"error": "invite_not_found", "message": "Ссылка не найдена"}, status_code=404)
    state, msg = _invite_state(invite)
    return {"code": invite["code"], "state": state, "message": msg, "expires_at": invite["expires_at"]}