#!/usr/bin/env bash
# Шаг 3. Docker Engine (из официального репозитория Docker) + Portainer CE.
#
# Переменные окружения:
#   PORTAINER_BIND   IP, на котором слушает Portainer (по умолчанию — tailnet IP этой машины,
#                    иначе 127.0.0.1). 0.0.0.0 задавай только осознанно: Docker публикует
#                    порты в обход ufw.
#   PORTAINER_IMAGE  образ Portainer (по умолчанию portainer/portainer-ce:lts)

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
require_debian_like

PORTAINER_IMAGE="${PORTAINER_IMAGE:-portainer/portainer-ce:lts}"

# 1. Удаляем пакеты из дистрибутива, которые конфликтуют с docker-ce
CONFLICTS=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
REMOVE=()
for pkg in "${CONFLICTS[@]}"; do
  if dpkg -s "$pkg" >/dev/null 2>&1; then REMOVE+=("$pkg"); fi
done
if (( ${#REMOVE[@]} > 0 )); then
  log "Удаляю конфликтующие пакеты: ${REMOVE[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get remove -y -q "${REMOVE[@]}"
fi

# 2. Официальный репозиторий Docker
apt_update
apt_install ca-certificates curl

log "Добавляю официальный репозиторий Docker (${OS_ID} ${OS_CODENAME})"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/${OS_ID}
Suites: ${OS_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt_update
apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
docker info >/dev/null
ok "Docker установлен: $(docker --version)"

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  usermod -aG docker "$SUDO_USER"
  warn "Пользователь $SUDO_USER добавлен в группу docker. Это почти то же, что root. Переподключись, чтобы группа применилась."
fi

# 3. Portainer CE
TS_IP="$(tailscale_ip4)"
if [[ -n "${PORTAINER_BIND:-}" ]]; then
  BIND="$PORTAINER_BIND"
elif [[ -n "$TS_IP" ]]; then
  BIND="$TS_IP"
else
  BIND="127.0.0.1"
  warn "Tailscale не подключён: Portainer слушает только 127.0.0.1. Задай PORTAINER_BIND, чтобы открыть доступ."
fi

log "Запускаю Portainer (${PORTAINER_IMAGE}) на ${BIND}:9443"
docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
if docker container inspect portainer >/dev/null 2>&1; then
  log "Контейнер portainer уже есть, пересоздаю (данные лежат в volume portainer_data)"
  docker rm -f portainer >/dev/null
fi
docker pull -q "$PORTAINER_IMAGE" >/dev/null
docker run -d \
  --name portainer \
  --restart=always \
  -p "${BIND}:9443:9443" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  "$PORTAINER_IMAGE" >/dev/null

CHECK_HOST="$BIND"
[[ "$BIND" == "0.0.0.0" ]] && CHECK_HOST="127.0.0.1"

log "Жду готовности Portainer"
ready=0
for _ in $(seq 1 30); do
  if curl -ksf --max-time 3 "https://${CHECK_HOST}:9443/api/system/status" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
(( ready == 1 )) || die "Portainer не ответил за 60 секунд. Смотри: docker logs portainer"

ok "Portainer доступен: https://${CHECK_HOST}:9443 (сертификат самоподписанный)"
warn "Открой Portainer и СРАЗУ создай admin-пользователя. Если не успеть примерно за 5 минут, Portainer закроет форму. Тогда выполни: docker restart portainer"
