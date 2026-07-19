#!/bin/bash
# gen-entry.sh — генерирует /root/orangevpn-entry.json (запись сервера для списка
# OrangeVPN) из УЖЕ установленного AmneziaWG-сервера. Нужен для серверов, которые
# ставились до появления этой генерации в install-server.sh.
# Запуск на сервере:  bash gen-entry.sh
set -euo pipefail
P=/etc/amnezia/amneziawg/params.env
C=$(ls /root/awg-client-*.conf 2>/dev/null | head -1)
[ -f "$P" ] || { echo "нет $P"; exit 1; }
[ -n "$C" ] || { echo "нет клиентского конфига"; exit 1; }
. "$P"
priv=$(awk -F' = ' '/^PrivateKey/{print $2}' "$C")
addr=$(awk -F' = ' '/^Address/{print $2}' "$C")
psk=$(awk -F' = ' '/^PresharedKey/{print $2}' "$C")
ip=$(curl -fsSL --max-time 10 https://api.ipify.org || hostname -I | awk '{print $1}')
cat > /root/orangevpn-entry.json <<EOF
{
  "name": "$(hostname) (${ip})",
  "host": "${ip}",
  "awg": {
    "private_key": "${priv}",
    "address": "${addr}",
    "mtu": 1280,
    "jc": ${JC}, "jmin": ${JMIN}, "jmax": ${JMAX},
    "s1": ${S1}, "s2": ${S2}, "s3": 0, "s4": 0,
    "h1": ${H1}, "h2": ${H2}, "h3": ${H3}, "h4": ${H4},
    "peer_public_key": "${SRV_PUB}",
    "preshared_key": "${psk}",
    "keepalive": 25
  }
}
EOF
chmod 600 /root/orangevpn-entry.json
echo "OK ${ip}"
