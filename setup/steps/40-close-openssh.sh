#!/usr/bin/env bash
# Шаг 4. Отключить системный OpenSSH-сервер (порт 22). Дальше вход только через Tailscale SSH.
#
# Что делает:
#   - останавливает, отключает и маскирует ssh.service / ssh.socket;
#   - удаляет пакет openssh-server (клиент ssh остаётся).
#
# Защита от самоблокировки:
#   - требует подключённый Tailscale с включённым Tailscale SSH;
#   - отказывается работать, если есть активные SSH-подключения к порту 22
#     (они оборвутся), кроме случая FORCE=1;
#   - спрашивает подтверждение (ASSUME_YES=1 пропускает вопрос).

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
require_debian_like

[[ -n "$(tailscale_ip4)" ]] || die "Tailscale не подключён. Сначала запусти шаг tailscale."

PREFS="$(tailscale debug prefs 2>/dev/null || true)"
grep -Eq '"RunSSH":[[:space:]]*true' <<<"$PREFS" \
  || die "Tailscale SSH не включён. Сначала запусти шаг tailscale."

ACTIVE="$(ss -Htn state established '( sport = :22 )' 2>/dev/null | wc -l)"
if (( ACTIVE > 0 )) && [[ "${FORCE:-0}" != 1 ]]; then
  die "Есть активные SSH-подключения к порту 22 (${ACTIVE} шт.). Они оборвутся. Зайди через tailscale ssh, закрой их и запусти снова (или FORCE=1)."
fi

warn "Будут остановлены и удалены системный sshd (openssh-server) и сокет ssh.socket. Клиент ssh останется."
warn "ПЕРЕД этим проверь вход с другого устройства: tailscale ssh <пользователь>@$(hostname -s)"
confirm "Отключить системный OpenSSH?" || die "Отменено пользователем"

log "Останавливаю и маскирую ssh.service / ssh.socket"
systemctl disable --now ssh.service ssh.socket 2>/dev/null || true
systemctl mask ssh.service ssh.socket
systemctl daemon-reload

if dpkg -s openssh-server >/dev/null 2>&1; then
  log "Удаляю пакет openssh-server"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -q openssh-server
fi

LISTENING="$(ss -Hltn '( sport = :22 )' 2>/dev/null || true)"
if [[ -n "$LISTENING" ]]; then
  warn "Порт 22 всё ещё слушается. Проверь: ss -ltnp '( sport = :22 )'"
else
  ok "Порт 22 больше не слушается"
fi

ok "Системный OpenSSH отключён. Доступ: tailscale ssh <пользователь>@$(hostname -s)"
