#!/usr/bin/env bash
# Настройка self-host машины (Debian / Ubuntu).
#
# Использование:
#   sudo ./install.sh                    # все шаги по порядку
#   sudo ./install.sh tailscale docker   # только выбранные шаги
#
# Шаги: upgrades, tailscale, docker, close-ssh
# Переменные окружения описаны в setup/README.md

set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"

require_root

declare -A STEP_FILE=(
  [upgrades]=10-unattended-upgrades.sh
  [tailscale]=20-tailscale.sh
  [docker]=30-docker-portainer.sh
  [close-ssh]=40-close-openssh.sh
)
ALL_STEPS=(upgrades tailscale docker close-ssh)

if [[ $# -eq 0 || "$1" == all ]]; then
  selected=("${ALL_STEPS[@]}")
else
  selected=("$@")
fi

for step in "${selected[@]}"; do
  [[ -n "${STEP_FILE[$step]:-}" ]] || die "Неизвестный шаг: $step (доступны: ${ALL_STEPS[*]})"
done

for step in "${selected[@]}"; do
  log "=== Шаг: $step"
  bash "$DIR/steps/${STEP_FILE[$step]}"
  ok "Шаг $step завершён"
done

ok "Готово"
