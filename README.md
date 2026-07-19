# turn-install

Установщики и документация для **[vk-turn-proxy](https://github.com/cacggghp/vk-turn-proxy)**
(«Good TURN») — обход блокировок через **TURN-релеи звонков VK**. Трафик VPN шифруется в DTLS 1.2 и
идёт через релеи VK, маскируясь под видеозвонок.

Здесь: установщик **сервера** (Debian/Ubuntu VPS), установщик **клиента** для роутера **OpenWrt**,
единый файл настроек `config.env`, патч клиента (обход бага капчи) и подробная документация.

> ⚠️ Для законного использования на **своих** серверах и со **своими** ссылками на звонки.
> Upstream: «только для учебных целей».

---

## Как это РЕАЛЬНО работает (важно, частое заблуждение)

Многие думают, что «сервер и клиент оба заходят в звонок, и через звонок идёт трафик». **Это не так.**
Проверено по исходникам ([`server/main.go`](https://github.com/cacggghp/vk-turn-proxy/blob/main/server/main.go)
имеет всего 3 флага: `-listen`, `-connect`, `-vless` — **никакой ссылки на звонок**):

```
┌─────────── РОУТЕР / КЛИЕНТ ───────────┐          ┌──────── VPS / СЕРВЕР ────────┐
 LAN → AmneziaWG(VKTURN) → 127.0.0.1:9000            :56000 (vk-turn server, DTLS)
        Endpoint=127.0.0.1:9000, MTU 1280               │ расшифровка
              │                                          ▼
        vk-turn client ──DTLS/ChannelData──►  TURN-релей VK  ──UDP──►  127.0.0.1:51820
              │  (авторизуется в VK по ссылке звонка                    AmneziaWG server → NAT → интернет
              │   ТОЛЬКО чтобы получить логин/пароль к TURN)
```

- **В звонок никто не заходит.** Клиент авторизуется в VK по ссылке звонка **только чтобы добыть
  логин/пароль к TURN-серверу** VK.
- Клиент делает **TURN Allocation** на релее VK и говорит: «шли мои пакеты на `SERVER_IP:56000`».
  Релей VK пересылает их на твой сервер по UDP. Сервер — обычный TURN **peer** с публичным IP.
- **Серверу ссылка на звонок НЕ нужна**, нужен только публичный IP и открытый порт 56000.
- Обратный путь: сервер → релей → клиент.

Итог: ссылка на звонок нужна **только на роутере** (клиенту), сервер её не знает.

---

## Быстрый старт

### 0. Заполни `config.env`

```bash
cp config.env.example config.env
nano config.env      # SERVER_IP, PROXY_PORT, VK_LINK — минимум
```

### 1. Сервер (Debian/Ubuntu VPS)

```bash
sudo bash install-server.sh          # читает config.env сам
```
Ставит AmneziaWG + vk-turn server + systemd + firewall, генерит клиентский конфиг
`/root/awg-client-<имя>.conf` и печатает данные для роутера. Управление: `vkturn status|logs|restart`.

### 2. Роутер (OpenWrt)

На роутере (файл кладём через `cat` по ssh — в dropbear нет sftp):
```sh
# с ноутбука:
cat install-openwrt.sh | ssh root@ROUTER 'cat > /tmp/i.sh'
cat config.env         | ssh root@ROUTER 'cat > /tmp/config.env'
# на роутере (config.env должен лежать рядом со скриптом):
ssh root@ROUTER 'cd /tmp && sh i.sh'
```
Ставит vk-turn client + procd-сервис `vkturn` + route-guard. Дальше — AmneziaWG-подключение
(см. [docs/openwrt-amneziawg.md](docs/openwrt-amneziawg.md)).

> 🔴 **Внимание:** релизный клиент НЕ проходит новую капчу VK. Нужен **пропатченный** — собери его
> через [`build-client.sh`](build-client.sh) и подмени `/usr/sbin/vkturn-client`. См. ниже.

---

## Капча VK «Я Не Робот» — обязательно к прочтению

Релиз v1.8.3 не проходит текущую капчу VK (баг парсера + сама капча решается только браузером).
Что сделано и как жить:

1. **Патч** [`patches/vk-captcha-not-robot.patch`](patches/vk-captcha-not-robot.patch):
   - чинит парсер (не отбраковывает капчу без legacy-полей `captcha_sid`/`captcha_img`);
   - таймаут ручной капчи 60с → 600с;
   - кэш VK-кредов 10мин → 24ч (**переподключения не требуют новой капчи**, пока VK не отвергнет креды).
2. **Сборка:** `./build-client.sh arm64` (или `mipsle`, `all`, …) — клонирует, патчит, кросс-компилит.
3. **Решение капчи вручную** (при первой авторизации и когда VK реально сбросит креды).
   Клиент отдаёт страницу капчи по **HTTPS** прямо на `0.0.0.0:8765` (самоподписанный серт).
   HTTPS обязателен: капча использует `crypto.subtle` (PoW), доступный только в secure context —
   `http://<ip>` им не является, а `https://<ip>` (даже самоподписанный) — является.
   ```
   С любого устройства в LAN → https://<ip-роутера>:8765
   → принять предупреждение о сертификате → пройти чекбокс «Я не робот»
   ```
   Запасной способ — `ssh -L 8765:localhost:8765 root@ROUTER`, затем `https://localhost:8765`.
   Подробно: **[docs/captcha-manual.md](docs/captcha-manual.md)**.

**Почему ВПН «отваливается на минуту».** Это переавторизация в VK: когда TURN-креды сбрасываются,
клиент повторно логинится → упирается в капчу → простой, пока не решишь. Патч кэша (24ч) убирает
лишние переавторизации — теперь капча нужна редко, а сетевые микрообрывы переподключаются без неё.
Для стабильности также поставь `THREADS=1` в `config.env` (1 поток стабильнее, но лимит ~5 Мбит/с у VK).

**Watchdog (авто-восстановление).** Некоторые плагины (напр. **zeroblock**) при сохранении делают
reload сети → интерфейс туннеля отваливается. На роутере ставится сервис `vkturn-watchdog`
(+ hotplug-хук): он пингует сервер через туннель и при обрыве **сам поднимает** `VKTURN` (`ifup`,
без капчи, пока клиент жив и креды в кэше). Клиента перезапускает только как крайнюю меру и НИКОГДА
во время ожидания капчи. Логи: `logread -e vkturn-wd`.

---

## Файлы

| Файл | Назначение |
|------|-----------|
| [`config.env.example`](config.env.example) | **единый файл настроек** — скопируй в `config.env` и заполни |
| [`install-server.sh`](install-server.sh) | сервер: AmneziaWG + vk-turn server + systemd + firewall |
| [`install-openwrt.sh`](install-openwrt.sh) | роутер: vk-turn client + procd + route-guard |
| [`build-client.sh`](build-client.sh) | собрать **пропатченный** клиент (обход капчи) под любую arch |
| [`patches/vk-captcha-not-robot.patch`](patches/vk-captcha-not-robot.patch) | фикс парсера + таймаут + кэш кредов 24ч |
| [`uninstall-server.sh`](uninstall-server.sh) | удаление серверной части (`--purge-awg` — вместе с AWG) |
| [`docs/openwrt-amneziawg.md`](docs/openwrt-amneziawg.md) | как связать AmneziaWG на OpenWrt с транспортом |
| [`docs/captcha-manual.md`](docs/captcha-manual.md) | ручное решение капчи VK через браузер |

---

## Ручная установка по шагам (без скриптов)

<details><summary>Сервер (Debian/Ubuntu)</summary>

```bash
# 1. AmneziaWG (Ubuntu): PPA + пакеты
add-apt-repository -y ppa:amnezia/ppa && apt update && apt install -y amneziawg amneziawg-tools qrencode
# 2. Сгенерировать awg0.conf (ключи awg genkey, обфускация Jc/Jmin/Jmax/S1/S2/H1..H4), поднять:
systemctl enable --now awg-quick@awg0
sysctl -w net.ipv4.ip_forward=1        # + NAT masquerade в PostUp awg0.conf
# 3. vk-turn server:
curl -L -o /usr/local/bin/vk-turn-server \
  https://github.com/cacggghp/vk-turn-proxy/releases/latest/download/server-linux-amd64
chmod +x /usr/local/bin/vk-turn-server
/usr/local/bin/vk-turn-server -listen 0.0.0.0:56000 -connect 127.0.0.1:51820   # (в systemd)
# 4. Открыть 56000/tcp+udp в firewall провайдера.
```
</details>

<details><summary>Роутер (OpenWrt)</summary>

```sh
# 1. Пропатченный клиент (собери build-client.sh на ПК, залей на роутер):
#    cat build/client-linux-arm64 | ssh root@ROUTER 'cat > /usr/sbin/vkturn-client; chmod +x /usr/sbin/vkturn-client'
# 2. Запуск (127.0.0.1:9000 — сюда цепляется AmneziaWG):
vkturn-client -peer SERVER_IP:56000 -vk-link https://vk.ru/call/join/XXXX -listen 127.0.0.1:9000 -n 1
# 3. AmneziaWG-интерфейс (uci, proto amneziawg): Endpoint=127.0.0.1:9000, MTU=1280,
#    ключи/обфускацию взять из awg-client-*.conf с сервера. Поднять после 'Established DTLS connection!'.
# 4. Капча: ssh -L 8765:localhost:8765 root@ROUTER → http://localhost:8765 → пройти чекбокс.
```
Полный рабочий пример UCI-интерфейса — в [docs/openwrt-amneziawg.md](docs/openwrt-amneziawg.md).
</details>

---

## Проверка

**Сервер:** `systemctl status vk-turn-server awg-quick@awg0`; `awg show`; `ss -lun | grep 56000`.
**Роутер:** `logread -e vkturn` → `Established DTLS connection!`; `awg show VKTURN` → свежий handshake;
`curl` через туннель возвращает **IP сервера**.

## Ссылки

- Проект: https://github.com/cacggghp/vk-turn-proxy
- AmneziaWG для OpenWrt: https://github.com/amnezia-vpn/amneziawg-openwrt
