# Образ music-play (https://github.com/PaulG67/music-play, коммит bc7af3e) с исправлениями
# из patch_music_play.py и свежим yt-dlp. Готовый образ есть только для amd64.
FROM ghcr.io/paulg67/music-play@sha256:7344a0fcce5e3b0c4f91a43c586dd0894e541680d986e3d221e44d642ea0f01d

COPY patch_music_play.py /tmp/patch_music_play.py
RUN python /tmp/patch_music_play.py && rm /tmp/patch_music_play.py

# Готовый образ не обновляется сам, а YouTube регулярно ломает извлечение потоков.
RUN pip install --no-cache-dir --upgrade "yt-dlp[default]"

COPY start.py /usr/local/bin/music-play-start.py
ENTRYPOINT ["python", "/usr/local/bin/music-play-start.py"]
