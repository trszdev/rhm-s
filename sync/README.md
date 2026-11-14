# Seafile локально с бекапом на Яндекс.Диск

Стек поднимает Seafile Server, доступный по HTTPS из tailnet Tailscale (`https://<TS_HOSTNAME>.<tailnet>.ts.net`), и раз в сутки (по умолчанию) отправляет бекап на Яндекс.Диск.

Состав стека ([docker-compose.yml](docker-compose.yml)):

- `tailscale` — отдельный узел tailnet. `tailscale serve` проксирует HTTPS на `seafile:80`, сертификат выдаёт Tailscale;
- `seafile` — Seafile Server 11.0, порты на хост не публикуются, доступ только из tailnet;
- `db` — MariaDB 10.11 для `ccnet_db`, `seafile_db`, `seahub_db`;
- `memcached` — кеш Seafile;
- `backup` — образ из [backup/](backup/): дамп баз и синхронизация файлов Seafile на Яндекс.Диск по WebDAV через rclone.

Данные лежат в именованных томах Docker `seafile_seafile-data` и `seafile_db-data`. Бекап монтирует том с файлами Seafile только для чтения.

## Перед запуском

- Docker Desktop для macOS (или Docker Engine с Compose v2).
- Аккаунт Tailscale. В админке (*Settings → Keys*) создай auth key. Одноразовый ключ подойдёт для первого входа, но удобнее reusable.
- В админке Tailscale включи **MagicDNS** и **HTTPS certificates** (раздел DNS). Без них `tailscale serve` не выдаст сертификат.
- Пароль приложения для Яндекс.Диска. Основной пароль от Яндекс ID не подходит. Создай его в [id.yandex.ru](https://id.yandex.ru) → *Безопасность* → *Пароли приложений*, тип «Диск (WebDAV)».
- Место: бекап занимает столько же, сколько данные Seafile, плюс дампы баз.

## Запуск

```bash
cd sync
cp .env.example .env
chmod 600 .env
```

Заполни `.env`: `TS_AUTHKEY`, `DB_ROOT_PASSWORD`, `SEAFILE_ADMIN_PASSWORD`, `YANDEX_USER`, `YANDEX_APP_PASSWORD`, а также `SEAFILE_SERVER_HOSTNAME`. Его значение — `<TS_HOSTNAME>.<tailnet>.ts.net`. Имя tailnet видно в админке Tailscale. Затем:

```bash
docker compose up -d --build
docker compose logs -f seafile
```

Первая инициализация занимает 1–3 минуты. Когда в логах появится готовность, открой `https://<TS_HOSTNAME>.<tailnet>.ts.net` с устройства из tailnet и войди под `SEAFILE_ADMIN_EMAIL`. Проверить, что узел поднялся: `docker compose logs tailscale`.

Чтобы попасть на сервер, нужен клиент Tailscale на устройстве. Открыть адрес из браузера без него не получится.

### Квота 10 ГБ на пользователя

Квота задаётся в `seafile.conf` и применяется после первого запуска. Выполни один раз:

```bash
set -a; . ./.env; set +a
docker compose exec -e SEAFILE_QUOTA_GB seafile sh -c 'grep -q "^\[quota\]" /shared/seafile/conf/seafile.conf || printf "\n[quota]\ndefault = %s\n" "$SEAFILE_QUOTA_GB" >> /shared/seafile/conf/seafile.conf'
docker compose restart seafile
```

Проверить: в веб-интерфейсе *System Admin* у пользователя должна стоять квота 10 ГБ. Если значение не применилось, открой `seafile.conf` внутри контейнера и проверь секцию `[quota]`. Квота действует на каждого пользователя отдельно, а не на весь сервер.

## Бекап

По умолчанию бекап делается сразу после старта контейнера `backup`, затем каждые `BACKUP_INTERVAL_HOURS` часов. Структура на Яндекс.Диске:

```
seafile-backup/
├── db/      дампы ccnet_db, seafile_db, seahub_db (*.sql.gz), хранятся BACKUP_RETENTION_DAYS дней
└── files/   зеркало файлов Seafile (без логов), BACKUP_DATA=true
```

Проверить работу:

```bash
docker compose logs -f backup
```

Запустить бекап вручную (перезапуск контейнера сразу делает бекап):

```bash
docker compose restart backup
```

### Ограничения

- **Яндекс.Диск.** Бесплатный тариф обычно даёт 10 ГБ на всё, включая файлы бекапа. Если данных Seafile близко к 10 ГБ, для бекапа понадобится тариф побольше или `BACKUP_DATA=false` (тогда в облако уходят только дампы баз).
- **Файлы Seafile — зеркало.** `files/` повторяет последнее состояние. Удалённые в Seafile файлы из зеркала пропадают при следующем запуске. Откатиться к старой версии можно только через дампы баз и файлы, которые ещё лежат на диске.
- **Согласованность.** Дамп баз снимается без остановки сервера, файлы копируются на ходу. Для Seafile это обычно безопасно, но в редких случаях бекап может захватить состояние между двумя записями. Для полной согласованности останови стек перед бекапом вручную.

## Восстановление (кратко)

1. Скачай нужный `seafile-db-*.sql.gz` из `db/` и восстанови его в запущенную базу:
   ```bash
   gunzip -c seafile-db-YYYYMMDD-HHMMSS.sql.gz | docker compose exec -T db sh -c 'exec mariadb -uroot -p"$MYSQL_ROOT_PASSWORD"'
   ```
2. Файлы из `files/` скопируй в том `seafile_seafile-data` в каталог `seafile/` (сначала останови `seafile`).
3. Запусти стек: `docker compose up -d`.

## Остановка и удаление

```bash
docker compose down        # остановить, данные сохранятся
docker compose down -v     # остановить и удалить тома (все данные Seafile и базы будут потеряны)
```
