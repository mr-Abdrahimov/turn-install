# turn-install

Установщики для **[vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy)** («Good TURN») —
инструмента обхода блокировок, который туннелирует VPN-трафик через **TURN-релеи звонков
VK / Яндекс Телемост**. Пакеты оборачиваются в DTLS 1.2 и STUN ChannelData, поэтому для DPI
трафик выглядит как обычный видеозвонок.

Здесь два готовых скрипта: один поднимает **серверную часть** на Debian/Ubuntu VPS, второй
ставит **клиентский транспорт** на роутер с **OpenWrt**. Внутренний VPN — **AmneziaWG**.

> ⚠️ **Ответственное использование.** Инструмент предназначен для обхода цензуры и защиты
> приватности на **своих** серверах и со **своими** звонковыми ссылками. Upstream помечает
> проект «только для учебных целей». Соблюдай законы своей юрисдикции.

> 🔴 **Важно про капчу VK.** Релизный клиент (v1.8.3) НЕ проходит новую капчу VK «Я Не Робот».
> Нужен **пропатченный** клиент (`build-client.sh`, патч `patches/vk-captcha-not-robot.patch`), и
> даже с ним капча решается **вручную через браузер** при каждой (пере)авторизации — полностью
> автоматического headless-режима сейчас нет. См. **[docs/captcha-manual.md](docs/captcha-manual.md)**.
> Проверено на живом стенде: сервер Ubuntu 24.04 + роутер OpenWrt (aarch64) — сквозной туннель
> поднимается, внешний IP через туннель = IP сервера.

## Архитектура

```
[LAN] → AmneziaWG(awg0) ──► 127.0.0.1:9000 (vk-turn client) ──► DTLS/TURN через релеи VK ──►
        │                                                                                    │
        │  Endpoint=127.0.0.1:9000, MTU=1280                                                 ▼
        └─────────────────────────────────────  VPS: vk-turn server (:56000)
                                                 └─► 127.0.0.1:51820 (AmneziaWG server) ─► NAT ─► интернет
```

- **vk-turn client** прячет UDP-трафик AmneziaWG в звонки VK и отправляет на VPS.
- **vk-turn server** принимает на публичном порту `56000`, расшифровывает и отдаёт локальному
  AmneziaWG (`127.0.0.1:51820`), а тот через NAT выпускает в интернет.
- Наружу открыт **только порт 56000** (tcp+udp). Порт AmneziaWG не публикуется.

## Быстрый старт

### 1. Сервер (Debian/Ubuntu VPS)

```bash
sudo bash install-server.sh
# или с параметрами:
sudo bash install-server.sh --proxy-port 56000 --awg-port 51820 --client-name router -y
```

Скрипт:
1. ставит зависимости и **AmneziaWG** (DKMS-модуль + `amneziawg-tools`), включает форвардинг;
2. генерирует серверный `awg0.conf` (ключи + случайная обфускация) и поднимает интерфейс;
3. скачивает `server-linux-<arch>` из релизов и делает **systemd-сервис** `vk-turn-server`;
4. открывает порт `56000` в firewall;
5. генерирует **клиентский конфиг** `/root/awg-client-router.conf` (с уже правильным
   `Endpoint = 127.0.0.1:9000`, `MTU = 1280`) и печатает данные для роутера + QR.

После установки: `vkturn status | logs | restart`.

### 2. Роутер (OpenWrt)

```sh
sh install-openwrt.sh \
  --peer <ПУБЛИЧНЫЙ_IP_VPS>:56000 \
  --vk-link https://vk.com/call/join/XXXXXXXX
# нестабильный хендшейк? добавь --udp
```

Скрипт определяет архитектуру роутера (`mips`, `mipsle`, `mips64le`, `arm`, `arm64`, `amd64`,
`386`, `riscv64` — **кросс-компиляция не нужна**, бинарники уже в релизах), скачивает
`client-linux-<arch>`, ставит **procd-сервис** `vkturn`, хелпер маршрутов `vkturn-routes`
(защита от петли) и утилиту управления.

Дальше подключи AmneziaWG на роутере к `127.0.0.1:9000` — подробно в
**[docs/openwrt-amneziawg.md](docs/openwrt-amneziawg.md)**.

Проверка: `logread -e vkturn` должен показать `Established DTLS connection!`.

## Что нужно заранее

- **VPS** на Debian/Ubuntu с публичным IP и открытым (у провайдера) портом `56000/tcp+udp`.
- **Валидная ссылка на звонок VK** (`https://vk.com/call/join/…`) — из неё vk-turn client
  берёт TURN-креды. Если соединение оборвётся, обнови ссылку: `vkturn set-link <URL>`.
- Для OpenWrt-роутера: ~10 МБ свободного flash (иначе — extroot) и интернет на WAN.

## Файлы

| Файл | Назначение |
|------|-----------|
| [`install-server.sh`](install-server.sh) | сервер: AmneziaWG + vk-turn server + systemd + firewall |
| [`install-openwrt.sh`](install-openwrt.sh) | роутер: vk-turn client + procd + route-guard |
| [`build-client.sh`](build-client.sh) | собрать пропатченный клиент (обход бага капчи) из исходников |
| [`patches/vk-captcha-not-robot.patch`](patches/vk-captcha-not-robot.patch) | фикс парсера капчи + таймаут ручного режима |
| [`uninstall-server.sh`](uninstall-server.sh) | удаление серверной части (`--purge-awg` — вместе с AWG) |
| [`docs/openwrt-amneziawg.md`](docs/openwrt-amneziawg.md) | как связать AmneziaWG на OpenWrt с транспортом |
| [`docs/captcha-manual.md`](docs/captcha-manual.md) | обход капчи VK «Я Не Робот» вручную через браузер |

## Управление

**Сервер:** `vkturn {status|start|stop|restart|logs|uninstall}`
**Роутер:** `vkturn {start|stop|restart|status|logs|set-peer|set-link|uninstall}`

## Диагностика

- Нет `Established DTLS connection!` → проверь `--peer`, открытость порта 56000 на VPS,
  живость VK-ссылки.
- DTLS есть, но AmneziaWG не встаёт → переустанови клиент с `--udp`, сверь ключи/обфускацию.
- Тормозит → увеличь `--threads` (6–8), MTU снизь до 1240.

Подробнее — в [docs/openwrt-amneziawg.md](docs/openwrt-amneziawg.md).

## Ссылки на первоисточники

- Основной проект (Go): https://github.com/cacggghp/vk-turn-proxy
- Референс-инсталлятор (архивный): https://github.com/NedgNDG/vk-proxy-auto-installer
- Реализация на Rust: https://github.com/Urtyom-Alyanov/turn-proxy
- AmneziaWG (сервер): https://github.com/amnezia-vpn/amneziawg-tools
- AmneziaWG для OpenWrt: https://github.com/amnezia-vpn/amneziawg-openwrt
