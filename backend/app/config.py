import os
from pathlib import Path

from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")


class Settings:
    def __init__(self) -> None:
        self.host = os.getenv("HOST", "0.0.0.0")
        self.port = int(os.getenv("PORT", "5050"))
        self.server_domain = os.getenv("SERVER_DOMAIN", "localhost")
        # Псевдоним сервера для каталога (показывается вместо IP/host).
        self.server_name = os.getenv("SERVER_NAME", "") or self.server_domain
        self.server_city = os.getenv("SERVER_CITY", "")
        self.server_country = os.getenv("SERVER_COUNTRY", "")
        self.db_path = os.getenv("DB_PATH", str(BASE_DIR / "data" / "node.db"))
        self.identity_path = os.getenv("IDENTITY_PATH", str(BASE_DIR / "data" / "identity.json"))
        self.admin_bootstrap_code = os.getenv("ADMIN_BOOTSTRAP_CODE", "")
        self.admin_username = os.getenv("ADMIN_USERNAME", "admin")
        self.session_ttl_hours = int(os.getenv("SESSION_TTL_HOURS", "720"))
        self.appeal_interval_days = int(os.getenv("APPEAL_INTERVAL_DAYS", "7"))
        self.message_ttl_seconds = int(os.getenv("MESSAGE_TTL_SECONDS", "1800"))
        self.s2s_timeout_seconds = int(os.getenv("S2S_TIMEOUT_SECONDS", "10"))
        self.trusted_proxy = os.getenv("TRUSTED_PROXY", "127.0.0.1")
        self.max_family_spaces = int(os.getenv("MAX_FAMILY_SPACES", "3"))
        self.invite_ttl_hours = int(os.getenv("INVITE_TTL_HOURS", "72"))
        self.uploads_dir = os.getenv("UPLOADS_DIR", str(BASE_DIR / "data" / "uploads"))
        # Режим федерации с другими серверами: closed (весь S2S отклоняется,
        # сервер невидим), allowlist (спаривание только вручную, работают
        # подписанные запросы из server_registry), open (спаривание через
        # /s2s/link_request + подписанные запросы).
        self.federation_mode = os.getenv("FEDERATION_MODE", "closed").strip().lower()
        if self.federation_mode not in ("closed", "allowlist", "open"):
            self.federation_mode = "closed"
        # TURN для звонков. Клиент забирает параметры через /api/server_info
        # (вместо хардкода в APK). TURN_ENABLED=0 — сервер не отдаёт TURN,
        # клиент ходит напрямую/STUN.
        self.turn_enabled = os.getenv("TURN_ENABLED", "1") not in ("0", "false", "no")
        self.turn_host = os.getenv("TURN_HOST", "")
        self.turn_port = int(os.getenv("TURN_PORT", "3478"))
        self.turn_user = os.getenv("TURN_USER", "")
        self.turn_pass = os.getenv("TURN_PASS", "")
        # Публичный манифест обновлений APK (для GitHub Releases — URL на
        # raw.githubusercontent; пусто = локальный /api/diag/update).
        self.update_manifest_url = os.getenv("UPDATE_MANIFEST_URL", "").strip()
        # Авто-подтяжка APK с GitHub Releases (сервер-зеркало для своих).
        self.github_repo = os.getenv("GITHUB_REPO", "").strip()
        self.update_check_enabled = os.getenv("UPDATE_CHECK_ENABLED", "1") not in ("0", "false", "no")
        self.update_check_hours = int(os.getenv("UPDATE_CHECK_HOURS", "6"))
        self.auto_update_pull = os.getenv("AUTO_UPDATE_PULL", "0") not in ("0", "false", "no")
        # Публичный URL, под которым раздаются загруженные файлы.
        # По умолчанию — локальный узел: http://<host>:<port>/uploads/.
        self.public_base_url = os.getenv(
            "PUBLIC_BASE_URL", f"http://{os.getenv('SERVER_DOMAIN', 'localhost')}:{os.getenv('PORT', '5050')}"
        ).rstrip("/")

    @property
    def session_ttl_seconds(self) -> int:
        return self.session_ttl_hours * 3600


settings = Settings()
