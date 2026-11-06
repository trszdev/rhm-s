#!/usr/bin/env bash
# Общие функции для всех шагов. Подключается через: source "<путь>/lib/common.sh"

set -Eeuo pipefail

if [[ -t 1 ]]; then
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_RESET=''
fi

log()  { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Запусти от root: sudo $0"
}

require_debian_like() {
  [[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) die "Поддерживаются только Ubuntu и Debian (найдено: ${PRETTY_NAME:-неизвестно})" ;;
  esac
  OS_ID="$ID"
  OS_CODENAME="${VERSION_CODENAME:-}"
  [[ -n "$OS_CODENAME" ]] || die "Не удалось определить VERSION_CODENAME"
  export OS_ID OS_CODENAME
}

apt_update()  { DEBIAN_FRONTEND=noninteractive apt-get update -q; }
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"; }

# IPv4 адрес этой машины в tailnet (пусто, если Tailscale не подключён)
tailscale_ip4() {
  command -v tailscale >/dev/null 2>&1 || return 0
  tailscale ip -4 2>/dev/null | head -n1 || true
}

# confirm "вопрос" → успех при ответе y/д. При ASSUME_YES=1 вопрос не задаётся.
confirm() {
  if [[ "${ASSUME_YES:-0}" == 1 ]]; then return 0; fi
  local answer=""
  read -r -p "$1 [y/N] " answer || true
  case "$answer" in
    y|Y|д|Д|да|Да|ДА) return 0 ;;
    *) return 1 ;;
  esac
}
