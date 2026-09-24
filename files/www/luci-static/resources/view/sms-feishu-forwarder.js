'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require poll';

var callStatus = rpc.declare({ object: 'sms-feishu-forwarder', method: 'status', expect: { '': {} } });
var callLogs = rpc.declare({ object: 'sms-feishu-forwarder', method: 'logs', expect: { lines: [] } });
var callRestart = rpc.declare({ object: 'sms-feishu-forwarder', method: 'restart', expect: { '': { code: 1 } } });
var callSeed = rpc.declare({ object: 'sms-feishu-forwarder', method: 'seed', expect: { '': { code: 1 } } });
var callTest = rpc.declare({ object: 'sms-feishu-forwarder', method: 'test_card', expect: { '': { code: 1 } } });
var callSendSchedule = rpc.declare({ object: 'sms-feishu-forwarder', method: 'send_schedule', params: [ 'section' ], expect: { '': { code: 1 } } });
var callSetWebhook = rpc.declare({ object: 'sms-feishu-forwarder', method: 'set_webhook', params: [ 'webhook' ], expect: { '': { code: 1 } } });

function statusRow(label1, value1, label2, value2) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'style': 'width:18%;font-weight:600' }, label1),
		E('td', { 'class': 'td', 'style': 'width:32%' }, value1),
		E('td', { 'class': 'td left', 'style': 'width:18%;font-weight:600' }, label2),
		E('td', { 'class': 'td', 'style': 'width:32%' }, value2)
	]);
}

function statusTable(data, modem) {
	var latest = data.latest_schedule || {};
	var quota = data.quota || {};
	modem = modem || {};
	var rsrqSinr = [ modem.rsrq, modem.sinr ].filter(function(v) { return v; }).join(' / ');
	var pciArfcn = [ modem.pci, modem.arfcn ].filter(function(v) { return v; }).join(' / ');
	var latestSchedule = [ latest.section || _('暂无'), latest.result ? ' / ' + latest.result : '', latest.timestamp ? ' / ' + latest.timestamp : '' ].join('');
	return E('table', { 'class': 'table', 'style': 'width:100%;table-layout:fixed' }, [
		statusRow(_('转发服务'), data.forwarder && data.forwarder.running ? _('运行中') : _('未运行'), _('定时服务'), data.scheduler && data.scheduler.running ? _('运行中') : _('未运行')),
		statusRow(_('最近转发'), data.latest_forwarding || _('暂无'), _('最近定时发送'), latestSchedule),
		statusRow(_('在线设备'), modem.online_devices || _('未知'), _('网络模式'), modem.network_mode || _('未知')),
		statusRow(_('RSRP'), modem.rsrp || _('未知'), _('RSRQ / SINR'), rsrqSinr || _('未知')),
		statusRow(_('模组温度'), modem.temperature || _('未知'), _('PCI / ARFCN'), pciArfcn || _('未知')),
		statusRow(_('WAN 地址'), modem.wan || _('未知'), _('运行时间'), modem.uptime || _('未知')),
		statusRow(_('校准周期'), quota.interval || _('关闭'), _('本地月用量'), quota.local_usage || _('未知')),
		statusRow(_('本月通用总量'), quota.carrier_total || _('未知'), _('校准剩余'), quota.calibrated_remaining || _('未知')),
		statusRow(_('估算剩余'), quota.estimated_remaining || _('未知'), _('上次校准'), quota.last_calibration || _('未知')),
		statusRow(_('下次到期'), quota.next_due || _('未知'), '', '')
	]);
}

return view.extend({
	load: function() {
		return uci.load('sms-feishu-forwarder').then(function() {
			return Promise.all([
				Promise.resolve(true),
				callStatus(),
				callLogs()
			]);
		});
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			return ui.changes.apply(mode == '0');
		}).then(function() {
			return callRestart();
		}).then(function(res) {
			if (!res || res.code !== 0)
				return Promise.reject(new Error(_('配置已保存，但服务状态同步失败')));
		});
	},

	render: function(data) {
		var m, s, o;
		var modemData = (data[1] && data[1].modem) || {};
		var status = E('div', {}, statusTable(data[1] || {}, modemData));
		poll.add(function() {
			return callStatus().then(function(res) {
				status.innerHTML = '';
				status.appendChild(statusTable(res || {}, (res && res.modem) || {}));
			});
		}, 10);

		m = new form.Map('sms-feishu-forwarder', _('短信飞书助手'));
		s = m.section(form.NamedSection, 'settings', 'settings', _('状态'));
		o = s.option(form.DummyValue, '_overview');
		o.render = function() { return status; };

		s = m.section(form.NamedSection, 'settings', 'settings', _('基础设置'));
		o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = '1';
		o.rmempty = false;
		o = s.option(form.Value, 'poll_interval', _('轮询间隔'));
		o.datatype = 'range(5,600)';
		o = s.option(form.Value, 'settle_delay', _('等待延迟'));
		o.datatype = 'uinteger';
		o = s.option(form.Flag, 'attach_status', _('附加状态'));
		o.default = '1';
		o.rmempty = false;
		o = s.option(form.ListValue, 'quota_calibration', _('校准周期'));
		o.value('off', _('关闭'));
		o.value('7', _('每 7 天'));
		o.value('14', _('每 14 天'));
		o.default = 'off';
		o.rmempty = false;
		o = s.option(form.Value, '_feishu_webhook', _('飞书 Webhook'));
		o.password = true;
		o.placeholder = _('留空保持不变');
		o.cfgvalue = function() { return ''; };
		o.write = function(section_id, value) {
			value = (value || '').trim();
			if (value)
				return callSetWebhook(value).then(function(res) {
					if (!res || res.code !== 0)
						return Promise.reject(new Error(_('飞书 Webhook 无效')));
				});
		};

		s = m.section(form.GridSection, 'schedule', _('定时短信'));
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		o = s.option(form.Flag, 'enabled', _('启用'));
		o.default = '1';
		o.rmempty = false;
		o = s.option(form.Value, 'name', _('名称'));
		o = s.option(form.Value, 'recipient', _('收件人'));
		o.datatype = 'and(minlength(3),maxlength(20))';
		o = s.option(form.Value, 'content', _('内容'));
		o.rmempty = false;
		o = s.option(form.Value, 'hour', _('小时'));
		o.default = '*';
		o.validate = function(section_id, value) { return /^(\*|\*\/[1-9][0-9]*|[0-9]|1[0-9]|2[0-3])$/.test(value) || _('请输入 *、*/N 或 0-23'); };
		o = s.option(form.Value, 'minute', _('分钟'));
		o.default = '0';
		o.validate = function(section_id, value) { return /^(\*|\*\/[1-9][0-9]*|[0-9]|[1-5][0-9])$/.test(value) || _('请输入 *、*/N 或 0-59'); };
		o = s.option(form.Value, 'weekdays', _('星期'));
		o.default = '*';
		o.validate = function(section_id, value) { return /^(\*|[0-6](,[0-6])*)$/.test(value) || _('请输入 * 或 0-6 逗号列表'); };
		o = s.option(form.Button, '_send', _('立即发送'));
		o.inputstyle = 'apply';
		o.onclick = function(ev, section_id) {
			return callSendSchedule(section_id).then(function(res) {
				ui.addNotification(null, E('p', {}, res.code === 0 ? _('已发送') : _('发送失败')));
			});
		};

		s = m.section(form.NamedSection, 'settings', 'settings', _('维护'));
		o = s.option(form.Button, '_test', _('测试飞书卡片'));
		o.inputstyle = 'apply';
		o.onclick = function() { return callTest().then(function(res) { ui.addNotification(null, E('p', {}, res.code === 0 ? _('测试已发送') : _('测试失败'))); }); };
		o = s.option(form.Button, '_restart', _('重启服务'));
		o.inputstyle = 'reload';
		o.onclick = function() { return callRestart().then(function(res) { ui.addNotification(null, E('p', {}, res.code === 0 ? _('已重启') : _('重启失败'))); }); };
		o = s.option(form.Button, '_seed', _('标记当前收件箱'));
		o.inputstyle = 'remove';
		o.onclick = function() {
			if (!window.confirm(_('确认将当前收件箱短信标记为已处理？')))
				return;
			return callSeed().then(function(res) { ui.addNotification(null, E('p', {}, res.code === 0 ? _('已标记') : _('标记失败'))); });
		};

		s = m.section(form.NamedSection, 'settings', 'settings', _('日志'));
		o = s.option(form.TextValue, '_logs');
		o.rows = 12;
		o.readonly = true;
		o.cfgvalue = function() { return (data[2] || []).join('\n'); };

		return m.render();
	}
});
