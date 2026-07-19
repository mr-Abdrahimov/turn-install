# Использование vk-turn-proxy на OpenWrt вместе с AmneziaWG

Этот документ описывает, как связать **vk-turn client** (транспорт через TURN-релеи VK)
с **AmneziaWG/WireGuard**-подключением на роутере OpenWrt.

## Схема

```
LAN-устройства
     │
     ▼
AmneziaWG-интерфейс (awg0) ── Endpoint 127.0.0.1:9000, MTU 1280
     │  (шифрованный WG/AWG-трафик как обычный UDP)
     ▼
vk-turn client  ── слушает 127.0.0.1:9000
     │  оборачивает UDP в DTLS 1.2 + STUN ChannelData
     ▼
TURN-релеи VK (звонки)  ── для DPI выглядит как видеозвонок
     │
     ▼
VPS: vk-turn server (:56000) → 127.0.0.1:51820 (AmneziaWG server) → NAT → интернет
```

Ключевая идея: AmneziaWG **не** ходит напрямую на публичный IP сервера. Его `Endpoint`
указывает на **локальный** vk-turn client (`127.0.0.1:9000`), а тот уже прячет трафик в звонки VK.

## Шаг 1. Поставить транспорт

```sh
sh install-openwrt.sh \
  --peer <ПУБЛИЧНЫЙ_IP_VPS>:56000 \
  --vk-link https://vk.com/call/join/XXXXXXXX
```

Проверить, что связь с сервером поднялась:

```sh
logread -e vkturn        # должна появиться строка: Established DTLS connection!
vkturn status
```

## Шаг 2. Настроить AmneziaWG-подключение (в твоём приложении/luci-proto-amneziawg)

Параметры берём из файла, который сгенерировал `install-server.sh` на VPS:
`/root/awg-client-router.conf`. Важные отличия для OpenWrt:

| Поле | Значение | Комментарий |
|------|----------|-------------|
| `Endpoint` | `127.0.0.1:9000` | **локальный** vk-turn client, НЕ IP сервера |
| `MTU` | `1280` | накладные TURN+DTLS; при обрывах — `1240` |
| `PublicKey` (peer) | из `awg-client-*.conf` | публичный ключ сервера |
| `PresharedKey` | из `awg-client-*.conf` | |
| `PrivateKey` (interface) | из `awg-client-*.conf` | |
| `Address` | из `awg-client-*.conf` (напр. `10.8.1.2/24`) | |
| `AllowedIPs` | по твоей политике маршрутизации | напр. `0.0.0.0/0` для full-tunnel |
| `Jc,Jmin,Jmax,S1,S2,H1..H4` | из `awg-client-*.conf` | обфускация должна совпадать с сервером |
| `PersistentKeepalive` | `25` | |

### Если ставишь AmneziaWG на OpenWrt с нуля

Нужны пакеты `kmod-amneziawg`, `amneziawg-tools`, `luci-proto-amneziawg` (нет в штатном
репозитории). Готовые сборки под твою версию/таргет:

```sh
sh <(wget -O - https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/master/amneziawg-install.sh)
```

или официальный feed [`amnezia-vpn/amneziawg-openwrt`](https://github.com/amnezia-vpn/amneziawg-openwrt).
Требуется **OpenWrt ≥ 24.10.3**. При настройке интерфейса укажи Endpoint `127.0.0.1:9000` и MTU `1280`.

## Шаг 3. Порядок запуска

1. `vk-turn client` (procd-сервис `vkturn`) стартует при загрузке роутера.
2. Дождись `Established DTLS connection!` в `logread`.
3. Твоё приложение поднимает AmneziaWG-туннель.

Если поднять туннель раньше, чем встанет vk-turn client — часть трафика уйдёт в петлю.

## Как решается петля маршрутизации

`install-openwrt.sh` кладёт хелпер `/usr/sbin/vkturn-routes`. Он читает stdout клиента:
клиент печатает IP каждого используемого TURN-релея и VPS, а хелпер прописывает на них
`ip route replace <ip> via <WAN-шлюз>`. Так собственные исходящие пакеты vk-turn client
всегда идут через физический WAN, а не в туннель — даже при `AllowedIPs = 0.0.0.0/0`.

WAN-шлюз определяется с исключением туннельных интерфейсов (`awg`/`wg`/`tun`), поэтому
работает и при full-tunnel, и при policy-routing.

> **Нюанс full-tunnel через fwmark.** Если твоё приложение реализует полный туннель
> через `fwmark` + `ip rule` (как `wg-quick`), убедись, что исходящие пакеты процесса
> `vkturn-client` не попадают под правило перенаправления. Обычно локальные процессы
> роутера используют основную таблицу маршрутизации, и host-роутов `/32` достаточно.
> При необходимости добавь `ip rule` для UID/метки процесса vk-turn client.

## Диагностика

| Симптом | Что смотреть |
|---------|--------------|
| Нет `Established DTLS connection!` | `--peer` верный? порт 56000 открыт на VPS? ссылка VK живая? |
| DTLS есть, но AmneziaWG не хендшейкает | переустанови клиент с `--udp`; проверь совпадение ключей/обфускации |
| Работает, но рвётся/тормозит | увеличь `--threads` (напр. 6–8); MTU → 1240 |
| Сайты не грузятся при активном туннеле | `ip route | grep <VPS_IP>` — есть ли `/32 via WAN`? DNS в конфиге AWG? |
| Ссылка VK «протухла» | обнови: `vkturn set-link https://vk.com/call/join/NEW` |

## Полезные ссылки

- Основной проект: https://github.com/cacggghp/vk-turn-proxy
- AmneziaWG для OpenWrt: https://github.com/amnezia-vpn/amneziawg-openwrt
- Инструкция Amnezia по OpenWrt: https://docs.amnezia.org/documentation/instructions/openwrt-os-awg/
