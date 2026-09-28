# Пространство — федеративный мессенджер

Свободный (AGPL-3.0) мессенджер: сквозное шифрование личек, групповые
комнаты-«Темы» с общим ключом, звонки (WebRTC + TURN), пространства,
федерация серверов, обновления через GitHub Releases.

## Состав

- `backend/` — Python-сервер (FastAPI + WebSocket + SQLite, только stdlib+5 зависимостей)
- `mobile/` — Flutter-клиент (Android; Windows — community-supported)
- `servers.json` — публичный каталог серверов (добавление через пулл-реквест)
- `update.json` — манифест обновлений (схема; живые сборки — в GitHub Releases)

## Быстрый старт: свой сервер за 15 минут (Ubuntu)

```bash
python3 --version  # нужен 3.10+
cd backend
pip install -r requirements.txt
cp .env.example .env
nano .env            # HOST, PORT, SERVER_DOMAIN, SERVER_NAME, ADMIN_BOOTSTRAP_CODE
python3 run.py
```

Открой `http://твой-ip:5050/health` — `{"status":"ok",...}` значит живо.
Первый вход в приложение с кодом `ADMIN_BOOTSTRAP_CODE` сделает тебя владельцем.
Строку с кодом из `.env` после этого удали.

### Порты и сеть

- Нужен доступный снаружи порт (по умолчанию 5050) + проброс на роутере.
- `GET /api/diag/netcheck` (из приложения или curl с токеном) сам скажет:
  белый IP / белый за NAT / серый CGNAT — и что делать.
- Серый IP (CGNAT) — только туннель наружу (WireGuard до VPS / Cloudflare Tunnel).
- Динамический белый IP — подойдёт с DDNS; в каталог и клиент пиши домен, не IP.

### TURN для звонков (необязательно)

Без TURN работают прямые и STUN-звонки. Для сложных NAT подними coturn
(`deploy/coturn/` + `docker-compose.yml` как пример) и впиши в `.env`:

```ini
TURN_ENABLED=1
TURN_HOST=твой-хост
TURN_PORT=3478
TURN_USER=логин
TURN_PASS=пароль
```

Клиент забирает параметры сам через `/api/server_info` — в код они не вшиты.

## Windows-сервер (community-supported)

```bat
py -3.12 -m venv venv
venv\Scripts\activate
pip install -r requirements-windows.txt
copy .env.example .env
notepad .env
python run.py
```

Порт открой в firewall. `uvicorn[standard]` под Windows не ставится —
используется голый `uvicorn` (разницы для энтузиаста нет).
TURN под Windows нет — `TURN_ENABLED=0`, звонки напрямую/STUN.
Чеклист самопроверки: `/health`, `/api/diag/update`, регистрация по инвайту,
чат, звонок.

## Клиент (Android)

```bash
cd mobile
flutter pub get
flutter build apk --release   # debug: flutter run
```

Своя подпись: положи свой keystore (см. `android/keystore.properties.example`),
**релизный ключ проекта никогда не публикуется**.
Обновления прилетают из `update.json` твоего сервера (каждый сервер —
зеркало: скачай asset из GitHub Releases в `backend/data/uploads/`).

## Федерация

- Режимы сервера (`FEDERATION_MODE`): `closed` (дефолт) / `allowlist` (спаривание
  вручную) / `open` (спаривание по запросу). Переключается из приложения
  на лету, без рестарта.
- Каталог `servers.json`: запись = `{alias, host, federation, contact}`.
  Хочешь в каталог — пулл-реквест. Нет записи — сервер закрыт по умолчанию.
  Клиент показывает алиасы, не IP.

## Безопасность

- Лички: E2EE на ключах устройств (сервер видит только конверты).
- Темы: общий ключ комнаты (XChaCha20), раздача через 1-1-конверты, ротация
  при исключении. Ушедший читает старое, не читает новое — так задумано.
- Обновления: `sha256` в манифесте + сверка подписи релизного ключа до
  установки. Чужой APK не встанет.
- Не публикуй никогда: `*.keystore`, `.env` (только `.env.example`),
  `backend/data/` (базы, аплоады, логи), фото/голос пользователей.

## Лицензия

AGPL-3.0 (см. `LICENSE`). Запустил модификацию на публичном сервере —
отдай исходники сообществу.
