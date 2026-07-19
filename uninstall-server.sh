#!/usr/bin/env bash
#
# uninstall-server.sh — удаление серверной части vk-turn-proxy с Debian/Ubuntu.
# По умолчанию НЕ удаляет AmneziaWG (VPN) — для этого добавь --purge-awg.

set -euo pipefail

SVC_NAME="vk-turn-server"
BIN_PATH="/usr/local/bin/vk-turn-server"
AWG_IF="awg0"
AWG_DIR="/etc/amnezia/amneziawg"
PURGE_AWG=0
PROXY_PORT=56000

while [ $# -gt 0 ]; do
  case "$1" in
    --purge-awg) PURGE_AWG=1; shift ;;
    --proxy-port) PROXY_PORT="$2"; shift 2 ;;
    -h|--help) echo "Использование: sudo bash uninstall-server.sh [--purge-awg] [--proxy-port N]"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
[ "$(id -u)" -eq 0 ] || { echo "Запусти от root" >&2; exit 1; }

log "Останавливаю и удаляю сервис ${SVC_NAME}…"
systemctl disable --now "${SVC_NAME}" 2>/dev/null || true
rm -f "/etc/systemd/system/${SVC_NAME}.service" "$BIN_PATH" /usr/local/bin/vkturn
systemctl daemon-reload

log "Закрываю порт ${PROXY_PORT} в UFW (если активен)…"
if command -v ufw >/dev/null 2>&1; then
  ufw delete allow "${PROXY_PORT}/tcp" >/dev/null 2>&1 || true
  ufw delete allow "${PROXY_PORT}/udp" >/dev/null 2>&1 || true
fi

if [ "$PURGE_AWG" = "1" ]; then
  log "Удаляю AmneziaWG-интерфейс ${AWG_IF} и конфиги…"
  systemctl disable --now "awg-quick@${AWG_IF}" 2>/dev/null || true
  rm -rf "$AWG_DIR"
  echo "Пакеты amneziawg* оставлены — при желании: apt-get remove --purge amneziawg amneziawg-tools amneziawg-dkms"
else
  log "AmneziaWG (${AWG_IF}) оставлен нетронутым. Для полного удаления: --purge-awg"
fi

log "Готово."
