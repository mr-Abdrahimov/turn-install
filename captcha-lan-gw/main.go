// captcha-lan-gw — LAN-шлюз для страницы ручной капчи vk-turn client.
//
// vk-turn client поднимает страницу капчи на 127.0.0.1:8765 и жёстко использует
// в HTML/JS origin "http://localhost:8765". Поэтому напрямую с LAN-устройства она
// не открывается. Этот прокси слушает LAN-порт роутера и:
//   - проксирует на 127.0.0.1:8765;
//   - подменяет Host на "localhost:8765" (иначе клиент отвергает запрос);
//   - в ответах переписывает "localhost:8765"/"127.0.0.1:8765" на адрес, по
//     которому пользователь реально зашёл (из заголовка Host запроса),
//     чтобы все внутренние ссылки/редиректы вели обратно на роутер.
//
// Итог: любой пользователь в LAN открывает http://<ip-роутера>:<порт> и решает
// капчу в браузере — без ssh-проброса портов.
//
// Конфиг через env:
//   LISTEN   — адрес прослушки (по умолчанию 0.0.0.0:8766)
//   UPSTREAM — адрес капча-сервера клиента (по умолчанию 127.0.0.1:8765)
package main

import (
	"bytes"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
)

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	listen := getenv("LISTEN", "0.0.0.0:8766")
	upstream := getenv("UPSTREAM", "http://127.0.0.1:8765")
	// хост, который клиент капчи считает "локальным" (Host для upstream-запроса)
	upstreamHost := strings.TrimPrefix(strings.TrimPrefix(upstream, "http://"), "https://")

	target, err := url.Parse(upstream)
	if err != nil {
		log.Fatalf("bad UPSTREAM %q: %v", upstream, err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	orig := proxy.Director
	proxy.Director = func(r *http.Request) {
		clientHost := r.Host // то, что ввёл пользователь, напр. 192.168.1.1:8766
		orig(r)
		r.Header.Set("X-Orig-Host", clientHost)
		r.Host = upstreamHost // клиент капчи принимает только localhost:8765
		r.Header.Del("Accept-Encoding")
	}

	// адреса, которые надо переписать на адрес пользователя
	localHosts := []string{upstreamHost, "localhost:8765", "127.0.0.1:8765"}

	proxy.ModifyResponse = func(resp *http.Response) error {
		clientHost := resp.Request.Header.Get("X-Orig-Host")
		if clientHost == "" {
			clientHost = upstreamHost
		}

		// Location-редиректы
		if loc := resp.Header.Get("Location"); loc != "" {
			for _, h := range localHosts {
				loc = strings.ReplaceAll(loc, h, clientHost)
			}
			resp.Header.Set("Location", loc)
		}

		// тело — только для текстовых типов
		ct := resp.Header.Get("Content-Type")
		if strings.Contains(ct, "text") || strings.Contains(ct, "html") ||
			strings.Contains(ct, "json") || strings.Contains(ct, "javascript") ||
			strings.Contains(ct, "xml") {
			body, err := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			if err != nil {
				return err
			}
			s := string(body)
			for _, h := range localHosts {
				s = strings.ReplaceAll(s, h, clientHost)
			}
			b := []byte(s)
			resp.Body = io.NopCloser(bytes.NewReader(b))
			resp.ContentLength = int64(len(b))
			resp.Header.Set("Content-Length", strconv.Itoa(len(b)))
		}
		return nil
	}

	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, e error) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusBadGateway)
		_, _ = io.WriteString(w, `<!doctype html><meta charset=utf-8>
<div style="font-family:sans-serif;text-align:center;margin-top:20vh">
<h2>Капча ещё не готова</h2>
<p>vk-turn client пока не открыл страницу капчи (порт 8765).</p>
<p>Обнови эту страницу через 10–20 секунд.</p></div>`)
	}

	log.Printf("captcha-lan-gw: %s -> %s (Host=%s)", listen, upstream, upstreamHost)
	log.Fatal(http.ListenAndServe(listen, proxy))
}
