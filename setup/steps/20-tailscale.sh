#!/usr/bin/env bash
# Шаг 2. Tailscale + Tailscale SSH.
#
# Переменные окружения:
#   TS_AUTHKEY   auth key из админки Tailscale (необязательно; без него появится ссылка для входа)
#   TS_HOSTNAME  имя машины в tailnet (по умолчанию — короткое имя хоста)

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
require_debian_like

TS_HOSTNAME="${TS_HOSTNAME:-$(hostname -s)}"

apt_update
apt_install curl ca-certificates

log "Добавляю официальный репозиторий Tailscale (${OS_ID} ${OS_CODENAME})"
install -d -m 0755 /usr/share/keyrings
curl -fsSL "https://pkgs.tailscale.com/stable/${OS_ID}/${OS_CODENAME}.noarmor.gpg" \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL "https://pkgs.tailscale.com/stable/${OS_ID}/${OS_CODENAME}.tailscale-keyring.list" \
  -o /etc/apt/sources.list.d/tailscale.list

apt_update
apt_install tailscale
systemctl enable --now tailscaled

if [[ -n "$(tailscale_ip4)" ]]; then
  ok "Tailscale уже подключён, IP: $(tailscale_ip4)"
  log "Включаю Tailscale SSH"
  tailscale set --ssh
elif [[ -n "${TS_AUTHKEY:-}" ]]; then
  log "Подключаю Tailscale по auth key (hostname: $TS_HOSTNAME)"
  tailscale up --ssh --hostname="$TS_HOSTNAME" --auth-key="$TS_AUTHKEY"
else
  warn "TS_AUTHKEY не задан: сейчас появится ссылка, открой её и авторизуй машину"
  tailscale up --ssh --hostname="$TS_HOSTNAME"
fi

log "Обновления tailscale ставит unattended-upgrades (шаг upgrades)"

[[ -n "$(tailscale_ip4)" ]] || die "Tailscale не подключился (нет IPv4 в tailnet). Проверь: tailscale status"

PREFS="$(tailscale debug prefs 2>/dev/null || true)"
grep -Eq '"RunSSH":[[:space:]]*true' <<<"$PREFS" \
  || die "Tailscale SSH не включён (RunSSH != true). Проверь: tailscale debug prefs. OpenSSH пока не трогаем."

ok "Tailscale SSH включён. IP в tailnet: $(tailscale_ip4)"
warn "Проверь вход с другого устройства ДО шага close-ssh: tailscale ssh <пользователь>@${TS_HOSTNAME}"
warn "Если tailnet ACL ограничивает SSH, разреши его в админке Tailscale (Access controls)."
