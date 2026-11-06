#!/usr/bin/env bash
# Шаг 1. Автоматические обновления безопасности и перезагрузка при необходимости.
#
# Что делает:
#   - ставит unattended-upgrades;
#   - раз в день проверяет списки пакетов и ставит обновления безопасности;
#   - ставит обновления пакетов docker-ce и tailscale из их репозиториев
#     (origin/label взяты из Release-файлов download.docker.com и pkgs.tailscale.com);
#   - перезагружает машину в REBOOT_TIME, но ТОЛЬКО если после обновления
#     появился /var/run/reboot-required (обновились ядро, libc и т.п.);
#   - удаляет неиспользуемые старые ядра.
#
# Шаг можно запускать до установки Docker и Tailscale: правило просто ждёт их репозиториев.
#
# Переменные окружения:
#   REBOOT_TIME  время возможной перезагрузки, HH:MM (по умолчанию 04:00)

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

require_root
require_debian_like

REBOOT_TIME="${REBOOT_TIME:-04:00}"
if [[ ! "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  die "REBOOT_TIME должен быть в формате HH:MM, получено: $REBOOT_TIME"
fi

log "Устанавливаю unattended-upgrades"
apt_update
apt_install unattended-upgrades

# Отдельный файл с суффиксом 52 читается после файлов дистрибутива и переопределяет их.
CONF=/etc/apt/apt.conf.d/52self-host-upgrades
log "Пишу $CONF"
cat > "$CONF" <<EOF
// Управляется setup/steps/10-unattended-upgrades.sh. Для изменений перезапусти шаг.

// Проверка списков пакетов и установка обновлений раз в день
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";

// Автоперезагрузка только если она нужна (/var/run/reboot-required)
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "${REBOOT_TIME}";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";

// Уборка старых ядер и зависимостей
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";

// Сторонние репозитории: Docker CE и Tailscale (origin/label из их Release-файлов).
// Оператор :: добавляет элементы к списку, не затирая Origins-Pattern из 50unattended-upgrades.
Unattended-Upgrade::Origins-Pattern:: "origin=Docker,label=Docker CE";
Unattended-Upgrade::Origins-Pattern:: "origin=Tailscale,label=Tailscale";

Unattended-Upgrade::SyslogEnable "true";
EOF
chmod 0644 "$CONF"

log "Включаю таймеры и сервис"
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
systemctl enable --now unattended-upgrades.service

log "Проверяю итоговую конфигурацию apt"
APT_DUMP="$(apt-config dump)"
grep -q 'Unattended-Upgrade::Automatic-Reboot "true"' <<<"$APT_DUMP" \
  || die "Автоперезагрузка не включилась. Смотри $CONF"
grep -q "Unattended-Upgrade::Automatic-Reboot-Time \"${REBOOT_TIME}\"" <<<"$APT_DUMP" \
  || die "Время перезагрузки не применилось. Смотри $CONF"
grep -q 'origin=Docker,label=Docker CE' <<<"$APT_DUMP" \
  || die "Правило для Docker не попало в конфиг. Смотри $CONF"
grep -q 'origin=Tailscale,label=Tailscale' <<<"$APT_DUMP" \
  || die "Правило для Tailscale не попало в конфиг. Смотри $CONF"

ok "unattended-upgrades настроен: безопасность, docker-ce и tailscale ежедневно, перезагрузка в ${REBOOT_TIME} при необходимости"
