"""Правки music-play при сборке образа. Сборка падает, если исходный код изменился."""
from pathlib import Path


def replace_once(path, old, new):
    file = Path(path)
    text = file.read_text(encoding="utf-8")
    if text.count(old) != 1:
        raise SystemExit(f"{path}: ожидалось одно вхождение: {old[:70]!r}")
    file.write_text(text.replace(old, new), encoding="utf-8")


# 1. Авторизация. В оригинале запрос без сессии считается запросом от пользователя по
#    умолчанию, поэтому без параметра u проходит любой Subsonic-запрос и вызов веб-API,
#    включая смену пароля.
replace_once(
    "app/main.py",
    "user = web_session.read(request) or auth_store.username()",
    "user = web_session.read(request) or "
    "(None if auth_store.password_required() else auth_store.username())",
)

# Экран входа. В оригинале он удалён: интерфейс работал только за счёт этой уязвимости.
LOGIN_PAGE = '''<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><title>Music Play</title>
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>
*{box-sizing:border-box}
body{margin:0;min-height:100dvh;display:grid;place-items:center;padding:16px;
background:#14171d;color:#e8eaee;font:16px/1.4 system-ui,-apple-system,sans-serif}
form{width:100%;max-width:320px;display:grid;gap:12px}
h1{margin:0 0 4px;font-size:22px}
input,button{width:100%;padding:12px;border-radius:10px;font:inherit;border:1px solid #39404d}
input{background:#1c212b;color:inherit}
button{background:#e8eaee;color:#14171d;border-color:#e8eaee;font-weight:600}
p{margin:0;color:#ff8a80}
</style></head><body>
<form method="post" action="/api/login">
<h1>Music Play</h1>
<p id="error" hidden>Неверный пароль</p>
<input type="password" name="password" placeholder="Пароль" aria-label="Пароль"
 autocomplete="current-password" autofocus required>
<button type="submit">Войти</button>
</form>
<script>
if (new URLSearchParams(location.search).get("login") === "fail")
  document.getElementById("error").hidden = false;
</script>
</body></html>'''
replace_once(
    "app/main.py",
    '@app.get("/", response_class=HTMLResponse)\n'
    "async def index(request: Request):\n"
    "    return templates.TemplateResponse(\n",
    f"LOGIN_PAGE = {LOGIN_PAGE!r}\n\n\n"
    '@app.get("/", response_class=HTMLResponse)\n'
    "async def index(request: Request):\n"
    "    if not request.state.session_user:\n"
    '        return HTMLResponse(LOGIN_PAGE, headers={"Cache-Control": "no-store"})\n'
    "    return templates.TemplateResponse(\n",
)

# 1а. Общий поиск YouTube не возвращает у песен длительность и альбом, из-за чего size=0, и
#     Amperfy их скрывает. Песни берём из поиска с фильтром, остальное оставляем как есть.
replace_once(
    "app/ytm/client.py",
    '    if not grouped["playlists"] and not grouped["community_playlists"]:\n',
    '    scoped_songs = search(query, "songs", max(song_limit, 20))\n'
    "    if scoped_songs:\n"
    "        # Один трек не должен попасть в базу дважды: это нарушает UNIQUE и отменяет запись.\n"
    "        song_ids: set[str] = set()\n"
    '        grouped["songs"] = []\n'
    '        _extend_unique(grouped["songs"], scoped_songs, song_ids)\n'
    '        grouped["videos"] = [item for item in grouped["videos"] if item.get("id") not in song_ids]\n\n'
    '    if not grouped["playlists"] and not grouped["community_playlists"]:\n',
)
replace_once(
    "app/subsonic/entities.py",
    '"size": track.get("size") or estimated_size(duration, bitrate),',
    '"size": track.get("size") or estimated_size(duration or 240, bitrate),',
)

# 2. YouTube отвечает 403, пока не наступит время available_at из ответа yt-dlp.
replace_once(
    "app/ytm/streams.py",
    '        ext = (fmt.get("ext") or "m4a").lower()\n',
    '        available_at = fmt.get("available_at") or (info or {}).get("available_at")\n'
    "        if available_at:\n"
    "            time.sleep(max(0.0, available_at - time.time()) + 0.5)\n\n"
    '        ext = (fmt.get("ext") or "m4a").lower()\n',
)

# 3. Без заголовка Range YouTube ограничивает скорость примерно до 32 КБ/с.
replace_once(
    "app/subsonic/media.py",
    'async with _http.stream("GET", source.url) as upstream:',
    'async with _http.stream("GET", source.url, headers={"Range": "bytes=0-"}) as upstream:',
)
replace_once(
    "app/subsonic/media.py",
    "async def _proxy(source: streams.StreamSource, range_header: str | None) -> Response:\n"
    '    headers = {"Range": range_header} if range_header else {}\n',
    "async def _proxy(source: streams.StreamSource, range_header: str | None) -> Response:\n"
    '    headers = {"Range": range_header or "bytes=0-"}\n',
)
replace_once(
    "app/subsonic/media.py",
    "    async def body():\n"
    "        try:\n"
    "            async for chunk in upstream.aiter_bytes(CHUNK_SIZE):\n"
    "                yield chunk\n"
    "        finally:\n"
    "            await upstream.aclose()\n\n"
    "    return StreamingResponse(\n"
    "        body(),\n"
    "        status_code=upstream.status_code,\n"
    "        media_type=source.content_type,\n",
    '    if not range_header:\n        passthrough.pop("Content-Range", None)\n\n'
    "    async def body():\n"
    "        try:\n"
    "            async for chunk in upstream.aiter_bytes(CHUNK_SIZE):\n"
    "                yield chunk\n"
    "        finally:\n"
    "            await upstream.aclose()\n\n"
    "    return StreamingResponse(\n"
    "        body(),\n"
    "        status_code=upstream.status_code if range_header else 200,\n"
    "        media_type=source.content_type,\n",
)

# 4. YouTube отдаёт AAC во фрагментированном MP4, в котором плеер Amperfy, по замерам
#    проекта Mirasonic, не может перематывать. ADTS хранит те же кадры без перекодирования
#    и допускает переход с любого места.
replace_once(
    "app/subsonic/media.py",
    "        partial.replace(target)\n"
    "        await run_in_threadpool(\n"
    "            streams.register_cached, source.video_id, target, "
    "source.content_type, source.suffix, source.bitrate\n"
    "        )\n",
    "        content_type, suffix = source.content_type, source.suffix\n"
    '        adts = target.with_suffix(".aac")\n'
    "        converted = False\n"
    '        if source.acodec.startswith("mp4a"):\n'
    "            process = await asyncio.create_subprocess_exec(\n"
    '                "ffmpeg", "-v", "error", "-y", "-i", str(partial),\n'
    '                "-vn", "-c:a", "copy", "-f", "adts", str(adts),\n'
    "            )\n"
    "            converted = await process.wait() == 0 and adts.stat().st_size > 0\n"
    "        if converted:\n"
    "            partial.unlink(missing_ok=True)\n"
    '            target, content_type, suffix = adts, "audio/aac", "aac"\n'
    "        else:\n"
    "            adts.unlink(missing_ok=True)\n"
    "            partial.replace(target)\n"
    "        await run_in_threadpool(\n"
    "            streams.register_cached, source.video_id, target, "
    "content_type, suffix, source.bitrate\n"
    "        )\n",
)

# 5. Трек целиком скачивается в кеш до ответа: загрузка занимает около секунды, а файл из
#    кеша даёт точные Content-Length и Range. Прокси остаётся запасным путём.
replace_once(
    "app/subsonic/media.py",
    "    await _schedule_prefetch(source)\n"
    "    return await _proxy(source, range_header)\n",
    "    if settings.cache_enabled:\n"
    "        async with _track_locks.setdefault(video_id, asyncio.Lock()):\n"
    "            entry = await run_in_threadpool(streams.cached_entry, video_id)\n"
    "            if not entry:\n"
    "                await _prefetch_to_cache(source)\n"
    "                entry = await run_in_threadpool(streams.cached_entry, video_id)\n"
    "        if entry:\n"
    "            return serve_cached_file(entry, range_header)\n\n"
    "    return await _proxy(source, range_header)\n",
)
replace_once(
    "app/subsonic/media.py",
    "_prefetch_lock = asyncio.Lock()\n",
    "_prefetch_lock = asyncio.Lock()\n_track_locks: dict[str, asyncio.Lock] = {}\n",
)
