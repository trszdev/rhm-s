"""Зеркалирование плейлистов YouTube Music в локальные плейлисты.

Amperfy получает локальные плейлисты через Subsonic getPlaylists. Если у
локального плейлиста заполнен ytm_id, его состав заменяется актуальным
составом плейлиста YouTube Music. Так добавления и удаления появляются в
Amperfy не позже чем через интервал синхронизации.

Переменные окружения:
- PLAYLIST_SYNC_URLS — URL или id плейлистов через запятую;
- PLAYLIST_SYNC_INTERVAL_MINUTES — интервал, по умолчанию 15 минут.
"""
from __future__ import annotations

import asyncio
import os
import shutil
from contextlib import suppress
from urllib.parse import parse_qs, urlparse

from sqlalchemy import select

from app.core.logging import logger
from app.core.settings import settings
from app.db import repo
from app.db.database import session_scope
from app.db.models import Playlist
from app.ytm import client as ytm
from app.ytm import streams

DEFAULT_INTERVAL_MINUTES = 15

_task: asyncio.Task | None = None


def _playlist_id(value: str) -> str | None:
    """Достаёт id из ссылки music.youtube.com/playlist?list=… или принимает id как есть."""
    value = (value or "").strip()
    if not value:
        return None
    if "://" in value or "list=" in value:
        values = parse_qs(urlparse(value).query).get("list") or []
        value = (values[0] if values else "").strip()
    if value.startswith("VL"):
        value = value[2:]
    return value or None


def configured_playlists() -> list[str]:
    raw = os.getenv("PLAYLIST_SYNC_URLS", "")
    playlists: list[str] = []
    for part in raw.replace("\n", ",").split(","):
        playlist_id = _playlist_id(part)
        if playlist_id and playlist_id not in playlists:
            playlists.append(playlist_id)
    return playlists


def _interval_seconds() -> float:
    try:
        minutes = float(os.getenv("PLAYLIST_SYNC_INTERVAL_MINUTES", DEFAULT_INTERVAL_MINUTES))
    except ValueError:
        minutes = DEFAULT_INTERVAL_MINUTES
    return max(minutes, 1) * 60


def clear_cache_on_start() -> None:
    """Очищает кеш при каждом запуске, даже если /cache смонтирован с диска.

    Записи в базе удаляются первыми, чтобы не осталось ссылок на пропавшие
    файлы. Затем удаляются осиротевшие файлы, обложки и кеш yt-dlp.
    """
    try:
        streams.clear_disk_cache()
    except Exception as exc:
        logger.warning("Кеш в базе не очищен: {}", exc)

    cache_root = settings.audio_cache_dir.parent
    for name in ("audio", "covers", "ytdlp", "import"):
        shutil.rmtree(cache_root / name, ignore_errors=True)
    settings.audio_cache_dir.mkdir(parents=True, exist_ok=True)
    settings.cover_cache_dir.mkdir(parents=True, exist_ok=True)
    logger.info("Кеш на диске очищен при запуске")


def sync_once() -> None:
    playlist_ids = configured_playlists()
    if not playlist_ids:
        return

    # Ответы YouTube Music кешируются на 15 минут, а задача как раз должна
    # замечать изменения. Поэтому перед обходом сбрасываем кеш целиком.
    ytm.clear_cache()

    for playlist_id in playlist_ids:
        try:
            remote = ytm.playlist(playlist_id, limit=None)
        except Exception as exc:
            logger.warning("Плейлист {} не получен: {}", playlist_id, exc)
            continue
        if not remote:
            logger.warning("Плейлист {} не найден или недоступен", playlist_id)
            continue

        tracks = [track for track in remote.get("tracks") or [] if track.get("id")]
        track_ids = [track["id"] for track in tracks]
        if not track_ids:
            logger.warning("Плейлист {} пуст, локальная версия не изменена", playlist_id)
            continue

        with session_scope() as session:
            local = session.scalar(select(Playlist).where(Playlist.ytm_id == playlist_id))
            if local is not None and repo.playlist_track_ids(session, local.id) == track_ids:
                logger.debug("Плейлист {} без изменений: {} треков", playlist_id, len(track_ids))
                continue

            repo.upsert_tracks(session, tracks)
            if local is None:
                local = repo.create_playlist(
                    session,
                    remote.get("name") or "YouTube Music",
                    track_ids,
                    ytm_id=playlist_id,
                )
            else:
                # Имя, заданное в Amperfy, не перезаписываем: меняется только состав.
                repo.replace_playlist_tracks(session, local.id, track_ids)
            logger.info("Плейлист «{}» синхронизирован: {} треков", local.name, len(track_ids))


async def _run() -> None:
    interval = _interval_seconds()
    while True:
        try:
            await asyncio.to_thread(sync_once)
        except Exception as exc:
            logger.exception("Синхронизация плейлистов: {}", exc)
        await asyncio.sleep(interval)


def start() -> None:
    global _task
    playlist_ids = configured_playlists()
    if not playlist_ids:
        logger.info("Синхронизация плейлистов не настроена")
        return
    if _task is None or _task.done():
        _task = asyncio.create_task(_run(), name="playlist-sync")
        logger.info(
            "Синхронизация плейлистов: {} каждые {} мин",
            ", ".join(playlist_ids),
            _interval_seconds() / 60,
        )


async def stop() -> None:
    global _task
    if _task is None:
        return
    _task.cancel()
    with suppress(asyncio.CancelledError):
        await _task
    _task = None
