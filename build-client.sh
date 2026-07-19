#!/usr/bin/env bash
#
# build-client.sh — собрать ПРОПАТЧЕННЫЙ vk-turn client (и server) из исходников.
#
# Зачем: релизный бинарник cacggghp/vk-turn-proxy (v1.8.3) не проходит новую капчу
# VK «Я Не Робот» (not_robot_captcha): парсер ParseVkCaptchaError отбраковывает ответ
# из-за отсутствия legacy-полей captcha_sid/captcha_img и НЕ доходит до встроенного
# решателя (auto → slider POC → manual), хотя тому нужны только redirect_uri+session_token.
# Патч patches/vk-captcha-not-robot.patch делает эти поля необязательными и поднимает
# таймаут ручной капчи 60с → 600с (чтобы успеть решить через браузер на headless-роутере).
#
# Требуется: Go (>=1.22). Кросс-компиляция чистого Go — без CGO, под любую arch роутера.
#
# Примеры:
#   ./build-client.sh                 # собрать client под linux/arm64 (по умолчанию)
#   ./build-client.sh mipsle          # под mipsle (ramips/mt76x8 и т.п.)
#   ./build-client.sh arm64 server    # собрать и client, и server под arm64
#   ./build-client.sh all             # все arch роутеров (arm64 arm mipsle mips mips64le)

set -euo pipefail

REPO="${CORE_REPO:-cacggghp/vk-turn-proxy}"
PIN="${PIN_COMMIT:-}"                       # напр. e8a9696…; пусто = main HEAD
ARCH_IN="${1:-arm64}"
WHAT="${2:-client}"                          # client | server | both
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/patches/vk-captcha-not-robot.patch"
OUT="$HERE/build"

log(){ printf '\033[1;32m==>\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[ОШИБКА]\033[0m %s\n' "$*" >&2; exit 1; }

command -v go >/dev/null || err "Нужен Go. macOS: brew install go ; Debian: apt install golang"
[ -f "$PATCH" ] || err "Не найден патч: $PATCH"

case "$ARCH_IN" in
  all) ARCHES="arm64 arm mipsle mips mips64le 386 amd64" ;;
  *)   ARCHES="$ARCH_IN" ;;
esac

SRC="$(mktemp -d)/vk-turn-proxy"
log "Клонирую $REPO…"
git clone --quiet "https://github.com/$REPO" "$SRC"
if [ -n "$PIN" ]; then
  git -C "$SRC" fetch --quiet --depth 1 origin "$PIN" && git -C "$SRC" checkout --quiet "$PIN"
fi
log "Применяю патч $(basename "$PATCH")…"
git -C "$SRC" apply --3way "$PATCH" || err "Патч не наложился (upstream мог измениться). Обнови patches/."

mkdir -p "$OUT"
build_one(){ # <goarch> <client|server>
  local ga="$1" comp="$2" gomips="" name="$comp-linux-$1"
  case "$ga" in mips|mipsle) gomips="softfloat" ;; esac
  log "Сборка $name…"
  ( cd "$SRC" && CGO_ENABLED=0 GOOS=linux GOARCH="$ga" ${gomips:+GOMIPS=$gomips} \
      go build -trimpath -ldflags="-s -w" -o "$OUT/$name" "./$comp" )
}

for ga in $ARCHES; do
  case "$WHAT" in
    client) build_one "$ga" client ;;
    server) build_one "$ga" server ;;
    both)   build_one "$ga" client; build_one "$ga" server ;;
    *) err "Второй аргумент: client | server | both" ;;
  esac
done

log "Готово. Бинарники в: $OUT"
ls -la "$OUT"
cat <<EOF

Доставка на роутер (dropbear без sftp — через cat по ssh):
  ssh root@ROUTER '/etc/init.d/vkturn stop'
  ssh root@ROUTER 'cat > /tmp/c && chmod +x /tmp/c && mv -f /tmp/c /usr/sbin/vkturn-client' < $OUT/client-linux-$ARCH_IN
  ssh root@ROUTER '/etc/init.d/vkturn restart'
EOF
