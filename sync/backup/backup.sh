#!/usr/bin/env bash
# Периодический бекап Seafile на Яндекс.Диск (WebDAV, через rclone).
#
# Каждый запуск:
#   1. дамп баз ccnet_db, seafile_db, seahub_db → <REMOTE>/db/ (хранится BACKUP_RETENTION_DAYS дней);
#   2. файлы Seafile (/source/seafile, без логов) → <REMOTE>/files/ (зеркало последнего состояния),
#      если BACKUP_DATA=true.
# Между запусками контейнер спит BACKUP_INTERVAL_HOURS часов. Первый бекап — сразу после старта.

set -euo pipefail

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

: "${DB_HOST:=db}"
: "${DB_PORT:=3306}"
: "${DB_ROOT_PASSWORD:?Задай DB_ROOT_PASSWORD}"
: "${YANDEX_USER:?Задай YANDEX_USER}"
: "${YANDEX_APP_PASSWORD:?Задай YANDEX_APP_PASSWORD}"
: "${BACKUP_REMOTE_DIR:=seafile-backup}"
: "${BACKUP_INTERVAL_HOURS:=24}"
: "${BACKUP_RETENTION_DAYS:=14}"
: "${BACKUP_DATA:=true}"
: "${SEAFILE_DATA_DIR:=/source/seafile}"

# Удалённое хранилище описывается переменными rclone, файл конфига не нужен.
# rclone хранит пароль в обфусцированном виде, поэтому пароль приложения кодируем здесь.
export RCLONE_CONFIG_YANDEX_TYPE=webdav
export RCLONE_CONFIG_YANDEX_URL=https://webdav.yandex.ru
export RCLONE_CONFIG_YANDEX_VENDOR=other
export RCLONE_CONFIG_YANDEX_USER="$YANDEX_USER"
RCLONE_CONFIG_YANDEX_PASS="$(rclone obscure "$YANDEX_APP_PASSWORD")"
export RCLONE_CONFIG_YANDEX_PASS
REMOTE="yandex:${BACKUP_REMOTE_DIR}"

# mariadb-клиент берёт пароль из MYSQL_PWD, чтобы он не попадал в аргументы командной строки
export MYSQL_PWD="$DB_ROOT_PASSWORD"

wait_for_db() {
    local _
    for _ in $(seq 1 60); do
        if mariadb -h "$DB_HOST" -P "$DB_PORT" -u root -e 'SELECT 1' >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    return 1
}

dump_db() {
    local stamp file
    stamp="$(date '+%Y%m%d-%H%M%S')"
    file="/tmp/seafile-db-${stamp}.sql.gz"

    # --single-transaction даёт согласованный снимок InnoDB без остановки базы
    if ! mariadb-dump -h "$DB_HOST" -P "$DB_PORT" -u root \
            --single-transaction --routines --events \
            --databases ccnet_db seafile_db seahub_db \
            | gzip -9 > "$file"; then
        rm -f "$file"
        return 1
    fi

    if ! rclone copy "$file" "$REMOTE/db/"; then
        rm -f "$file"
        return 1
    fi
    rm -f "$file"
    log "дамп баз загружен: $(basename "$file")"
}

sync_data() {
    # Файлы блоков Seafile неизменяемы, поэтому копирование на ходу безопасно.
    # Логи не нужны в бекапе.
    rclone sync "$SEAFILE_DATA_DIR" "$REMOTE/files" \
        --exclude 'logs/**' \
        --transfers 4 \
        --checkers 8 \
        --stats-one-line
    log "файлы Seafile синхронизированы"
}

prune_dumps() {
    rclone delete "$REMOTE/db/" --min-age "${BACKUP_RETENTION_DAYS}d"
}

run_backup() {
    log "старт бекапа"

    wait_for_db || { log "БД недоступна, бекап пропущен"; return 1; }
    dump_db || { log "ошибка дампа баз"; return 1; }

    if [[ "$BACKUP_DATA" == "true" ]]; then
        sync_data || { log "ошибка синхронизации файлов"; return 1; }
    fi

    prune_dumps || log "не удалось удалить старые дампы"
    log "бекап завершён"
}

log "бекап каждые ${BACKUP_INTERVAL_HOURS} ч, дампы хранятся ${BACKUP_RETENTION_DAYS} дн., назначение: ${REMOTE}, файлы: ${BACKUP_DATA}"

while true; do
    run_backup || log "бекап завершился с ошибкой"
    sleep "$((BACKUP_INTERVAL_HOURS * 3600))"
done
