#!/bin/sh

set -eu

ROOT="${ROOT:-/}"
MANAGED_PATHS="usr/bin/sms-feishu-forwarder usr/bin/sms-feishu-scheduler usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk usr/lib/sms-feishu-forwarder/quota.sh usr/lib/sms-feishu-forwarder/mt5700m-cutover etc/init.d/sms-feishu-forwarder etc/config/sms-feishu-forwarder usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json usr/share/rpcd/ucode/sms-feishu-forwarder.uc www/luci-static/resources/view/sms-feishu-forwarder.js"

target()
{
	printf '%s/%s' "${ROOT%/}" "$1"
}

restore_latest_backup()
{
	local rel="$1"
	local latest src
	latest="$(ls -1dt "$ROOT"/etc/sms-feishu-forwarder/backups/* 2>/dev/null | head -n 1 || true)"
	[ -n "$latest" ] || return 0
	src="$latest/$rel"
	if [ -e "$src" ]; then
		mkdir -p "$(dirname "$(target "$rel")")"
		cp -p "$src" "$(target "$rel")"
	else
		rm -f "$(target "$rel")"
	fi
}

restore_latest_taskplan_backup()
{
	local latest src
	latest="$(ls -1dt "$ROOT"/etc/sms-feishu-forwarder/backups/* 2>/dev/null | head -n 1 || true)"
	[ -n "$latest" ] || return 0
	src="$latest/etc/config/taskplan"
	[ -e "$src" ] || return 0
	mkdir -p "$(dirname "$(target etc/config/taskplan)")"
	cp -p "$src" "$(target etc/config/taskplan)"
	restart_taskplan
}

restart_taskplan()
{
	[ -x "$(target etc/init.d/taskplan)" ] || return 0
	"$(target etc/init.d/taskplan)" restart >/dev/null 2>&1 || true
}

restart_rpcd_best_effort()
{
	[ -x "$(target etc/init.d/rpcd)" ] || return 0
	"$(target etc/init.d/rpcd)" restart >/dev/null 2>&1 || true
}

if [ "$ROOT" = "/" ] && [ -x /etc/init.d/sms-feishu-forwarder ]; then
	/etc/init.d/sms-feishu-forwarder stop >/dev/null 2>&1 || true
	/etc/init.d/sms-feishu-forwarder disable >/dev/null 2>&1 || true
fi

for rel in $MANAGED_PATHS; do
	restore_latest_backup "$rel"
done
restore_latest_taskplan_backup
restart_rpcd_best_effort

STATE_FILE="$(target etc/sms-feishu-forwarder/legacy-state)"
if [ "$ROOT" = "/" ] && [ -f "$STATE_FILE" ]; then
	smsforward_enabled=0
	smsforward_running=0
	sms_forwarder_enabled=0
	sms_forwarder_running=0
	. "$STATE_FILE"
	if [ "${smsforward_enabled:-0}" = "1" ] && [ -x /etc/init.d/smsforward ]; then
		/etc/init.d/smsforward enable >/dev/null 2>&1 || true
	fi
	if [ "${smsforward_running:-0}" = "1" ] && [ -x /etc/init.d/smsforward ]; then
		/etc/init.d/smsforward start >/dev/null 2>&1 || true
	fi
	if [ "${sms_forwarder_enabled:-0}" = "1" ] && [ -x /etc/init.d/sms_forwarder ]; then
		/etc/init.d/sms_forwarder enable >/dev/null 2>&1 || true
	fi
	if [ "${sms_forwarder_running:-0}" = "1" ] && [ -x /etc/init.d/sms_forwarder ]; then
		/etc/init.d/sms_forwarder start >/dev/null 2>&1 || true
	fi
fi

printf '%s\n' "sms-feishu-forwarder uninstalled. State and backups under /etc/sms-feishu-forwarder and /var/lib/sms-feishu-forwarder were left intact."
