#!/bin/sh
# ============================================================================
#  OrangeVPN — единый установщик для OpenWrt (самораспаковывающийся)
#
#  Ставит ВСЁ: пропатченный vk-turn client (HTTPS-капча), procd-сервисы,
#  watchdog авто-восстановления, hotplug-хук и LuCI-плагин «OrangeVPN»
#  (раздел VPN): список серверов с пингом, выбор сервера в один клик.
#
#  Запуск на роутере:
#     sh orangevpn-install.run
#     sh orangevpn-install.run --url https://.../orangevpn.json --vk-link https://vk.ru/call/join/XXX
#
#  Опции: --url <URL списка>  --vk-link <ссылка VK>  --iface <имя, по умолч. OrangeVPN>
#         --peer-ip <AWG-IP сервера, по умолч. 10.8.1.1>  -h|--help
# ============================================================================
set -eu

LIST_URL=""; VK_LINK=""; IFACE="OrangeVPN"; PEER_IP="10.8.1.1"

while [ $# -gt 0 ]; do
	case "$1" in
		--url)     LIST_URL="$2"; shift 2 ;;
		--vk-link) VK_LINK="$2";  shift 2 ;;
		--iface)   IFACE="$2";    shift 2 ;;
		--peer-ip) PEER_IP="$2";  shift 2 ;;
		-h|--help)
			sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
	esac
done

c_g='\033[1;32m'; c_y='\033[1;33m'; c_r='\033[1;31m'; c_0='\033[0m'
log()  { printf "${c_g}==>${c_0} %s\n" "$*"; }
warn() { printf "${c_y}[!]${c_0} %s\n" "$*" >&2; }
err()  { printf "${c_r}[ОШИБКА]${c_0} %s\n" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || err "Запусти от root:  sh $0"

echo
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   OrangeVPN — установка на OpenWrt        ║"
echo "  ╚══════════════════════════════════════════╝"
echo

# ---- интерактивный опрос, если параметры не заданы и есть терминал ----
if [ -z "$LIST_URL" ] && [ -t 0 ]; then
	echo "Укажи ССЫЛКУ НА СПИСОК СЕРВЕРОВ (JSON с твоего сервера)."
	echo "Пример: http://1.2.3.4:8088/<секрет>/orangevpn.json"
	printf "URL списка: "
	read -r LIST_URL || true
fi
if [ -z "$VK_LINK" ] && [ -t 0 ]; then
	echo
	echo "Укажи ССЫЛКУ НА ЗВОНОК VK (из неё берутся TURN-креды)."
	echo "Создать: VK -> Звонки -> Создать звонок -> Копировать ссылку (звонок можно не начинать)."
	printf "VK-ссылка (Enter — пропустить): "
	read -r VK_LINK || true
fi

# ---- распаковка пейлоада ----
WORKDIR="$(mktemp -d /tmp/orangevpn.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

ARCHIVE="$(awk '/^__PAYLOAD_BELOW__/{print NR+1; exit}' "$0")"
[ -n "$ARCHIVE" ] || err "Пейлоад не найден (файл повреждён?)."

log "Распаковываю…"
if ! tail -n +"$ARCHIVE" "$0" | tar -xzf - -C "$WORKDIR" 2>/dev/null; then
	tail -n +"$ARCHIVE" "$0" | gzip -dc | tar -xf - -C "$WORKDIR" \
		|| err "Не удалось распаковать пейлоад."
fi
[ -f "$WORKDIR/setup.sh" ] || err "В пейлоаде нет setup.sh."
chmod +x "$WORKDIR/setup.sh"

# ---- установка ----
sh "$WORKDIR/setup.sh" \
	${LIST_URL:+--url "$LIST_URL"} \
	${VK_LINK:+--vk-link "$VK_LINK"} \
	--iface "$IFACE" --peer-ip "$PEER_IP"

LAN_IP="$(uci -q get network.lan.ipaddr 2>/dev/null || echo '192.168.1.1')"
cat <<EOF

=== Установка завершена ===

  1) Открой LuCI:  http://${LAN_IP}/  ->  раздел  VPN -> OrangeVPN
     Там список серверов с пингом; лучший отмечен ★.
  2) Нажми «Подключить» у нужного сервера — он применится к интерфейсу ${IFACE}.
  3) Если попросит капчу — открой  https://${LAN_IP}:8765
     (прими самоподписанный сертификат, пройди «Я не робот»).

  Логи:      logread -e vkturn ; logread -e vkturn-wd
  Состояние: ubus call luci.orangevpn status
EOF
exit 0
__PAYLOAD_BELOW__
