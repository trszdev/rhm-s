#!/usr/bin/env bash
# Шаг 3. Docker Engine (из официального репозитория Docker) + Portainer за Tailscale HTTPS.
#
# Portainer запускается стеком setup/docker/docker-compose.yml:
#   - контейнер ts — отдельный узел tailnet с именем PORTAINER_TS_HOSTNAME;
#   - контейнер portainer живёт в сети ts и не публикует порты;
#   - tailscale serve отдаёт https://<имя>.<tailnet>.ts.net с сертификатом Tailscale.
#
# Переменные окружения:
#   TS_AUTHKEY             auth key для контейнера ts. Нужен, если setup/docker/.env ещё нет.
#                          Одноразовый ключ уже мог быть использован шагом tailscale,
#                          поэтому для контейнера лучше reusable-ключ или отдельный ключ.
#   PORTAINER_TS_HOSTNAME  имя Portainer в tailnet (по умолчанию portainer).
#                          Не используй то же имя, что у хоста: это два разных узла.

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
require_debian_like

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" && pwd)"
ENV_FILE="$STACK_DIR/.env"
PORTAINER_TS_HOSTNAME="${PORTAINER_TS_HOSTNAME:-portainer}"

compose() { docker compose -f "$STACK_DIR/docker-compose.yml" "$@"; }

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

# 3. Файл .env для стека (секрет, права 600)
if [[ -f "$ENV_FILE" ]]; then
  if grep -q 'REPLACE_ME' "$ENV_FILE"; then
    die "В $ENV_FILE остался плейсхолдер REPLACE_ME. Впиши настоящий TS_AUTHKEY или удали файл и задай TS_AUTHKEY в окружении."
  fi
  log "Использую существующий $ENV_FILE"
else
  [[ -n "${TS_AUTHKEY:-}" ]] || die "Нет $ENV_FILE и не задан TS_AUTHKEY. Задай TS_AUTHKEY или создай .env из .env.example."
  log "Создаю $ENV_FILE (права 600)"
  (
    umask 077
    cat > "$ENV_FILE" <<EOF
# Создано setup/steps/30-docker-portainer.sh. Не коммить.
TS_AUTHKEY=${TS_AUTHKEY}
TS_HOSTNAME=${PORTAINER_TS_HOSTNAME}
EOF
  )
fi
chmod 600 "$ENV_FILE"

# 4. Старый контейнер portainer из прошлой версии скрипта (не из compose) мешает стеку
if docker container inspect portainer >/dev/null 2>&1; then
  warn "Найден контейнер portainer из прошлой версии. Удаляю его. Его volume portainer_data сохраняется, но новый стек использует свой volume selfhost_portainer_data и начинается с чистого листа."
  docker rm -f portainer >/dev/null
fi

# 5. Запуск стека
log "Запускаю стек Portainer (docker compose)"
compose pull --quiet
compose up -d

log "Жду, пока контейнер ts подключится к tailnet"
ready=0
for _ in $(seq 1 45); do
  if [[ -n "$(compose exec -T ts tailscale ip -4 2>/dev/null || true)" ]]; then
    ready=1
    break
  fi
  sleep 2
done
(( ready == 1 )) || die "Контейнер ts не подключился к tailnet за 90 секунд. Смотри: docker compose -f $STACK_DIR/docker-compose.yml logs ts"

# 6. Проверка serve и вывод адреса
SERVE_STATUS="$(compose exec -T ts tailscale serve status 2>/dev/null || true)"
if grep -q '127.0.0.1:9443' <<<"$SERVE_STATUS"; then
  ok "tailscale serve проксирует на Portainer"
else
  warn "serve не настроен (плейсхолдер \${TS_CERT_DOMAIN} не сработал?). Выполни вручную: docker compose -f $STACK_DIR/docker-compose.yml exec ts tailscale serve --bg --https=443 https+insecure://127.0.0.1:9443"
fi

DNS_NAME="$(compose exec -T ts tailscale status --json 2>/dev/null \
  | grep -o '"DNSName": *"[^"]*"' | head -n1 | sed -E 's/.*"([^"]*)"$/\1/' || true)"
if [[ -n "$DNS_NAME" ]]; then
  ok "Portainer: https://${DNS_NAME%.}"
  warn "Открой адрес и сразу создай admin-пользователя при первом входе."
else
  warn "Не удалось прочитать DNS-имя. Проверь: docker compose -f $STACK_DIR/docker-compose.yml exec ts tailscale status"
fi
