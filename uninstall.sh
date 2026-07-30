#!/bin/sh

set -eu

ROOT="${ROOT:-/}"

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
	fi
}

if [ "$ROOT" = "/" ] && [ -x /etc/init.d/sms-feishu-forwarder ]; then
	/etc/init.d/sms-feishu-forwarder stop >/dev/null 2>&1 || true
	/etc/init.d/sms-feishu-forwarder disable >/dev/null 2>&1 || true
fi

rm -f "$(target usr/bin/sms-feishu-forwarder)" "$(target etc/init.d/sms-feishu-forwarder)"
restore_latest_backup "etc/config/sms-feishu-forwarder"

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
