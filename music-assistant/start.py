"""Подготовка /config перед запуском music-play.

- Пароль music-play читает только из auth.json, а не из окружения. Записываем его
  из SUBSONIC_USER и SUBSONIC_PASSWORD, чтобы сервер не запускался без пароля.
- Из одного файла cookies.txt получаем второй формат: ytmusic_auth.json для ytmusicapi.
  yt-dlp использует сам cookies.txt.
"""
import base64
import json
import os
import sys
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("CONFIG_DIR", "/config"))
COOKIES_FILE = CONFIG_DIR / "cookies.txt"
YTM_AUTH_FILE = CONFIG_DIR / "ytmusic_auth.json"
AUTH_FILE = CONFIG_DIR / "auth.json"

YTM_ORIGIN = "https://music.youtube.com"
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
)
# Без этой куки ytmusicapi не может подписать запросы от имени аккаунта.
SAPISID_COOKIE = "__Secure-3PAPISID"
# Срок для кук из строки заголовка, где его нет: 2100 год. Реальный срок решает Google.
COOKIE_EXPIRES = 4102444800


def write_private(path, text):
    """Записывает файл с правами 600 уже в момент создания."""
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(str(path), 0o600)


def parse_youtube_cookies(text):
    """Куки домена youtube.com из файла в формате Netscape."""
    cookies = {}
    for line in text.splitlines():
        if line.startswith("#HttpOnly_"):
            line = line[len("#HttpOnly_"):]
        elif not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 7:
            continue
        domain, name, value = fields[0].lower(), fields[5], fields[6]
        if domain == "youtube.com" or domain.endswith(".youtube.com"):
            cookies[name] = value
    return cookies


def build_ytm_headers(cookies):
    """Заголовки для ytmusicapi, как после `ytmusicapi browser`."""
    # SimpleCookie в ytmusicapi прекращает разбор на первой недопустимой куке,
    # поэтому нужная кука идёт первой.
    ordered = [SAPISID_COOKIE] + sorted(name for name in cookies if name != SAPISID_COOKIE)
    return {
        # Значение заменяется при каждом запросе, но ключ нужен для определения типа входа.
        "authorization": "SAPISIDHASH 0_0",
        "cookie": "; ".join(f"{name}={cookies[name]}" for name in ordered),
        "x-goog-authuser": "0",
        "origin": YTM_ORIGIN,
        "x-origin": YTM_ORIGIN,
        "user-agent": USER_AGENT,
        "accept": "*/*",
        "content-type": "application/json",
    }


def decode_cookie_env(value):
    """Содержимое cookies.txt из YTM_COOKIES: base64, Netscape или строка `a=b; c=d`."""
    value = value.strip()
    if "\t" in value:
        return value
    try:
        decoded = base64.b64decode(value, validate=True).decode("utf-8")
        if "\t" in decoded:
            return decoded
    except ValueError:
        pass
    pairs = []
    for part in value.removeprefix("Cookie:").split(";"):
        name, separator, cookie = part.strip().partition("=")
        if separator and name:
            pairs.append((name, cookie))
    if not pairs:
        raise ValueError("формат не распознан")
    lines = [f".youtube.com\tTRUE\t/\tTRUE\t{COOKIE_EXPIRES}\t{name}\t{cookie}" for name, cookie in pairs]
    return "# Netscape HTTP Cookie File\n" + "\n".join(lines) + "\n"


def apply_cookie_env():
    """Записывает куки из YTM_COOKIES в cookies.txt. Пустая переменная ничего не меняет."""
    value = os.environ.pop("YTM_COOKIES", "")
    if not value.strip():
        return
    try:
        text = decode_cookie_env(value)
    except ValueError as error:
        print(f"YTM_COOKIES не применена: {error}", file=sys.stderr, flush=True)
        return
    COOKIES_FILE.unlink(missing_ok=True)
    write_private(COOKIES_FILE, text)


def sync_ytm_auth():
    """Обновляет ytmusic_auth.json. Возвращает True, если вход в аккаунт настроен."""
    if not COOKIES_FILE.exists():
        YTM_AUTH_FILE.unlink(missing_ok=True)
        print("cookies.txt нет: YouTube Music работает без входа в аккаунт", flush=True)
        return False

    # docker cp сохраняет владельца с хоста. Пересоздаём файл от root, чтобы yt-dlp мог
    # его обновлять, а права были 600.
    raw = COOKIES_FILE.read_text(encoding="utf-8", errors="replace")
    COOKIES_FILE.unlink()
    write_private(COOKIES_FILE, raw)
    cookies = parse_youtube_cookies(raw)
    if SAPISID_COOKIE not in cookies:
        YTM_AUTH_FILE.unlink(missing_ok=True)
        print(
            f"В cookies.txt нет {SAPISID_COOKIE}. Экспортируй куки после входа на "
            "music.youtube.com. Плейлисты аккаунта недоступны",
            file=sys.stderr,
            flush=True,
        )
        return False

    write_private(YTM_AUTH_FILE, json.dumps(build_ytm_headers(cookies), indent=2))
    print("Вход в YouTube Music настроен из cookies.txt", flush=True)
    return True


def write_credentials():
    user = os.environ.get("SUBSONIC_USER", "").strip()
    password = os.environ.get("SUBSONIC_PASSWORD", "").strip()
    if not user or not password:
        sys.exit("SUBSONIC_USER и SUBSONIC_PASSWORD обязательны: без пароля сервер открыт")
    write_private(AUTH_FILE, json.dumps({"username": user, "password": password}))


def main():
    write_credentials()
    try:
        apply_cookie_env()
        sync_ytm_auth()
    except OSError as error:
        # Сервер без входа в аккаунт лучше цикла перезапусков.
        print(f"Не удалось обработать cookies.txt: {error}", file=sys.stderr, flush=True)
    port = os.environ.get("PORT", "5080")
    # Без access-лога: Amperfy передаёт логин и токен в строке запроса.
    os.execvp(
        "python",
        ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", port, "--no-access-log"],
    )


if __name__ == "__main__":
    main()
