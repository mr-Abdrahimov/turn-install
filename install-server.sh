#!/usr/bin/env bash
#
# install-server.sh — установщик серверной части vk-turn-proxy («Good TURN»)
#                     для Debian/Ubuntu VPS.
#
# Поднимает: AmneziaWG (внутренний VPN) + vk-turn server (транспорт через
# TURN-релеи VK) + systemd-сервис + firewall. После установки трафик клиента
# приходит на публичный порт 56000, расшифровывается и уходит в AmneziaWG
# (127.0.0.1:51820), а оттуда через NAT в интернет.
#
# Быстрый старт (одной командой):
#   bash <(curl -fsSL https://raw.githubusercontent.com/<you>/turn-install/main/install-server.sh)
#
# Или локально:  sudo bash install-server.sh
#
# Только для законного использования (обход цензуры/приватность на СВОИХ
# серверах и своих звонковых ссылках). Upstream: «только для учебных целей».

set -euo pipefail

# ----------------------------------------------------------------------------
# Значения по умолчанию (переопределяются флагами)
# ----------------------------------------------------------------------------
PROXY_PORT=56000                       # публичный порт vk-turn server (tcp+udp)
AWG_PORT=51820                         # локальный порт AmneziaWG на сервере
AWG_IF="awg0"
AWG_SUBNET="10.8.1.0/24"
AWG_SERVER_IP="10.8.1.1"
AWG_DIR="/etc/amnezia/amneziawg"
CORE_REPO="cacggghp/vk-turn-proxy"     # откуда брать server-linux-<arch>
BIN_PATH="/usr/local/bin/vk-turn-server"
SVC_NAME="vk-turn-server"
ASSUME_YES=0
CLIENT_NAME="router"

usage() {
  cat <<'EOF'
Использование: sudo bash install-server.sh [опции]

  --proxy-port N     публичный порт vk-turn server (по умолчанию 56000)
  --awg-port N       локальный порт AmneziaWG (по умолчанию 51820)
  --core-repo R      GitHub-репозиторий с релизами (по умолч. cacggghp/vk-turn-proxy)
  --client-name S    имя первого клиентского пира (по умолчанию router)
  -y, --yes          не задавать вопросов
  -h, --help         эта справка
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --proxy-port) PROXY_PORT="$2"; shift 2 ;;
    --awg-port)   AWG_PORT="$2"; shift 2 ;;
    --core-repo)  CORE_REPO="$2"; shift 2 ;;
    --client-name) CLIENT_NAME="$2"; shift 2 ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; usage; exit 1 ;;
  esac
done

# ----------------------------------------------------------------------------
# Утилиты вывода
# ----------------------------------------------------------------------------
c_grn='\033[1;32m'; c_yel='\033[1;33m'; c_red='\033[1;31m'; c_dim='\033[2m'; c_rst='\033[0m'
log()  { printf "${c_grn}==>${c_rst} %s\n" "$*"; }
warn() { printf "${c_yel}[!]${c_rst} %s\n" "$*" >&2; }
err()  { printf "${c_red}[ОШИБКА]${c_rst} %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ "$(id -u)" -eq 0 ] || err "Запусти от root:  sudo bash install-server.sh"

# ----------------------------------------------------------------------------
# Определение дистрибутива и архитектуры
# ----------------------------------------------------------------------------
. /etc/os-release 2>/dev/null || err "Не удалось прочитать /etc/os-release"
case "${ID:-}:${ID_LIKE:-}" in
  *debian*|*ubuntu*) : ;;
  *) warn "Дистрибутив '${ID:-?}' не Debian/Ubuntu — скрипт рассчитан на apt, возможны сбои." ;;
esac

detect_arch() {
  local a; a="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$a" in
    amd64|x86_64)  echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    armhf|armv7l|arm) echo "arm" ;;
    i386|i686|386) echo "386" ;;
    riscv64)       echo "riscv64" ;;
    *) err "Неизвестная архитектура '$a' — поддерживаются amd64/arm64/arm/386/riscv64" ;;
  esac
}
ARCH="$(detect_arch)"
log "Дистрибутив: ${PRETTY_NAME:-$ID}, архитектура: linux-${ARCH}"

# ----------------------------------------------------------------------------
# 1. Зависимости + IP forwarding
# ----------------------------------------------------------------------------
install_deps() {
  log "Устанавливаю зависимости (apt)…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    curl jq qrencode iproute2 iptables ca-certificates gnupg lsb-release \
    software-properties-common >/dev/null

  # включаем форвардинг пакетов (нужно для NAT из AmneziaWG в интернет)
  local sysctl_f=/etc/sysctl.d/99-vkturn-forward.conf
  cat > "$sysctl_f" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
  sysctl -p "$sysctl_f" >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
# 2. Установка AmneziaWG (ядровый DKMS-модуль + amneziawg-tools)
# ----------------------------------------------------------------------------
install_amneziawg() {
  if have awg && have awg-quick; then
    log "AmneziaWG уже установлен ($(awg --version 2>/dev/null | head -n1 || echo ok))"
    return
  fi
  log "Устанавливаю AmneziaWG…"

  # Путь A: официальный PPA (Ubuntu) / apt-репозиторий
  if [ "${ID:-}" = "ubuntu" ]; then
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1 || warn "Не удалось добавить ppa:amnezia/ppa"
    apt-get update -qq || true
    apt-get install -y -qq amneziawg amneziawg-tools 2>/dev/null || \
      apt-get install -y -qq amneziawg-dkms amneziawg-tools 2>/dev/null || true
  fi

  # Путь B (Debian или если PPA не дал бинарей): сборка из исходников через DKMS.
  if ! have awg; then
    warn "Ставлю AmneziaWG из исходников (DKMS). Нужны заголовки ядра и компилятор."
    apt-get install -y -qq git build-essential dkms \
      "linux-headers-$(uname -r)" >/dev/null 2>&1 || \
      apt-get install -y -qq git build-essential dkms linux-headers-amd64 >/dev/null 2>&1 || \
      warn "Не удалось поставить заголовки ядра — сборка модуля может упасть."

    local tmp; tmp="$(mktemp -d)"
    # amneziawg-tools (userspace: awg, awg-quick)
    git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-tools "$tmp/tools" >/dev/null 2>&1 \
      || err "Не удалось клонировать amneziawg-tools"
    make -C "$tmp/tools/src" >/dev/null 2>&1 && make -C "$tmp/tools/src" install >/dev/null 2>&1 \
      || err "Сборка amneziawg-tools не удалась"

    # ядровый модуль через DKMS
    git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-linux-kernel-module "$tmp/kmod" >/dev/null 2>&1 \
      || err "Не удалось клонировать amneziawg-linux-kernel-module"
    local ver="1.0.0"
    cp -r "$tmp/kmod/src" "/usr/src/amneziawg-$ver"
    if [ -f "/usr/src/amneziawg-$ver/dkms.conf" ] || [ -f "$tmp/kmod/dkms.conf" ]; then
      [ -f "/usr/src/amneziawg-$ver/dkms.conf" ] || cp "$tmp/kmod/dkms.conf" "/usr/src/amneziawg-$ver/"
      dkms add     "amneziawg/$ver" >/dev/null 2>&1 || true
      dkms build   "amneziawg/$ver" >/dev/null 2>&1 || warn "dkms build не удался"
      dkms install "amneziawg/$ver" >/dev/null 2>&1 || warn "dkms install не удался"
    fi
    modprobe amneziawg 2>/dev/null || warn "Модуль amneziawg не загрузился — проверь совместимость ядра."
    rm -rf "$tmp"
  fi

  have awg || err "AmneziaWG установить не удалось. Поставь вручную (см. github.com/amnezia-vpn) и запусти скрипт повторно."
}

# ----------------------------------------------------------------------------
# 3. Генерация серверного конфига AmneziaWG
# ----------------------------------------------------------------------------
# случайное целое в диапазоне [min,max] из /dev/urandom
rand_between() {
  local min="$1" max="$2" span n
  span=$(( max - min + 1 ))
  n=$(( 0x$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n') ))
  echo $(( min + (n % span) ))
}

gen_awg_server() {
  mkdir -p "$AWG_DIR"; chmod 700 "$AWG_DIR"
  local conf="$AWG_DIR/${AWG_IF}.conf"

  if [ -f "$conf" ]; then
    log "Серверный конфиг $conf уже существует — переиспользую."
    return
  fi

  log "Генерирую ключи и обфускацию AmneziaWG…"
  SRV_PRIV="$(awg genkey)"
  SRV_PUB="$(printf '%s' "$SRV_PRIV" | awg pubkey)"

  # Обфускация-параметры. Ограничения: H1..H4 различны и >4; S1 != S2; S1+56 != S2.
  JC="$(rand_between 3 10)"
  JMIN="$(rand_between 50 100)"
  JMAX="$(rand_between 400 700)"
  S1="$(rand_between 15 150)"
  S2="$(rand_between 15 150)"
  while [ "$S1" = "$S2" ] || [ $(( S1 + 56 )) = "$S2" ]; do S2="$(rand_between 15 150)"; done
  H1="$(rand_between 5 2000000000)"
  H2="$(rand_between 5 2000000000)"; while [ "$H2" = "$H1" ]; do H2="$(rand_between 5 2000000000)"; done
  H3="$(rand_between 5 2000000000)"; while [ "$H3" = "$H1" ] || [ "$H3" = "$H2" ]; do H3="$(rand_between 5 2000000000)"; done
  H4="$(rand_between 5 2000000000)"; while [ "$H4" = "$H1" ] || [ "$H4" = "$H2" ] || [ "$H4" = "$H3" ]; do H4="$(rand_between 5 2000000000)"; done

  # внешний интерфейс для NAT
  WAN_IF="$(ip -o -4 route show to default | awk '{print $5; exit}')"
  [ -n "$WAN_IF" ] || WAN_IF="eth0"

  umask 077
  cat > "$conf" <<EOF
[Interface]
Address = ${AWG_SERVER_IP}/24
ListenPort = ${AWG_PORT}
PrivateKey = ${SRV_PRIV}

# Обфускация AmneziaWG
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

# NAT: выпускаем трафик клиентов в интернет через ${WAN_IF}
PostUp   = iptables -t nat -A POSTROUTING -s ${AWG_SUBNET} -o ${WAN_IF} -j MASQUERADE; iptables -A FORWARD -i ${AWG_IF} -j ACCEPT; iptables -A FORWARD -o ${AWG_IF} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_SUBNET} -o ${WAN_IF} -j MASQUERADE; iptables -D FORWARD -i ${AWG_IF} -j ACCEPT; iptables -D FORWARD -o ${AWG_IF} -j ACCEPT
EOF
  chmod 600 "$conf"

  # сохраняем параметры для генерации клиентов
  cat > "$AWG_DIR/params.env" <<EOF
SRV_PUB=${SRV_PUB}
AWG_PORT=${AWG_PORT}
AWG_SERVER_IP=${AWG_SERVER_IP}
AWG_SUBNET=${AWG_SUBNET}
JC=${JC}
JMIN=${JMIN}
JMAX=${JMAX}
S1=${S1}
S2=${S2}
H1=${H1}
H2=${H2}
H3=${H3}
H4=${H4}
EOF
  chmod 600 "$AWG_DIR/params.env"

  systemctl enable "awg-quick@${AWG_IF}" >/dev/null 2>&1 || true
  systemctl restart "awg-quick@${AWG_IF}" || err "Не удалось поднять интерфейс ${AWG_IF} (awg-quick@${AWG_IF})"
  log "AmneziaWG-интерфейс ${AWG_IF} поднят на порту ${AWG_PORT}."
}

# ----------------------------------------------------------------------------
# 4. Скачивание бинарника vk-turn server
# ----------------------------------------------------------------------------
install_vkturn_bin() {
  log "Скачиваю vk-turn server (${CORE_REPO}, server-linux-${ARCH})…"
  local url
  url="$(curl -fsSL "https://api.github.com/repos/${CORE_REPO}/releases/latest" \
         | jq -r ".assets[] | select(.name==\"server-linux-${ARCH}\") | .browser_download_url" \
         | head -n1)"
  if [ -z "$url" ] || [ "$url" = "null" ]; then
    # запасной прямой путь к latest-ассету
    url="https://github.com/${CORE_REPO}/releases/latest/download/server-linux-${ARCH}"
    warn "Через API ассет не найден, пробую прямую ссылку: $url"
  fi
  curl -fSL --retry 3 -o "$BIN_PATH" "$url" || err "Не удалось скачать бинарник server-linux-${ARCH}"
  chmod +x "$BIN_PATH"
  log "Установлен: $BIN_PATH"
}

# ----------------------------------------------------------------------------
# 5. systemd-сервис vk-turn server
# ----------------------------------------------------------------------------
install_service() {
  log "Создаю systemd-сервис ${SVC_NAME}…"
  cat > "/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=vk-turn-proxy server (TURN transport -> AmneziaWG)
After=network-online.target awg-quick@${AWG_IF}.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN_PATH} -listen 0.0.0.0:${PROXY_PORT} -connect 127.0.0.1:${AWG_PORT}
Restart=always
RestartSec=3
LimitNOFILE=1048576
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SVC_NAME}" >/dev/null 2>&1 || true
  systemctl restart "${SVC_NAME}"
  sleep 1
  systemctl is-active --quiet "${SVC_NAME}" \
    && log "Сервис ${SVC_NAME} запущен на 0.0.0.0:${PROXY_PORT}." \
    || warn "Сервис ${SVC_NAME} не активен — смотри: journalctl -u ${SVC_NAME} -e"
}

# ----------------------------------------------------------------------------
# 6. Firewall: открыть только публичный порт proxy (tcp+udp)
# ----------------------------------------------------------------------------
setup_firewall() {
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    log "UFW активен — открываю ${PROXY_PORT}/tcp и /udp…"
    ufw allow "${PROXY_PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow "${PROXY_PORT}/udp" >/dev/null 2>&1 || true
  else
    log "UFW не активен — оставляю iptables как есть (порт ${PROXY_PORT} должен быть доступен извне)."
    warn "Если у провайдера есть внешний firewall/Security Group — открой ${PROXY_PORT} (tcp+udp) там."
  fi
}

# ----------------------------------------------------------------------------
# 7. Генерация клиентского пира (для роутера) + вывод параметров
# ----------------------------------------------------------------------------
add_client() {
  local name="$1"
  # shellcheck disable=SC1091
  . "$AWG_DIR/params.env"
  local conf="$AWG_DIR/${AWG_IF}.conf"
  local out="/root/awg-client-${name}.conf"

  local cpriv cpub cpsk cip
  cpriv="$(awg genkey)"
  cpub="$(printf '%s' "$cpriv" | awg pubkey)"
  cpsk="$(awg genpsk)"

  # выделяем следующий свободный IP .2, .3, … (берём 4-й октет из строк AllowedIPs пиров)
  local last
  last="$(grep -oE 'AllowedIPs = 10\.8\.1\.[0-9]+' "$conf" 2>/dev/null \
          | grep -oE '[0-9]+$' | sort -n | tail -n1)"
  [ -n "$last" ] || last=1
  cip="10.8.1.$(( last + 1 ))"

  # добавляем пир на сервер и применяем на живом интерфейсе
  cat >> "$conf" <<EOF

# client: ${name}
[Peer]
PublicKey = ${cpub}
PresharedKey = ${cpsk}
AllowedIPs = ${cip}/32
EOF
  awg set "${AWG_IF}" peer "${cpub}" preshared-key <(printf '%s' "$cpsk") allowed-ips "${cip}/32" 2>/dev/null || \
    systemctl restart "awg-quick@${AWG_IF}"

  local pubip
  pubip="$(curl -fsSL https://api.ipify.org 2>/dev/null || curl -fsSL https://ifconfig.me 2>/dev/null || echo '<SERVER_IP>')"

  # клиентский конфиг: Endpoint УЖЕ указывает на локальный vk-turn client (127.0.0.1:9000)!
  umask 077
  cat > "$out" <<EOF
[Interface]
PrivateKey = ${cpriv}
Address = ${cip}/24
MTU = 1280
DNS = 1.1.1.1

Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${SRV_PUB}
PresharedKey = ${cpsk}
# ВАЖНО: Endpoint = локальный vk-turn client, а НЕ публичный IP сервера!
Endpoint = 127.0.0.1:9000
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  echo
  log "Клиентский AmneziaWG-конфиг сохранён: ${out}"
  echo "----------------------------------------------------------------------"
  printf "  Публичный IP сервера : ${c_grn}%s${c_rst}\n" "$pubip"
  printf "  Порт vk-turn (proxy) : ${c_grn}%s${c_rst}\n" "$PROXY_PORT"
  printf "  Для роутера --peer    : ${c_grn}%s:%s${c_rst}\n" "$pubip" "$PROXY_PORT"
  echo "----------------------------------------------------------------------"
  if have qrencode; then
    echo "QR (для мобильного клиента AmneziaWG — но Endpoint надо указывать локальный):"
    qrencode -t ANSIUTF8 < "$out" || true
  fi
}

# ----------------------------------------------------------------------------
# 8. Утилита управления /usr/local/bin/vkturn
# ----------------------------------------------------------------------------
install_manager() {
  cat > /usr/local/bin/vkturn <<'MGR'
#!/usr/bin/env bash
set -euo pipefail
SVC="vk-turn-server"; AWG_IF="awg0"; AWG_DIR="/etc/amnezia/amneziawg"
case "${1:-}" in
  status)  systemctl status "$SVC" --no-pager || true; echo; awg show "$AWG_IF" || true ;;
  start)   systemctl start "$SVC"; systemctl start "awg-quick@${AWG_IF}" ;;
  stop)    systemctl stop "$SVC" ;;
  restart) systemctl restart "awg-quick@${AWG_IF}"; systemctl restart "$SVC" ;;
  logs)    journalctl -u "$SVC" -f ;;
  add-client)
    name="${2:-client-$(date +%s)}"
    # переиспользуем логику установщика при наличии
    echo "Добавь пир вручную командой awg, либо перезапусти install-server.sh --client-name $name"
    ;;
  uninstall)
    systemctl disable --now "$SVC" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SVC}.service" /usr/local/bin/vk-turn-server
    systemctl daemon-reload
    echo "vk-turn server удалён. AmneziaWG ($AWG_IF) НЕ тронут — удали вручную при желании."
    ;;
  *) echo "vkturn {status|start|stop|restart|logs|add-client <name>|uninstall}" ;;
esac
MGR
  chmod +x /usr/local/bin/vkturn
}

# ----------------------------------------------------------------------------
# Основной поток
# ----------------------------------------------------------------------------
main() {
  install_deps
  install_amneziawg
  gen_awg_server
  install_vkturn_bin
  install_service
  setup_firewall
  install_manager
  add_client "$CLIENT_NAME"

  echo
  log "Готово! Серверная часть vk-turn-proxy установлена."
  cat <<EOF

${c_dim}Что дальше:${c_rst}
  • Управление:            vkturn status | logs | restart
  • Клиентский конфиг:     /root/awg-client-${CLIENT_NAME}.conf
  • На роутере OpenWrt:    запусти install-openwrt.sh с
                             --peer <ПУБЛИЧНЫЙ_IP>:${PROXY_PORT}
                             --vk-link https://vk.com/call/join/XXXX
  • vk-turn client'у нужна ВАЛИДНАЯ ссылка на звонок VK (vk.com/call/join/…),
    из неё берутся TURN-креды. Сервер ссылку не хранит — она задаётся на клиенте.
EOF
}

main "$@"
