# OrangeVPN — плагин + единый установщик для OpenWrt

Один файл (`orangevpn-install.run`), который ставит **всю систему** и добавляет в LuCI
раздел **VPN → OrangeVPN**: список серверов с пингом, выбор сервера в один клик.

```
┌─ LuCI: VPN → OrangeVPN ──────────────────────────────────┐
│ Имя              Сервер          Пинг      Статус  Действие│
│ RU-1             2.27.12.78      78 мс             Подключить│
│ RU-2             95.85.249.19    52 мс ★   ● выбран Активен  │
└──────────────────────────────────────────────────────────┘
```
★ — минимальный пинг (лучший сервер).

## Что ставит установщик

| Компонент | Назначение |
|---|---|
| `/usr/sbin/vkturn-client` | пропатченный vk-turn client (HTTPS-капча, кэш кредов 24ч) |
| `/etc/init.d/vkturn` | procd-сервис клиента (прямой запуск — чистый restart) |
| `/usr/sbin/vkturn-watchdog` + init | авто-восстановление туннеля (напр. после reload zeroblock) |
| `/etc/hotplug.d/iface/99-vkturn-recover` | мгновенная реакция на возврат WAN |
| LuCI-плагин | menu.d + acl.d + view.js + rpcd-бэкенд `luci.orangevpn` |
| UCI `orangevpn` | URL списка серверов + ссылка на звонок VK |

Плагин управляет AmneziaWG-интерфейсом **`OrangeVPN`**. Если на роутере был старый
интерфейс `VKTURN` — установщик переносит настройки в `OrangeVPN` и убирает старый.

## Установка

```sh
# на роутере (файл заливается через cat, т.к. в dropbear нет sftp)
cat orangevpn-install.run | ssh root@192.168.1.1 'cat > /tmp/orangevpn-install.run'
ssh root@192.168.1.1 'sh /tmp/orangevpn-install.run'
```
Спросит URL списка серверов и ссылку на звонок VK. Либо без вопросов:
```sh
sh /tmp/orangevpn-install.run --url 'http://СЕРВЕР:8088/СЕКРЕТ/orangevpn.json' \
                              --vk-link 'https://vk.ru/call/join/XXXX'
```

## Сборка `.run`

```sh
./build-client.sh arm64          # собрать пропатченный клиент (в build/)
./orangevpn/build-run.sh         # -> orangevpn/orangevpn-install.run (~5 МБ)
# под другую arch:
./build-client.sh mipsle && ./orangevpn/build-run.sh build/client-linux-mipsle
```

## Формат списка серверов (JSON)

```json
{
  "proxy_port": 56000,
  "vk_link": "https://vk.ru/call/join/XXXX",
  "servers": [
    {
      "name": "RU-1",
      "host": "2.27.12.78",
      "awg": {
        "private_key": "<приватный ключ клиента>",
        "address": "10.8.1.2/24",
        "mtu": 1280,
        "jc": 10, "jmin": 60, "jmax": 611,
        "s1": 134, "s2": 62, "s3": 0, "s4": 0,
        "h1": 122798731, "h2": 1904567431, "h3": 207500138, "h4": 680276921,
        "peer_public_key": "<публичный ключ сервера>",
        "preshared_key": "<PSK>",
        "keepalive": 25
      }
    }
  ]
}
```

- `host` — публичный IP сервера: по нему **пингуется** и на него нацеливается vk-turn client (`-peer host:proxy_port`).
- Блок `awg` — параметры AmneziaWG-подключения (**Endpoint всегда `127.0.0.1:9000`** — локальный vk-turn client, это подставляет плагин).
- `install-server.sh` на каждом сервере кладёт готовую запись в **`/root/orangevpn-entry.json`** — просто собери из них массив `servers`.

## Как захостить список

Список содержит **приватные ключи**, поэтому отдавай его по «секретному» пути и,
по возможности, по HTTPS.

```sh
# на одном из серверов
TOKEN=$(head -c 18 /dev/urandom | od -An -tx1 | tr -d ' \n')
mkdir -p /var/lib/orangevpn/$TOKEN
cp orangevpn.json /var/lib/orangevpn/$TOKEN/
cat > /etc/systemd/system/orangevpn-list.service <<'SVC'
[Unit]
Description=OrangeVPN connection list
After=network-online.target
[Service]
WorkingDirectory=/var/lib/orangevpn
ExecStart=/usr/bin/python3 -m http.server 8088 --bind 0.0.0.0
Restart=always
[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload && systemctl enable --now orangevpn-list
echo "URL: http://$(curl -s ifconfig.me):8088/$TOKEN/orangevpn.json"
```

> ⚠️ **Безопасность.** По HTTP ключи идут открытым текстом. Секретный путь защищает от
> случайного обнаружения, но не от перехвата трафика. Для продакшена поставь HTTPS
> (nginx + Let's Encrypt) или отдавай список только по VPN/из доверенной сети.

## Использование

1. LuCI → **VPN → OrangeVPN**.
2. Пинги измеряются автоматически (обновление каждые 5 сек), лучший отмечен **★**.
3. **«Подключить»** — применяет сервер к интерфейсу `OrangeVPN` и нацеливает на него клиент.
4. Если попросит капчу — открой **`https://<ip-роутера>:8765`**, прими самоподписанный
   сертификат, пройди «Я не робот». HTTPS обязателен: капча использует `crypto.subtle`,
   доступный только в secure context.

## Диагностика

```sh
ubus call luci.orangevpn status      # состояние туннеля/капчи
ubus call luci.orangevpn list        # список серверов
ubus call luci.orangevpn ping '{"host":"1.1.1.1"}'
logread -e vkturn                    # лог клиента
logread -e vkturn-wd                 # лог watchdog
```
Если страница не появилась в меню: `rm -f /tmp/luci-indexcache*; rm -rf /tmp/luci-modulecache/; /etc/init.d/rpcd restart`.

## Производительность (замерено на живом стенде)

| Канал | Скорость |
|---|---|
| Прямой WAN | 3.3 МБ/с |
| Обычный WireGuard/AWG-туннель (для сравнения) | 1.7 МБ/с |
| **vk-turn (эта система)** | **~70 КБ/с (~0.5 Мбит/с)** |

Полоса режется TURN-релеями VK **на каждый поток** (~6 КБ/с) и суммируется, но с насыщением:

| `-n` (потоков) | Скорость |
|---|---|
| 1 | 8 КБ/с |
| 8 | 49 КБ/с |
| **16** | **70 КБ/с ← оптимум** |
| 32 | 67 КБ/с (прироста нет) |

Проверено и НЕ подтвердилось: `-udp` не быстрее TCP (49 против 57 КБ/с), CPU роутера не при чём
(клиент ест 0–4%), потерь и джиттера нет (100/100 пакетов, ровные ~50 мс).

**Вывод:** ~0.5 Мбит/с — потолок самой технологии (трафик идёт через чужие TURN-релеи VK),
а не дефект сборки. Поэтому через этот туннель стоит пускать только то, что реально требует
именно такого обхода. Тяжёлый и чувствительный к полосе трафик (видео, голосовые звонки
вместе с прочей активностью) лучше направлять в обычный VPN — иначе канал переполняется
и появляются «зависания» на 2–3 секунды.

## Капча при перезапуске больше не нужна

TURN-креды сохраняются в `/etc/vkturn/creds.json` и переиспользуются после рестарта клиента
и перезагрузки роутера. Капча запрашивается только когда VK реально отвергнет креды
(тогда файл удаляется автоматически). Путь можно переопределить через `VKTURN_CREDS_FILE`.
