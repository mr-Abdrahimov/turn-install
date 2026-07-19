#!/bin/sh
# setup.sh — ставит всю систему OrangeVPN на OpenWrt (запускается из установщика,
# рядом лежат: ./vkturn-client (бинарник) и ./files/... (дерево файлов LuCI-плагина)).
# Идемпотентен: повторный запуск обновляет, не дублируя.
#
# Аргументы (все опциональны): --url <URL списка> --vk-link <ссылка VK> --iface <имя> --peer-ip <IP>
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
IFACE="OrangeVPN"
PEER_IP="10.8.1.1"
LIST_URL=""
VK_LINK=""

while [ $# -gt 0 ]; do
	case "$1" in
		--url)     LIST_URL="$2"; shift 2 ;;
		--vk-link) VK_LINK="$2";  shift 2 ;;
		--iface)   IFACE="$2";    shift 2 ;;
		--peer-ip) PEER_IP="$2";  shift 2 ;;
		*) shift ;;
	esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ОШИБКА]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || err "Запусти от root."
[ -f /etc/openwrt_release ] || warn "Не похоже на OpenWrt — procd-часть может не заработать."

# ---------- 0. проверка архитектуры ----------
DISTRIB_ARCH=""
[ -f /etc/openwrt_release ] && . /etc/openwrt_release 2>/dev/null || true
case "${DISTRIB_ARCH:-$(uname -m)}" in
	aarch64*|arm64*) ;;
	*) warn "Встроенный бинарник собран под aarch64, а тут '${DISTRIB_ARCH:-$(uname -m)}'." ;
	   warn "Клиент может не запуститься — пересобери build-client.sh под свою arch." ;;
esac

# ---------- 1. vk-turn client ----------
if [ -f "$HERE/vkturn-client" ]; then
	log "Ставлю vk-turn client…"
	/etc/init.d/vkturn stop 2>/dev/null || true
	killall vkturn-client 2>/dev/null || true
	sleep 1
	cp "$HERE/vkturn-client" /tmp/.vkc.new && chmod +x /tmp/.vkc.new
	mv -f /tmp/.vkc.new /usr/sbin/vkturn-client
	log "Клиент: /usr/sbin/vkturn-client ($(wc -c </usr/sbin/vkturn-client) байт)"
else
	warn "В пейлоаде нет vkturn-client — пропускаю (оставляю уже установленный)."
fi

# ---------- 2. конфиг клиента (сохраняем существующие значения) ----------
mkdir -p /etc/vkturn
if [ ! -f /etc/vkturn/vkturn.conf ]; then
	cat > /etc/vkturn/vkturn.conf <<'EOF'
PEER=""
LISTEN="127.0.0.1:9000"
THREADS="4"
LINK_ARG=""
EXTRA=""
EOF
fi
[ -n "$VK_LINK" ] && sed -i "s|^LINK_ARG=.*|LINK_ARG=\"-vk-link $VK_LINK\"|" /etc/vkturn/vkturn.conf
chmod 600 /etc/vkturn/vkturn.conf

# ---------- 3. procd-сервис клиента (прямой запуск — чистый restart) ----------
cat > /etc/init.d/vkturn <<'INIT'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
CONF=/etc/vkturn/vkturn.conf
start_service() {
  [ -f "$CONF" ] || { echo "vkturn: нет $CONF"; return 1; }
  killall vkturn-client 2>/dev/null
  . "$CONF"
  [ -n "$PEER" ] || { echo "vkturn: PEER не задан — выбери сервер в LuCI (VPN -> OrangeVPN)"; return 1; }
  procd_open_instance
  # shellcheck disable=SC2086
  procd_set_param command /usr/sbin/vkturn-client -peer "$PEER" $LINK_ARG -listen "$LISTEN" -n "$THREADS" $EXTRA
  procd_set_param respawn 3600 5 0
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
stop_service() { killall vkturn-client 2>/dev/null; }
INIT
chmod +x /etc/init.d/vkturn

# ---------- 4. watchdog (следит за $IFACE, авто-восстановление) ----------
cat > /usr/sbin/vkturn-watchdog <<WD
#!/bin/sh
# Восстанавливает туннель при обрыве (напр. reload zeroblock). Без капчи, пока
# клиент жив и креды в кэше. Клиента не трогает, если ждёт капчу.
IFACE="${IFACE}"
PEER_IP="${PEER_IP}"
POLL_OK=20; POLL_BAD=10; HARD_AFTER=18
LOG(){ logger -t vkturn-wd "\$*"; }
lan_ip(){ uci -q get network.lan.ipaddr 2>/dev/null || echo "<ip-роутера>"; }
tunnel_ok(){ ping -c1 -W3 "\$PEER_IP" >/dev/null 2>&1; }
client_running(){ pgrep -f "/usr/sbin/vkturn-client" >/dev/null 2>&1; }
captcha_pending(){ netstat -lnt 2>/dev/null | grep -q ":8765" || ss -lnt 2>/dev/null | grep -q ":8765"; }
LOG "watchdog запущен (iface=\$IFACE peer=\$PEER_IP)"
FAILS=0
while :; do
  if tunnel_ok; then
    [ "\$FAILS" -gt 0 ] && LOG "туннель восстановлен"; FAILS=0; sleep "\$POLL_OK"; continue
  fi
  if captcha_pending; then
    LOG "туннель down: ждёт КАПЧУ — открой https://\$(lan_ip):8765"; FAILS=0; sleep "\$POLL_BAD"; continue
  fi
  FAILS=\$((FAILS+1)); LOG "туннель down (fail #\$FAILS) — восстанавливаю"
  client_running || { LOG "client не запущен -> старт"; /etc/init.d/vkturn start 2>/dev/null; sleep 8; }
  ifup "\$IFACE" 2>/dev/null
  if [ "\$FAILS" -ge "\$HARD_AFTER" ] && client_running && ! captcha_pending; then
    LOG "долгий обрыв -> перезапуск клиента (может нужна капча https://\$(lan_ip):8765)"
    /etc/init.d/vkturn restart 2>/dev/null; FAILS=0
  fi
  sleep "\$POLL_BAD"
done
WD
chmod +x /usr/sbin/vkturn-watchdog

cat > /etc/init.d/vkturn-watchdog <<'WDI'
#!/bin/sh /etc/rc.common
START=97
STOP=10
USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command /usr/sbin/vkturn-watchdog
  procd_set_param respawn 3600 5 0
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
WDI
chmod +x /etc/init.d/vkturn-watchdog

# ---------- 5. hotplug: мгновенная реакция на возврат сети ----------
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-vkturn-recover <<HP
#!/bin/sh
[ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in
  wan|wan6|${IFACE}) ( sleep 3; ifup ${IFACE} 2>/dev/null ) & ;;
esac
HP
chmod +x /etc/hotplug.d/iface/99-vkturn-recover

# ---------- 6. LuCI-плагин ----------
log "Ставлю LuCI-плагин OrangeVPN…"
[ -d "$HERE/files" ] || err "В пейлоаде нет files/ — плагин не установить."
cp -a "$HERE/files/." /
chmod 755 /usr/libexec/rpcd/luci.orangevpn
# конфиг uci — не затирать существующий
[ -f /etc/config/orangevpn ] || cp "$HERE/files/etc/config/orangevpn" /etc/config/orangevpn
uci -q get orangevpn.settings >/dev/null 2>&1 || uci set orangevpn.settings=settings
[ -n "$LIST_URL" ] && uci set orangevpn.settings.url="$LIST_URL"
[ -n "$VK_LINK" ]  && uci set orangevpn.settings.vk_link="$VK_LINK"
uci commit orangevpn

# ---------- 7. миграция VKTURN -> OrangeVPN ----------
if [ "$IFACE" != "VKTURN" ] && uci -q get network.VKTURN >/dev/null 2>&1; then
	log "Нашёл старый интерфейс VKTURN — переношу настройки в $IFACE и убираю его."
	# перенести ключи/обфускацию, если $IFACE ещё не настроен
	if ! uci -q get network.${IFACE}.private_key >/dev/null 2>&1; then
		# ВАЖНО: секцию надо создать ДО установки её опций, иначе uci: Invalid argument
		uci set network.${IFACE}=interface
		uci set network.${IFACE}.proto='amneziawg'
		uci set network.${IFACE}.auto='1'
		for o in private_key mtu nohostroute awg_jc awg_jmin awg_jmax \
		         awg_s1 awg_s2 awg_s3 awg_s4 awg_h1 awg_h2 awg_h3 awg_h4; do
			v="$(uci -q get network.VKTURN.$o 2>/dev/null || true)"
			[ -n "$v" ] && uci set network.${IFACE}.$o="$v"
		done
		# addresses — это СПИСОК, переносим через add_list
		uci -q delete network.${IFACE}.addresses 2>/dev/null || true
		for a in $(uci -q get network.VKTURN.addresses 2>/dev/null || true); do
			uci add_list network.${IFACE}.addresses="$a"
		done
		# перенести peer
		OLDP="$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)=amneziawg_VKTURN$/\1/p" | head -1)"
		if [ -n "$OLDP" ]; then
			while uci -q delete "network.@amneziawg_${IFACE}[0]"; do :; done
			NP="$(uci add network "amneziawg_${IFACE}")"
			for o in public_key preshared_key endpoint_host endpoint_port persistent_keepalive; do
				v="$(uci -q get network.${OLDP}.$o || true)"
				[ -n "$v" ] && uci set network.${NP}.$o="$v"
			done
			uci -q delete network.${NP}.allowed_ips 2>/dev/null || true
			uci add_list network.${NP}.allowed_ips='0.0.0.0/0'
		fi
	fi
	ifdown VKTURN 2>/dev/null || true
	OLDP2="$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)=amneziawg_VKTURN$/\1/p")"
	for p in $OLDP2; do uci -q delete "network.$p" 2>/dev/null || true; done
	uci -q delete network.VKTURN 2>/dev/null || true
	uci commit network
fi

# ---------- 8. запуск ----------
/etc/init.d/vkturn enable  >/dev/null 2>&1 || true
/etc/init.d/vkturn-watchdog enable >/dev/null 2>&1 || true
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/ 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/vkturn-watchdog restart >/dev/null 2>&1 || true
# клиент стартуем только если уже выбран сервер
if grep -q '^PEER="[^"]\+"' /etc/vkturn/vkturn.conf 2>/dev/null; then
	/etc/init.d/vkturn restart >/dev/null 2>&1 || true
fi

log "Готово."
