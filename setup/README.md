# Настройка машины для self-host

Скрипты готовят Debian/Ubuntu-сервер:

1. **unattended-upgrades**: автоматические обновления безопасности, а также `docker-ce` и `tailscale` из их репозиториев. Перезагрузка в заданное время только если она нужна.
2. **Tailscale + Tailscale SSH**: доступ к машине только из tailnet.
3. **Docker Engine + Portainer CE**: Portainer доступен по адресу tailnet IP.
4. **Отключение системного OpenSSH**: порт 22 закрывается, остаётся только Tailscale SSH.

Скрипты не запускаются на macOS. Они рассчитаны на Ubuntu и Debian (проверяется `/etc/os-release`).

## Перед запуском

- Ubuntu или Debian, доступ `sudo`, интернет.
- Аккаунт Tailscale. Если хочешь установку без браузера, создай auth key: *Settings → Keys* в админке Tailscale.
- В *Access controls* админки Tailscale SSH должен быть разрешён для твоих устройств. В политике по умолчанию это уже так.
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

## Переменные окружения

| Переменная | Где используется | По умолчанию | Назначение |
|---|---|---|---|
| `TS_AUTHKEY` | tailscale | — | auth key для входа без браузера |
| `TS_HOSTNAME` | tailscale | короткое имя хоста | имя машины в tailnet |
| `REBOOT_TIME` | upgrades | `04:00` | время возможной автоперезагрузки, `HH:MM` |
| `PORTAINER_BIND` | docker | tailnet IP машины | IP, на котором слушает Portainer |
| `PORTAINER_IMAGE` | docker | `portainer/portainer-ce:lts` | образ Portainer |
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
docker ps --filter name=portainer
```

Portainer открывается по адресу `https://<tailnet-IP>:9443` или по MagicDNS-имени `https://<имя-машины>.<tailnet>.ts.net:9443`. Браузер покажет предупреждение о сертификате, так как он самоподписанный.

## Важные нюансы

- **Docker обходит ufw.** Опубликованные порты контейнеров (`-p 8080:80`) открываются наружу, даже если ufw их запрещает. Публикуй порты только на tailnet IP (`-p 100.x.y.z:8080:80`) или открывай через ufw осознанно. Сами скрипты ufw не настраивают.
- **Portainer требует создать admin за ~5 минут после первого запуска.** Если не успел, выполни `docker restart portainer` и повтори.
- **Группа `docker` равна root.** Пользователь из этой группы может получить root через контейнер. Туда добавляется пользователь, который запустил `sudo`.
- **Portainer монтирует `/var/run/docker.sock`.** Это полный контроль над Docker, то есть над хостом. Доступ к Portainer должен быть только у тебя.
- **Автоперезагрузка.** Перезагрузка происходит только если после обновления появился `/var/run/reboot-required`, в `REBOOT_TIME`, даже если кто-то подключён. Контейнеры с `restart=always` и Tailscale поднимаются после загрузки сами.
- **Автообновление Docker и Tailscale.** Шаг `upgrades` добавляет в unattended-upgrades origin-правила `origin=Docker,label=Docker CE` и `origin=Tailscale,label=Tailscale`. Они взяты из Release-файлов репозиториев. Пакеты `docker-ce`, `containerd.io` и т.п. обновляются вместе с этим правилом.
  - Обновление демона перезапускает `dockerd` и `tailscaled`. Контейнеры с `restart=always` поднимутся сами, но будут недоступны несколько секунд. Если это недопустимо, добавь `"live-restore": true` в `/etc/docker/daemon.json`.
  - Обновление `tailscaled` может на несколько секунд оборвать SSH-сессию через tailnet. Переподключись.
  - Шаг `tailscale` больше не включает `tailscale set --auto-update`, чтобы обновлял только unattended-upgrades.
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
├── lib/common.sh                    # общие функции: log, die, confirm, проверки ОС
└── steps/
    ├── 10-unattended-upgrades.sh    # автообновления и перезагрузка
    ├── 20-tailscale.sh              # Tailscale + Tailscale SSH
    ├── 30-docker-portainer.sh       # Docker + Portainer CE
    └── 40-close-openssh.sh          # отключение системного sshd
```
