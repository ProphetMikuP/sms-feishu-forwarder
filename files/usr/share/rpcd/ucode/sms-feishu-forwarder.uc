#!/usr/bin/ucode
'use strict';

import * as fs from 'fs';
import * as uci from 'uci';

const state_dir = '/etc/sms-feishu-forwarder/schedule-state';
const default_modem_status_path = '/var/lib/sms-feishu-forwarder/modem-status.json';
const default_quota_status_path = '/var/lib/sms-feishu-forwarder/quota-status.json';

function valid_section(name) {
	return type(name) == 'string' && match(name, /^[A-Za-z_][A-Za-z0-9_]*$/);
}

function schedule_exists(name) {
	if (!valid_section(name))
		return false;
	let c = uci.cursor();
	let s = c.get_all('sms-feishu-forwarder', name);
	return s && s['.type'] == 'schedule';
}

function readfile(path) {
	let data = fs.readfile(path);
	return data == null ? '' : trim(data);
}

function config_value(option, fallback) {
	let c = uci.cursor();
	let value = c.get('sms-feishu-forwarder', 'settings', option);
	return value ? value : fallback;
}

function instance_running(instance) {
	if (instance != 'forwarder' && instance != 'scheduler')
		return false;
	let cmd = "ubus call service list '{\"name\":\"sms-feishu-forwarder\"}' 2>/dev/null | jsonfilter -q -e '@[\"sms-feishu-forwarder\"].instances." + instance + ".running' | grep -qx true";
	return system(cmd) == 0;
}

function instance_state(instance) {
	let enabled = system('/etc/init.d/sms-feishu-forwarder enabled >/dev/null 2>&1') == 0;
	let running = instance_running(instance);
	return { enabled, running };
}

function schedule_result(name) {
	if (!valid_section(name))
		return {};
	return {
		last_slot: readfile(state_dir + '/' + name + '.last_slot'),
		result: readfile(state_dir + '/' + name + '.result'),
		timestamp: readfile(state_dir + '/' + name + '.timestamp'),
		message: readfile(state_dir + '/' + name + '.message')
	};
}

function latest_schedule_result() {
	let best = {};
	let c = uci.cursor();
	c.foreach('sms-feishu-forwarder', 'schedule', function(s) {
		let r = schedule_result(s['.name']);
		if (r.timestamp && (!best.timestamp || r.timestamp > best.timestamp))
			best = { section: s['.name'], name: s.name || s['.name'], result: r.result, timestamp: r.timestamp, message: r.message };
	});
	return best;
}

function modem_status() {
	let data = readfile(config_value('modem_status_path', default_modem_status_path));
	try {
		let modem = json(trim(data || '{}'));
		return {
			online: modem.online || '未知',
			online_devices: modem.online_devices || '未知',
			network_mode: modem.network_mode || '未知',
			rsrp: modem.rsrp || '未知',
			rsrq: modem.rsrq || '未知',
			sinr: modem.sinr || '未知',
			temperature: modem.temperature || '未知',
			pci: modem.pci || '未知',
			arfcn: modem.arfcn || '未知',
			wan: modem.wan || '未知',
			uptime: modem.uptime || '未知'
		};
	} catch (e) {
		return {
			online: '未知',
			online_devices: '未知',
			network_mode: '未知',
			rsrp: '未知',
			rsrq: '未知',
			sinr: '未知',
			temperature: '未知',
			pci: '未知',
			arfcn: '未知',
			wan: '未知',
			uptime: '未知'
		};
	}
}

function quota_status() {
	let interval = config_value('quota_calibration', 'off');
	if (interval != '7' && interval != '14')
		interval = 'off';
	let unknown = {
		interval,
		local_usage: '未知',
		carrier_total: '未知',
		calibrated_remaining: '未知',
		estimated_remaining: '未知',
		last_calibration: '未知',
		next_due: '未知',
		status: interval == 'off' ? 'off' : 'unknown'
	};
	let data = readfile(config_value('quota_status_path', default_quota_status_path));
	try {
		let value = json(trim(data || '{}'));
		return {
			interval: value.interval == '7' || value.interval == '14' ? value.interval : interval,
			local_usage: value.local_usage || '未知',
			carrier_total: value.carrier_total || '未知',
			calibrated_remaining: value.calibrated_remaining || '未知',
			estimated_remaining: value.estimated_remaining || '未知',
			last_calibration: value.last_calibration || '未知',
			next_due: value.next_due || '未知',
			status: value.status || unknown.status
		};
	} catch (e) {
		return unknown;
	}
}

function valid_webhook(url) {
	return type(url) == 'string' &&
		length(url) <= 512 &&
		match(url, /^https:\/\/open\.feishu\.cn\/open-apis\/bot\/v2\/hook\/[A-Za-z0-9._-]+$/);
}

function set_webhook(url) {
	if (!valid_webhook(url))
		return { code: 2 };
	let c = uci.cursor();
	if (!c.get_all('smsforward', 'settings') && !c.set('smsforward', 'settings', 'settings'))
		return { code: 3, error: 'uci_section' };
	if (!c.set('smsforward', 'settings', 'feishu_webhook', url))
		return { code: 3, error: 'uci_option' };
	if (!c.commit('smsforward'))
		return { code: 3, error: 'uci_commit' };
	return { code: 0 };
}

function scheduler_send_command(section) {
	if (!schedule_exists(section))
		return { code: 2, error: 'invalid schedule section' };
	return { code: system('/usr/bin/sms-feishu-scheduler --send ' + section + ' >/dev/null 2>&1') };
}

function restart_service() {
	if (config_value('enabled', '1') == '1')
		return { code: system('/etc/init.d/sms-feishu-forwarder enable >/dev/null 2>&1; /etc/init.d/sms-feishu-forwarder restart >/dev/null 2>&1') };
	return { code: system('/etc/init.d/sms-feishu-forwarder stop >/dev/null 2>&1; /etc/init.d/sms-feishu-forwarder disable >/dev/null 2>&1') };
}

return {
	'sms-feishu-forwarder': {
		status: {
			call: function(req) {
				return {
					forwarder: instance_state('forwarder'),
					scheduler: instance_state('scheduler'),
					latest_forwarding: readfile('/var/lib/sms-feishu-forwarder/latest.result'),
					latest_schedule: latest_schedule_result(),
					modem: modem_status(),
					quota: quota_status()
				};
			}
		},
		logs: {
			call: function(req) {
				let fp = fs.popen("logread 2>/dev/null | grep -E 'sms-feishu-forwarder|sms-feishu-scheduler' | sed -E 's#https://open\\.feishu\\.cn/open-apis/bot/v2/hook/[A-Za-z0-9._-]+#[redacted-webhook]#g; s#(IMEI|IMSI|ICCID)[=: ][A-Za-z0-9]+#\\1=[redacted]#g' | tail -n 200");
				let data = fp ? fp.read('all') : '';
				if (fp)
					fp.close();
				return { lines: split(trim(data || ''), '\n') };
			}
		},
		restart: {
			call: function(req) {
				return restart_service();
			}
		},
		seed: {
			call: function(req) {
				return { code: system('/etc/init.d/sms-feishu-forwarder stop >/dev/null 2>&1; /usr/bin/sms-feishu-forwarder --seed >/dev/null 2>&1; rc=$?; /etc/init.d/sms-feishu-forwarder restart >/dev/null 2>&1; exit $rc') };
			}
		},
		test_card: {
			call: function(req) {
				return { code: system('/usr/bin/sms-feishu-forwarder --test >/dev/null 2>&1') };
			}
		},
		send_schedule: {
			args: { section: "" },
			call: function(request) {
				let section = request && request.args && request.args.section;
				return scheduler_send_command(section);
			}
		},
		set_webhook: {
			args: { webhook: "" },
			call: function(request) {
				return set_webhook(request && request.args && request.args.webhook);
			}
		}
	}
};
