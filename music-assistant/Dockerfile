# Rustream (https://github.com/Sanchoz2022/rustream) с закреплённой версией исходников.
# Отличия от Dockerfile проекта:
#   - сборка под архитектуру сервера, а не только x86_64;
#   - страна поиска задаётся при сборке, а не зашита как RU;
#   - добавлен Node.js: без JS-среды yt-dlp может не получить все форматы YouTube.

FROM rust:1-alpine AS builder
ARG RUSTREAM_COMMIT=68de05a6748fdfd68d86f5a125cc25577cec0939
ARG REGION=RU
RUN apk add --no-cache musl-dev build-base perl
WORKDIR /build
RUN wget -qO- "https://github.com/Sanchoz2022/rustream/archive/${RUSTREAM_COMMIT}.tar.gz" \
      | tar xz --strip-components=1 \
 && grep -qF '"gl": "RU"' src/ytm/innertube.rs \
 && sed -i "s/\"gl\": \"RU\"/\"gl\": \"${REGION}\"/" src/ytm/innertube.rs \
 && cargo build --release --locked \
 && cp target/release/rustream /rustream

FROM alpine:3.20
RUN apk add --no-cache ffmpeg ca-certificates python3 nodejs \
 && wget -qO /usr/local/bin/yt-dlp https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
 && chmod +x /usr/local/bin/yt-dlp \
 && echo '--js-runtimes node' > /etc/yt-dlp.conf \
 && mkdir -p /data /music \
 && printf '%s\n' \
      'music_dirs = ["/music"]' \
      'bind_addr = "0.0.0.0:4533"' \
      'db_path = "/data/rustream.db"' \
      'ytm_enabled = true' \
      'ytdlp_path = "yt-dlp"' \
      'ytm_cache_dir = "/cache/ytm"' \
      'ytm_cache_max_mb = 512' \
      > /etc/rustream.toml
# Конфиг лежит в образе: compose не разрешает inline-конфиги в контейнере с read_only.
ENV RUSTREAM_CONFIG=/etc/rustream.toml
COPY --from=builder /rustream /usr/local/bin/rustream
WORKDIR /data
EXPOSE 4533
CMD ["/usr/local/bin/rustream"]
