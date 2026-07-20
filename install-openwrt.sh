#!/bin/sh
#
# install-openwrt.sh — установка КЛИЕНТСКОГО транспорта vk-turn-proxy на роутер
#                     с прошивкой OpenWrt (busybox / procd).
#
# Ставит vk-turn client, который слушает 127.0.0.1:9000 и гонит UDP-трафик
# через TURN-релеи VK на твой VPS. К этой точке (127.0.0.1:9000) твоё
# приложение-роутер цепляет AmneziaWG/WireGuard-подключение (Endpoint,
# MTU 1280) и само раскидывает трафик LAN.
#
# Запуск на роутере:
#   sh install-openwrt.sh --peer <VPS_IP>:56000 --vk-link https://vk.com/call/join/XXXX
#
# Требуется: OpenWrt с интернетом на WAN и ~10 МБ свободного места во flash.

set -eu

# ---- значения по умолчанию ---------------------------------------------------
PEER=""
VK_LINK=""
YANDEX_LINK=""
LISTEN="127.0.0.1:9000"
THREADS="16"
USE_UDP="0"
EXTRA=""
CORE_REPO="cacggghp/vk-turn-proxy"
BIN_PATH="/usr/sbin/vkturn-client"
CONF_DIR="/etc/vkturn"
CONF="$CONF_DIR/vkturn.conf"

usage() {
  cat <<'EOF'
Использование: sh install-openwrt.sh [опции]

  --peer HOST:PORT     адрес vk-turn server на VPS (напр. 1.2.3.4:56000)   [обязательно]
  --vk-link URL        ссылка на звонок VK (https://vk.com/call/join/...)  [обязательно*]
  --yandex-link URL    ссылка Яндекс Телемост (альтернатива --vk-link)
  --listen ADDR        локальный адрес прослушки (по умолчанию 127.0.0.1:9000)
  --threads N          число параллельных потоков (-n, по умолчанию 16)
  --udp                UDP-режим (стабильнее для WG/AWG-хендшейка)
  --core-repo R        репозиторий релизов (по умолч. cacggghp/vk-turn-proxy)
  --extra "ARGS"       произвольные доп. флаги vk-turn client
  -h, --help           справка

  * нужна либо --vk-link, либо --yandex-link.
EOF
}

# читаем config.env рядом со скриптом (если есть). Из него берём SERVER_IP+PROXY_PORT
# (=> PEER), VK_LINK, THREADS, USE_UDP. Флаги ниже переопределяют.
_HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"
if [ -f "$_HERE/config.env" ]; then
  # shellcheck disable=SC1091
  . "$_HERE/config.env"
  [ -n "${SERVER_IP:-}" ] && PEER="${SERVER_IP}:${PROXY_PORT:-56000}"
  [ -n "${VK_LINK:-}" ] && VK_LINK="${VK_LINK}"
  [ -n "${THREADS:-}" ] && THREADS="${THREADS}"
  [ "${USE_UDP:-0}" = "1" ] && USE_UDP="1"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --peer)        PEER="$2"; shift 2 ;;
    --vk-link)     VK_LINK="$2"; shift 2 ;;
    --yandex-link) YANDEX_LINK="$2"; shift 2 ;;
    --listen)      LISTEN="$2"; shift 2 ;;
    --threads)     THREADS="$2"; shift 2 ;;
    --udp)         USE_UDP="1"; shift ;;
    --core-repo)   CORE_REPO="$2"; shift 2 ;;
    --extra)       EXTRA="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage; exit 1 ;;
  esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ОШИБКА]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ] || err "Запусти от root."
[ -f /etc/openwrt_release ] || warn "Похоже, это не OpenWrt — procd-часть может не заработать."

# ---- валидация обязательных параметров --------------------------------------
[ -n "$PEER" ] || { usage; err "Не задан --peer <VPS_IP>:56000"; }
if [ -z "$VK_LINK" ] && [ -z "$YANDEX_LINK" ]; then
  usage; err "Нужна --vk-link или --yandex-link"
fi

# ---- определение архитектуры OpenWrt ----------------------------------------
detect_arch() {
  DISTRIB_ARCH=""
  [ -f /etc/openwrt_release ] && . /etc/openwrt_release 2>/dev/null || true
  a="$DISTRIB_ARCH"
  [ -n "$a" ] || a="$(opkg print-architecture 2>/dev/null | grep -v -e ' all ' -e ' noarch ' \
                       | sort -k3 -n | tail -n1 | awk '{print $2}')"
  [ -n "$a" ] || a="$(uname -m)"
  case "$a" in
    x86_64)              echo "amd64" ;;
    i386_*|i486_*|i686*) echo "386" ;;
    aarch64*|arm64*)     echo "arm64" ;;
    arm_*|armv*|arm)     echo "arm" ;;
    mipsel_*|mipsel)     echo "mipsle" ;;
    mips_*|mips)         echo "mips" ;;
    mips64el_*|mips64le*) echo "mips64le" ;;
    riscv64*)            echo "riscv64" ;;
    *) err "Неизвестная arch OpenWrt: '$a'. Скачай client-linux-<arch> вручную из релизов ${CORE_REPO}." ;;
  esac
}
ARCH="$(detect_arch)"
log "Архитектура роутера: linux-${ARCH}"

# ---- проверка свободного места ----------------------------------------------
FREE_KB="$(df -k / 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "${FREE_KB:-}" ] && [ "$FREE_KB" -lt 12000 ]; then
  warn "Мало свободного места во flash (${FREE_KB} КБ). Бинарник ~8 МБ."
  warn "Рассмотри extroot (расширение на USB) — https://openwrt.org/docs/guide-user/additional-software/extroot_configuration"
fi

# ---- скачивание бинарника ----------------------------------------------------
# ca-bundle для https (best effort)
opkg list-installed 2>/dev/null | grep -q '^ca-bundle' || {
  opkg update >/dev/null 2>&1 && opkg install ca-bundle >/dev/null 2>&1 || \
    warn "Не удалось поставить ca-bundle — если скачивание упадёт, установи вручную: opkg install ca-bundle"
}

download() {
  # download <url> <out>
  url="$1"; out="$2"
  if have curl;          then curl -fSL --retry 3 -o "$out" "$url" && return 0; fi
  if have uclient-fetch; then uclient-fetch -O "$out" "$url" && return 0; fi
  if have wget;          then wget -O "$out" "$url" && return 0; fi
  return 1
}

URL="https://github.com/${CORE_REPO}/releases/latest/download/client-linux-${ARCH}"
log "Скачиваю vk-turn client: $URL"
TMP="$(mktemp 2>/dev/null || echo /tmp/vkturn-client.$$)"
download "$URL" "$TMP" || err "Скачивание не удалось. Проверь интернет/ca-bundle или скачай вручную в $BIN_PATH"
# простая проверка, что это бинарник, а не HTML-страница ошибки
if head -c4 "$TMP" | grep -q '<'; then
  rm -f "$TMP"; err "Скачался HTML вместо бинарника — вероятно нет ассета client-linux-${ARCH}. Проверь релизы ${CORE_REPO}."
fi
mv "$TMP" "$BIN_PATH"
chmod +x "$BIN_PATH"
log "Установлен бинарник: $BIN_PATH"

# ---- конфиг ------------------------------------------------------------------
mkdir -p "$CONF_DIR"
[ "$USE_UDP" = "1" ] && EXTRA="-udp $EXTRA"
LINK_ARG=""
[ -n "$VK_LINK" ]     && LINK_ARG="-vk-link $VK_LINK"
[ -n "$YANDEX_LINK" ] && LINK_ARG="-yandex-link $YANDEX_LINK"

cat > "$CONF" <<EOF
# Конфиг vk-turn client (читается /etc/init.d/vkturn)
PEER="$PEER"
LISTEN="$LISTEN"
THREADS="$THREADS"
LINK_ARG="$LINK_ARG"
EXTRA="$EXTRA"
EOF
chmod 600 "$CONF"
log "Конфиг записан: $CONF"

# ---- route-guard: пиним IP TURN/VPS через WAN-шлюз (против петли) ------------
cat > /usr/sbin/vkturn-routes <<'RG'
#!/bin/sh
# Читает stdout vk-turn client. Каждую строку пропускает дальше (для logread),
# а строки-«голый IPv4» дополнительно прописывает host-роутом через WAN-шлюз,
# чтобы собственный трафик клиента к VPS/TURN-релеям не уходил в туннель.

detect_wan_gw() {
  # берём default-route, НЕ через туннельный интерфейс (awg/wg/tun)
  ip -4 route show default 2>/dev/null | awk '
    $0 !~ /dev (awg|wg|tun|tailscale)/ {
      for (i=1;i<=NF;i++) if ($i=="via") { print $(i+1); exit }
    }'
}
GW="$(detect_wan_gw)"
[ -n "$GW" ] || echo "vkturn-routes: WAN-шлюз не найден, роуты пиниться не будут" >&2

while IFS= read -r line; do
  printf '%s\n' "$line"                       # pass-through -> logread
  ip=$(printf '%s' "$line" | tr -d '\r ')
  case "$ip" in
    ''|*[!0-9.]*) continue ;;                 # не чистый IPv4 — пропускаем
  esac
  echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || continue
  [ -n "$GW" ] || { GW="$(detect_wan_gw)"; [ -n "$GW" ] || continue; }
  ip route replace "$ip" via "$GW" 2>/dev/null
done
RG
chmod +x /usr/sbin/vkturn-routes

# ---- procd init-скрипт -------------------------------------------------------
cat > /etc/init.d/vkturn <<'INIT'
#!/bin/sh /etc/rc.common
# procd-сервис vk-turn client
START=95
STOP=10
USE_PROCD=1
CONF=/etc/vkturn/vkturn.conf

start_service() {
  [ -f "$CONF" ] || { echo "vkturn: нет $CONF"; return 1; }
  killall vkturn-client 2>/dev/null   # добить возможные зависшие процессы
  # shellcheck disable=SC1090
  . "$CONF"
  procd_open_instance
  # Клиент запускается НАПРЯМУЮ (без пайпа через sh -c), чтобы procd видел
  # настоящий PID и чисто убивал его при stop/restart. Иначе зависший клиент
  # держит 127.0.0.1:9000 и новый инстанс падает с "address already in use".
  # shellcheck disable=SC2086
  procd_set_param command /usr/sbin/vkturn-client -peer "$PEER" $LINK_ARG -listen "$LISTEN" -n "$THREADS" $EXTRA
  procd_set_param respawn 3600 5 0
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}

stop_service() {
  killall vkturn-client 2>/dev/null
}
INIT
chmod +x /etc/init.d/vkturn

# ---- утилита управления ------------------------------------------------------
cat > /usr/sbin/vkturn <<'MGR'
#!/bin/sh
CONF=/etc/vkturn/vkturn.conf
case "${1:-}" in
  start)   /etc/init.d/vkturn start ;;
  stop)    /etc/init.d/vkturn stop ;;
  restart) /etc/init.d/vkturn restart ;;
  status)  /etc/init.d/vkturn status 2>/dev/null; echo "--- routes ---"; ip route | grep -v default | grep ' via ' | head ;;
  logs)    logread -f -e vkturn ;;
  set-peer)    [ -n "${2:-}" ] && sed -i "s|^PEER=.*|PEER=\"$2\"|" "$CONF" && /etc/init.d/vkturn restart ;;
  set-link)    [ -n "${2:-}" ] && sed -i "s|^LINK_ARG=.*|LINK_ARG=\"-vk-link $2\"|" "$CONF" && /etc/init.d/vkturn restart ;;
  uninstall)
    /etc/init.d/vkturn disable 2>/dev/null
    /etc/init.d/vkturn stop 2>/dev/null
    rm -f /etc/init.d/vkturn /usr/sbin/vkturn-client /usr/sbin/vkturn-routes
    echo "vk-turn client удалён. Конфиг $CONF оставлен (удали вручную при желании)."
    ;;
  *) echo "vkturn {start|stop|restart|status|logs|set-peer HOST:PORT|set-link URL|uninstall}" ;;
esac
MGR
chmod +x /usr/sbin/vkturn

# ---- LAN-капча ---------------------------------------------------------------
# Пропатченный клиент отдаёт страницу капчи по HTTPS прямо на 0.0.0.0:8765
# (самоподписанный сертификат). Решать капчу: открыть https://<ip-роутера>:8765,
# принять предупреждение о сертификате, пройти чекбокс. HTTPS обязателен: страница
# использует crypto.subtle (PoW), доступный только в secure context — http по LAN
# им не является, а https (даже самоподписанный) — является. Отдельный шлюз не нужен.
log "Капчу решать по https://<ip-роутера>:8765 (принять самоподписанный серт)"

# ---- watchdog: авто-восстановление туннеля (напр. после reload zeroblock) ----
AWG_IFACE="${AWG_IFACE:-VKTURN}"
AWG_PEER_IP="${AWG_PEER_IP:-10.8.1.1}"
cat > /usr/sbin/vkturn-watchdog <<WD
#!/bin/sh
# Следит за туннелем и восстанавливает его при обрыве. По возможности БЕЗ капчи:
# мягко поднимает интерфейс; клиента перезапускает лишь как крайнюю меру и НИКОГДА
# во время ожидания капчи (иначе получится луп перезапросов к VK).
IFACE="${AWG_IFACE}"
PEER_IP="${AWG_PEER_IP}"
POLL_OK=20; POLL_BAD=10; HARD_AFTER=18
LOG(){ logger -t vkturn-wd "\$*"; }
lan_ip(){ uci -q get network.lan.ipaddr 2>/dev/null || echo "<ip-роутера>"; }
handshake_age(){
  hs="\$(awg show "\$IFACE" latest-handshakes 2>/dev/null | awk '{print \$2; exit}')"
  [ -n "\$hs" ] && [ "\$hs" -gt 0 ] 2>/dev/null || return 1
  echo \$(( \$(date +%s) - hs ))
}
# здоровье по возрасту handshake: ICMP через TURN теряется и даёт ложные срабатывания
tunnel_ok(){ age="\$(handshake_age)" && [ "\$age" -lt 200 ] && return 0; ping -c3 -W2 "\$PEER_IP" >/dev/null 2>&1; }
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
# hotplug: мгновенная реакция на возврат сети (WAN/VKTURN ifup)
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/99-vkturn-recover <<HP
#!/bin/sh
[ "\$ACTION" = "ifup" ] || exit 0
case "\$INTERFACE" in
  wan|wan6) ( sleep 5; ifup ${AWG_IFACE} 2>/dev/null ) & ;;
esac
HP
chmod +x /etc/hotplug.d/iface/99-vkturn-recover
/etc/init.d/vkturn-watchdog enable >/dev/null 2>&1 || true
/etc/init.d/vkturn-watchdog restart >/dev/null 2>&1 || true
log "Watchdog установлен: туннель авто-восстанавливается после обрывов (reload zeroblock и т.п.)"

# ---- запуск ------------------------------------------------------------------
/etc/init.d/vkturn enable  >/dev/null 2>&1 || true
/etc/init.d/vkturn restart

sleep 2
echo
log "Готово! vk-turn client установлен и запущен."
cat <<EOF

Проверка подключения:
  logread -e vkturn        # ждём строку 'Established DTLS connection!'
  vkturn status

Дальше — в твоём приложении-роутере (AmneziaWG/WireGuard) укажи для этого сервера:
  Endpoint  = ${LISTEN}          (локальный vk-turn client, НЕ публичный IP!)
  MTU       = 1280               (при проблемах с фрагментацией — 1240)
  PublicKey / ключи / обфускацию (Jc,Jmin,Jmax,S1,S2,H1..H4) — из awg-client-*.conf с сервера

ВАЖНО: включай туннель ТОЛЬКО после 'Established DTLS connection!'.
Если хендшейк AmneziaWG не проходит — переустанови с флагом --udp.
Подробности: docs/openwrt-amneziawg.md

*** КАПЧА VK ***
Этот бинарник — релизный (v1.8.3) и НЕ проходит новую капчу VK «Я Не Робот»
(в логах: 'missing captcha_sid' по кругу). Нужен ПРОПАТЧЕННЫЙ клиент:
собери его через build-client.sh и подмени /usr/sbin/vkturn-client.
Капчу всё равно придётся решать вручную через браузер (ssh -L 8765:localhost:8765).
Подробности: docs/captcha-manual.md
EOF
