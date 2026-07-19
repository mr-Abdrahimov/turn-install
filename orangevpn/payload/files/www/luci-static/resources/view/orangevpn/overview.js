'use strict';
'require view';
'require ui';
'require rpc';
'require uci';
'require poll';
'require dom';

var rpcList = rpc.declare({ object: 'luci.orangevpn', method: 'list' });
var rpcPing = rpc.declare({ object: 'luci.orangevpn', method: 'ping', params: ['host'], expect: { rtt: '' } });
var rpcConnect = rpc.declare({ object: 'luci.orangevpn', method: 'connect', params: ['index'] });
var rpcStatus = rpc.declare({ object: 'luci.orangevpn', method: 'status' });
var rpcSetUrl = rpc.declare({ object: 'luci.orangevpn', method: 'seturl', params: ['url', 'vk_link'], expect: { result: false } });

return view.extend({
	load: function () {
		return Promise.all([
			L.resolveDefault(rpcList(), {}),
			L.resolveDefault(rpcStatus(), {})
		]);
	},

	// пингуем все хосты, обновляем ячейки, подсвечиваем минимальный
	pollPings: function (rows) {
		var self = this;
		var hosts = Object.keys(rows);
		return Promise.all(hosts.map(function (h) {
			// ВНИМАНИЕ: из-за expect:{rtt:''} rpc возвращает САМО значение rtt, а не объект
			return L.resolveDefault(rpcPing(h), null).then(function (r) {
				var v = (r === '' || r == null) ? NaN : parseInt(r, 10);
				rows[h].rtt = isNaN(v) ? null : v;
			});
		})).then(function () {
			// найти минимальный валидный пинг
			var best = null;
			hosts.forEach(function (h) {
				var v = rows[h].rtt;
				if (v != null && (best == null || v < best)) best = v;
			});
			hosts.forEach(function (h) {
				var v = rows[h].rtt, cell = rows[h].cell, tr = rows[h].tr;
				if (v == null) {
					dom.content(cell, E('span', { style: 'color:#a00' }, _('нет ответа')));
					tr.classList.remove('orange-best');
				} else {
					var isBest = (v === best);
					dom.content(cell, E('span', {
						style: 'font-weight:' + (isBest ? '700' : '400') + ';color:' + (isBest ? '#080' : 'inherit')
					}, v + ' ' + _('мс') + (isBest ? ' ★' : '')));
					if (isBest) tr.classList.add('orange-best'); else tr.classList.remove('orange-best');
				}
			});
		});
	},

	renderStatus: function (st) {
		st = st || {};
		var parts = [];
		if (st.up) {
			parts.push(E('span', { style: 'color:#080;font-weight:700' }, '● ' + _('Подключено')));
			if (st.active_host) parts.push(' — ' + st.active_host);
			if (st.handshake_age >= 0) parts.push(' (' + _('handshake') + ': ' + st.handshake_age + ' ' + _('сек назад') + ')');
		} else if (st.captcha_pending) {
			parts.push(E('span', { style: 'color:#c60;font-weight:700' }, '⚠ ' + _('Требуется капча')));
			parts.push(' — ' + _('открой') + ' ');
			parts.push(E('a', { href: st.captcha_url, target: '_blank', rel: 'noreferrer' }, st.captcha_url));
			parts.push(' (' + _('прими самоподписанный сертификат, пройди «Я не робот»') + ')');
		} else {
			parts.push(E('span', { style: 'color:#a00;font-weight:700' }, '○ ' + _('Не подключено')));
			if (st.active_host) parts.push(' — ' + _('выбран') + ' ' + st.active_host);
		}
		return E('div', { 'class': 'cbi-value', style: 'padding:8px 0' }, parts);
	},

	reloadInto: function (container) {
		var self = this;
		return self.load().then(function (data) {
			dom.content(container, self.renderBody(data));
		});
	},

	renderBody: function (data) {
		var self = this;
		var info = data[0] || {};
		var st = data[1] || {};
		var servers = info.servers || [];
		var rows = {}; // host -> {cell, tr, rtt}

		// --- настройки ---
		var urlInput = E('input', {
			'type': 'text', 'class': 'cbi-input-text', style: 'width:100%',
			'placeholder': 'https://ваш-сервер/orangevpn.json', 'value': info.url || ''
		});
		var vkNote = info.vk_link_from_list
			? E('span', { style: 'color:#080' }, _('✓ приходит из списка серверов'))
			: (info.has_vk_link
				? E('span', { style: 'color:#888' }, _('задана локально (в списке её нет)'))
				: E('span', { style: 'color:#c60' }, _('не задана — добавь "vk_link" в JSON списка')));
		var settings = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Настройки')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('URL списка серверов')),
				E('div', { 'class': 'cbi-value-field' }, urlInput)
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Ссылка на звонок VK')),
				E('div', { 'class': 'cbi-value-field' }, [ vkNote,
					E('div', { 'class': 'cbi-value-description' },
						_('Берётся автоматически из списка серверов (поле "vk_link"), задавать вручную не нужно.')) ])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-save',
						'click': ui.createHandlerFn(self, function () {
							return rpcSetUrl(urlInput.value || '', '').then(function () {
								ui.addNotification(null, _('Сохранено. Обновляю список…'), 'info');
								return self.reloadInto(document.getElementById('orange-root'));
							});
						})
					}, _('Сохранить и обновить')),
					' ',
					E('button', {
						'class': 'btn cbi-button cbi-button-neutral',
						'click': ui.createHandlerFn(self, function () {
							return self.reloadInto(document.getElementById('orange-root'));
						})
					}, _('Обновить список'))
				])
			])
		]);

		// --- таблица серверов ---
		var table = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, _('Имя')),
				E('th', { 'class': 'th' }, _('Сервер (host)')),
				E('th', { 'class': 'th', style: 'text-align:center' }, _('Пинг')),
				E('th', { 'class': 'th', style: 'text-align:center' }, _('Статус')),
				E('th', { 'class': 'th', style: 'text-align:center' }, _('Действие'))
			])
		]);

		if (!info.has_url) {
			table.appendChild(E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', colspan: 5 },
				E('em', {}, _('Укажи URL списка серверов в настройках выше.')))));
		} else if (servers.length === 0) {
			table.appendChild(E('tr', { 'class': 'tr' }, E('td', { 'class': 'td', colspan: 5 },
				E('em', {}, _('Список пуст или URL недоступен. Проверь ссылку.')))));
		}

		servers.forEach(function (s) {
			var pingTd = E('td', { 'class': 'td', style: 'text-align:center' }, E('em', {}, '…'));
			var tr = E('tr', { 'class': 'tr' });
			rows[s.host] = { cell: pingTd, tr: tr, rtt: null };

			var actionBtn = E('button', {
				'class': 'btn cbi-button ' + (s.active ? 'cbi-button-positive' : 'cbi-button-apply'),
				'click': ui.createHandlerFn(self, function () {
					return rpcConnect(String(s.index)).then(function (res) {
						if (res && res.result) {
							if (res.captcha) {
								ui.showModal(_('Требуется капча'), [
									E('p', {}, _('Подключение к серверу запущено. Осталось пройти капчу VK:')),
									E('p', {}, [ E('b', {}, _('Открой в браузере: ')),
										E('a', { href: res.captcha_url, target: '_blank', rel: 'noreferrer' }, res.captcha_url) ]),
									E('p', {}, _('Прими самоподписанный сертификат, нажми «Я не робот». Туннель поднимется автоматически.')),
									E('div', { 'class': 'right' }, E('button', {
										'class': 'btn', 'click': ui.hideModal
									}, _('Понятно')))
								]);
							} else {
								ui.addNotification(null, _('Подключаюсь к ') + (res.host || ''), 'info');
							}
							return self.reloadInto(document.getElementById('orange-root'));
						} else {
							ui.addNotification(null, (res && res.error) || _('Не удалось подключиться'), 'error');
						}
					});
				})
			}, s.active ? _('Активен') : _('Подключить'));

			dom.content(tr, [
				E('td', { 'class': 'td' }, s.name),
				E('td', { 'class': 'td' }, s.host),
				pingTd,
				E('td', { 'class': 'td', style: 'text-align:center' },
					s.active ? E('span', { style: 'color:#080;font-weight:700' }, '● ' + _('выбран')) : ''),
				E('td', { 'class': 'td', style: 'text-align:center' }, actionBtn)
			]);
			table.appendChild(tr);
		});

		// запустить опрос пингов
		if (Object.keys(rows).length) {
			poll.add(function () { return self.pollPings(rows); }, 5);
		}

		return E('div', {}, [ self.renderStatus(st), settings,
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, _('Серверы')), table ]) ]);
	},

	render: function (data) {
		var self = this;
		var root = E('div', { id: 'orange-root' }, self.renderBody(data));
		return E('div', {}, [
			E('style', {}, '.orange-best td{background:rgba(0,136,0,0.08)}'),
			E('h2', {}, [ 'OrangeVPN ', E('small', { style: 'color:#888;font-weight:400' }, 'v3') ]),
			E('p', {}, _('Список серверов пингуется; лучший (минимальный пинг) отмечен ★. Нажми «Подключить», чтобы завести коннект в интерфейс OrangeVPN.')),
			root
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
