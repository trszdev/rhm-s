# Настройка машины для self-host

Скрипты готовят Debian/Ubuntu-сервер:

1. **unattended-upgrades**: автоматические обновления безопасности, а также `docker-ce` и `tailscale` из их репозиториев. Перезагрузка в заданное время только если она нужна.
2. **Tailscale + Tailscale SSH**: доступ к машине только из tailnet.
3. **Docker Engine + Portainer**: Portainer запускается стеком [docker/](docker/) и доступен по HTTPS на MagicDNS-имени `https://<имя>.<tailnet>.ts.net`.
4. **Отключение системного OpenSSH**: порт 22 закрывается, остаётся только Tailscale SSH.

Скрипты не запускаются на macOS. Они рассчитаны на Ubuntu и Debian (проверяется `/etc/os-release`).

## Перед запуском

- Ubuntu или Debian, доступ `sudo`, интернет.
- Аккаунт Tailscale. В админке (*Settings → Keys*) создай auth key.
  - Один ключ нужен шагу `tailscale` (узел хоста) и шагу `docker` (контейнер Portainer). Одноразовый ключ может использовать только один узел. Поэтому создай **reusable** ключ или два разных.
- В админке Tailscale включи **MagicDNS** и **HTTPS certificates** (раздел DNS). Без них `tailscale serve` не выдаст сертификат.
- В *Access controls* SSH должен быть разрешён для твоих устройств. В политике по умолчанию это уже так.
- Для доступа к машине нужен хотя бы один вход, который не зависит от OpenSSH: консоль провайдера или физический доступ. Это страховка на случай, если Tailscale не поднимется.

## Запуск

Скопируй папку `setup` на машину (например, через `git clone` этого репозитория), затем:

```bash
cd setup
sudo ./install.sh
```

С auth key (ключ не попадёт в историю shell):

```bash
read -rs -p "Tailscale auth key: " TS_AUTHKEY && echo
export TS_AUTHKEY
sudo --preserve-env=TS_AUTHKEY ./install.sh
```

Запустить отдельные шаги:

```bash
sudo ./install.sh upgrades
sudo ./install.sh tailscale docker
```

### Порядок и безопасность

Шаг `close-ssh` стоит последним и работает только после проверки:

1. Из другого устройства зайди через `tailscale ssh <пользователь>@<имя-машины>`.
2. Только после успешного входа запусти шаг `close-ssh` (или весь `install.sh`).

Шаг `close-ssh` сам проверяет, что Tailscale подключён и Tailscale SSH включён. Он также отказывается работать, если есть активные SSH-подключения к порту 22, потому что они оборвутся. Чтобы обойти эту проверку, используй `FORCE=1`, но делай так только осознанно.

## Portainer за Tailscale HTTPS

Шаг `docker` ставит Docker и запускает стек [docker/docker-compose.yml](docker/docker-compose.yml):

- `ts` — отдельный узел tailnet с именем `PORTAINER_TS_HOSTNAME` (по умолчанию `portainer`). Ключ берётся из `TS_AUTHKEY`.
- `portainer` — находится с `ts` в общей внутренней сети `backend`, порты не публикует.
- `tailscale serve` по [config/serve.json](docker/config/serve.json) проксирует `https://portainer.<tailnet>.ts.net` на `https+insecure://portainer:9443`. Сертификат выдаёт Tailscale и продлевает сам. Браузер не покажет предупреждение.

Общий `network_mode: service:ts` здесь использовать нельзя: в userspace-режиме tailscaled перенаправляет входящие порты узла на свой `127.0.0.1`, и порты Portainer стали бы доступны в tailnet в обход `serve`.

Шаг создаёт `setup/docker/.env` (права 600) из `TS_AUTHKEY`. Если `.env` уже есть, шаг его не трогает. Файл `.env` не коммить, он в `.gitignore`.

Ручной запуск без install.sh:

```bash
cd setup/docker
cp .env.example .env          # впиши TS_AUTHKEY
chmod 600 .env
docker compose up -d
docker compose logs -f ts     # ждём подключения к tailnet
```

Проверка:

```bash
docker compose exec ts tailscale serve status
curl -sI https://portainer.<tailnet>.ts.net | head -1
```

Если serve не поднялся, посмотри `docker compose logs ts`. Строка `not able to issue TLS certs` значит, что в tailnet выключены HTTPS Certificates.

Прямое обращение к узлу по портам не должно работать: с другого устройства в tailnet `curl -m 5 -k https://portainer.<tailnet>.ts.net:9443` должен завершиться ошибкой подключения.

Старый контейнер `portainer` из прошлой версии скрипта шаг `docker` удаляет. Его volume `portainer_data` остаётся, но новый стек использует свой volume `selfhost_portainer_data`. Данные старого Portainer не переносятся, при первом входе создаётся новый admin.

## Переменные окружения

| Переменная | Где используется | По умолчанию | Назначение |
|---|---|---|---|
| `TS_AUTHKEY` | tailscale, docker | — | auth key: для шага `tailscale` и для контейнера `ts` (нужен, если нет `docker/.env`) |
| `TS_HOSTNAME` | tailscale | короткое имя хоста | имя хоста в tailnet |
| `PORTAINER_TS_HOSTNAME` | docker | `portainer` | имя Portainer в tailnet |
| `REBOOT_TIME` | upgrades | `04:00` | время возможной автоперезагрузки, `HH:MM` |
| `ASSUME_YES` | close-ssh | — | `1` пропускает вопрос подтверждения |
| `FORCE` | close-ssh | — | `1` отключает проверку активных SSH-сессий |

## Проверка после установки

```bash
tailscale status
tailscale ip -4
tailscale debug prefs | grep RunSSH          # ожидаем "RunSSH": true
ss -ltn | grep ':22 '                        # ожидаем пустой вывод
apt-config dump | grep Automatic-Reboot      # ожидаем "true" и время
sudo unattended-upgrade --dry-run --debug    # проверка без установки
docker run --rm hello-world
docker compose -f setup/docker/docker-compose.yml ps
```

Portainer открывается по адресу `https://portainer.<tailnet>.ts.net` (или по имени из `PORTAINER_TS_HOSTNAME`). Адрес только внутри tailnet, сертификат настоящий.

## Важные нюансы

- **Docker обходит ufw.** Опубликованные порты контейнеров (`-p 8080:80`) открываются наружу, даже если ufw их запрещает. Публикуй порты только на tailnet IP (`-p 100.x.y.z:8080:80`) или открывай через ufw осознанно. Сами скрипты ufw не настраивают.
- **Группа `docker` равна root.** Пользователь из этой группы может получить root через контейнер. Туда добавляется пользователь, который запустил `sudo`.
- **Portainer монтирует `/var/run/docker.sock`.** Это полный контроль над Docker, то есть над хостом. Доступ к Portainer должен быть только у тебя. Через tailnet он доступен только тем, кому разрешено в ACL.
- **Автоперезагрузка.** Перезагрузка происходит только если после обновления появился `/var/run/reboot-required`, в `REBOOT_TIME`, даже если кто-то подключён. Контейнеры с `restart: unless-stopped` и Tailscale поднимаются после загрузки сами.
- **Автообновление Docker и Tailscale.** Шаг `upgrades` добавляет в unattended-upgrades origin-правила `origin=Docker,label=Docker CE` и `origin=Tailscale,label=Tailscale`. Они взяты из Release-файлов репозиториев. Пакеты `docker-ce`, `containerd.io` и т.п. обновляются вместе с этим правилом.
  - Обновление демона перезапускает `dockerd` и `tailscaled`. Контейнеры поднимутся сами, но будут недоступны несколько секунд. Если это недопустимо, добавь `"live-restore": true` в `/etc/docker/daemon.json`.
  - Обновление `tailscaled` может на несколько секунд оборвать SSH-сессию через tailnet. Переподключись.
  - Шаг `tailscale` не включает `tailscale set --auto-update`, чтобы обновлял только unattended-upgrades.
  - Проверить, что правила активны: `apt-config dump | grep Origins-Pattern`.

## Откат: вернуть OpenSSH

Нужен доступ через консоль провайдера или физически, если Tailscale SSH уже не работает.

```bash
sudo systemctl unmask ssh.service ssh.socket
sudo apt-get install -y openssh-server
sudo systemctl enable --now ssh.service
```

## Структура

```
setup/
├── install.sh                       # точка входа, запускает шаги по порядку
├── README.md
├── lib/common.sh                    # общие функции: log, die, confirm, проверки ОС
├── steps/
│   ├── 10-unattended-upgrades.sh    # автообновления и перезагрузка
│   ├── 20-tailscale.sh              # Tailscale + Tailscale SSH на хосте
│   ├── 30-docker-portainer.sh       # Docker, затем запуск стека docker/
│   └── 40-close-openssh.sh          # отключение системного sshd
└── docker/
    ├── docker-compose.yml           # контейнеры ts и portainer
    ├── config/serve.json            # HTTPS-прокси tailscale serve
    ├── .env.example
    └── .gitignore
```
