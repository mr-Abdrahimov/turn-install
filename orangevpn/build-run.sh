#!/usr/bin/env bash
# build-run.sh — собирает ЕДИНЫЙ самораспаковывающийся установщик orangevpn-install.run
#
# Внутрь кладётся:
#   - setup.sh            (логика установки)
#   - files/...           (LuCI-плагин: menu.d, acl.d, view.js, rpcd-бэкенд, uci-конфиг)
#   - vkturn-client       (ПРОПАТЧЕННЫЙ бинарник клиента под нужную arch)
#
# Использование:
#   ./build-run.sh [путь-к-vkturn-client] [выходной-файл]
# По умолчанию берёт ../build/client-linux-arm64 (результат ../build-client.sh arm64).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLIENT="${1:-$HERE/../build/client-linux-arm64}"
OUT="${2:-$HERE/orangevpn-install.run}"
PAYLOAD="$HERE/payload"

log(){ printf '\033[1;32m==>\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ОШИБКА]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$HERE/installer-head.sh" ] || err "Нет installer-head.sh"
[ -f "$PAYLOAD/setup.sh" ]       || err "Нет payload/setup.sh"
[ -d "$PAYLOAD/files" ]          || err "Нет payload/files/"

if [ ! -f "$CLIENT" ]; then
  err "Не найден бинарник клиента: $CLIENT
Собери его сначала:  cd $HERE/.. && ./build-client.sh arm64
(или укажи путь: ./build-run.sh /путь/к/client-linux-<arch>)"
fi

# готовим временный payload-каталог (чтобы не тащить бинарник в git)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -a "$PAYLOAD/." "$TMP/"
cp "$CLIENT" "$TMP/vkturn-client"
chmod +x "$TMP/vkturn-client" "$TMP/setup.sh"
chmod 755 "$TMP/files/usr/libexec/rpcd/luci.orangevpn"

log "Содержимое пейлоада:"
( cd "$TMP" && find . -type f | sed 's/^\./  /' | sort )

# голова обязана заканчиваться строкой __PAYLOAD_BELOW__ + \n
tail -c 200 "$HERE/installer-head.sh" | grep -q '^__PAYLOAD_BELOW__$' \
  || err "installer-head.sh должен заканчиваться строкой __PAYLOAD_BELOW__"

log "Собираю $OUT …"
{
  cat "$HERE/installer-head.sh"
  ( cd "$TMP" && tar -czf - . )
} > "$OUT"
chmod +x "$OUT"

SIZE="$(wc -c < "$OUT" | tr -d ' ')"
log "Готово: $OUT ($(( SIZE / 1024 / 1024 )) МБ, $SIZE байт)"
cat <<EOF

Доставка на роутер (в dropbear нет sftp — через cat по ssh):
  cat "$OUT" | ssh root@192.168.1.1 'cat > /tmp/orangevpn-install.run'
  ssh root@192.168.1.1 'sh /tmp/orangevpn-install.run --url <URL_СПИСКА> --vk-link <VK_ССЫЛКА>'
EOF
