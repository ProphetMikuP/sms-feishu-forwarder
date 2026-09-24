#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

require_file()
{
	[ -f "$1" ] || {
		printf 'missing live-contract source: %s\n' "$1" >&2
		exit 1
	}
}

require_file "$ROOT/files/usr/bin/sms-feishu-forwarder"
require_file "$ROOT/files/usr/bin/sms-feishu-scheduler"
require_file "$ROOT/files/usr/lib/sms-feishu-forwarder/quota.sh"
require_file "$ROOT/packaging/RELEASE.md"

grep -Fq '/usr/sbin/mt5700m-read' "$ROOT/files/usr/bin/sms-feishu-forwarder"
grep -Fq 'sms-list' "$ROOT/files/usr/bin/sms-feishu-forwarder"
grep -Fq '/usr/sbin/mt5700m-at' "$ROOT/files/usr/bin/sms-feishu-scheduler"
grep -Fq 'sms-send-start' "$ROOT/files/usr/bin/sms-feishu-scheduler"
grep -Fq '/usr/sbin/mt5700m-read' "$ROOT/files/usr/bin/sms-feishu-scheduler"
grep -Fq 'sms-send-status' "$ROOT/files/usr/bin/sms-feishu-scheduler"
grep -Fq 'MT5700M v3.0.3' "$ROOT/packaging/RELEASE.md"

if [ -n "${MT5700M_LIVE_ROOT:-}" ]; then
	[ -x "$MT5700M_LIVE_ROOT/usr/sbin/mt5700m-read" ]
	[ -x "$MT5700M_LIVE_ROOT/usr/sbin/mt5700m-at" ]
	[ "${MT5700M_LIVE_VERSION:-}" = '3.0.3' ]
fi

printf '%s\n' 'live_contract_gate=ok'
