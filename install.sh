#!/bin/sh

set -eu
umask 077

ROOT="${ROOT:-/}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$ROOT/etc/sms-feishu-forwarder/backups/$STAMP"
SCRIPT_DIR="$(dirname -- "$0")"
SRC_DIR="$(CDPATH= cd -- "$SCRIPT_DIR" && pwd)"
INSTALL_SUCCEEDED=0
RUN_TARGET_ACTIONS=0
MANAGED_PATHS="usr/bin/sms-feishu-forwarder etc/init.d/sms-feishu-forwarder etc/config/sms-feishu-forwarder"

[ "$ROOT" = "/" ] && RUN_TARGET_ACTIONS=1
[ "${SMSFF_INSTALL_RUN_TARGET_ACTIONS:-0}" = "1" ] && RUN_TARGET_ACTIONS=1

target()
{
	printf '%s/%s' "${ROOT%/}" "$1"
}

backup_path()
{
	local rel="$1"
	local dst
	dst="$BACKUP_DIR/$rel"
	if [ -e "$(target "$rel")" ]; then
		mkdir -p "$(dirname "$dst")"
		cp -p "$(target "$rel")" "$dst"
	fi
}

install_file()
{
	local src="$1"
	local rel="$2"
	local mode="$3"
	local dir tmp
	dir="$(dirname "$(target "$rel")")"
	mkdir -p "$dir"
	backup_path "$rel"
	tmp="$(mktemp "$dir/.install.XXXXXX")"
	cp "$src" "$tmp"
	chmod "$mode" "$tmp"
	mv "$tmp" "$(target "$rel")"
}

restore_managed_path()
{
	local rel="$1"
	local src
	src="$BACKUP_DIR/$rel"
	if [ -e "$src" ]; then
		mkdir -p "$(dirname "$(target "$rel")")"
		cp -p "$src" "$(target "$rel")"
	else
		rm -f "$(target "$rel")"
	fi
}

record_legacy_state()
{
	local f="$ROOT/etc/sms-feishu-forwarder/legacy-state"
	mkdir -p "$(dirname "$f")"
	{
		if [ -x "$(target etc/init.d/smsforward)" ]; then
			if "$(target etc/init.d/smsforward)" enabled >/dev/null 2>&1; then
				printf 'smsforward_enabled=1\n'
			else
				printf 'smsforward_enabled=0\n'
			fi
			if "$(target etc/init.d/smsforward)" running >/dev/null 2>&1; then
				printf 'smsforward_running=1\n'
			else
				printf 'smsforward_running=0\n'
			fi
		fi
		if [ -x "$(target etc/init.d/sms_forwarder)" ]; then
			if "$(target etc/init.d/sms_forwarder)" enabled >/dev/null 2>&1; then
				printf 'sms_forwarder_enabled=1\n'
			else
				printf 'sms_forwarder_enabled=0\n'
			fi
			if "$(target etc/init.d/sms_forwarder)" running >/dev/null 2>&1; then
				printf 'sms_forwarder_running=1\n'
			else
				printf 'sms_forwarder_running=0\n'
			fi
		fi
	} > "$f"
	chmod 600 "$f"
}

disable_legacy_after_success()
{
	if { [ "${smsforward_enabled:-0}" = "1" ] || [ "${smsforward_running:-0}" = "1" ]; } && [ -x "$(target etc/init.d/smsforward)" ]; then
		"$(target etc/init.d/smsforward)" stop >/dev/null 2>&1 || true
		"$(target etc/init.d/smsforward)" disable >/dev/null 2>&1 || true
	fi
	if [ "${sms_forwarder_enabled:-0}" = "1" ] && [ -x "$(target etc/init.d/sms_forwarder)" ]; then
		"$(target etc/init.d/sms_forwarder)" stop >/dev/null 2>&1 || true
		"$(target etc/init.d/sms_forwarder)" disable >/dev/null 2>&1 || true
	fi
}

restore_legacy_state()
{
	local f="$ROOT/etc/sms-feishu-forwarder/legacy-state"
	[ -f "$f" ] || return 0
	smsforward_enabled=0
	smsforward_running=0
	sms_forwarder_enabled=0
	sms_forwarder_running=0
	. "$f"
	if [ "${smsforward_enabled:-0}" = "1" ]; then
		"$(target etc/init.d/smsforward)" enable >/dev/null 2>&1 || true
	fi
	if [ "${smsforward_running:-0}" = "1" ]; then
		"$(target etc/init.d/smsforward)" start >/dev/null 2>&1 || true
	fi
	if [ "${sms_forwarder_enabled:-0}" = "1" ]; then
		"$(target etc/init.d/sms_forwarder)" enable >/dev/null 2>&1 || true
	fi
	if [ "${sms_forwarder_running:-0}" = "1" ]; then
		"$(target etc/init.d/sms_forwarder)" start >/dev/null 2>&1 || true
	fi
}

rollback_install()
{
	local rel
	[ "$INSTALL_SUCCEEDED" = "0" ] || return 0
	printf '%s\n' "Install failed; rolling back installed files and legacy service state." >&2
	if [ "$RUN_TARGET_ACTIONS" = "1" ] && [ -x "$(target etc/init.d/sms-feishu-forwarder)" ]; then
		"$(target etc/init.d/sms-feishu-forwarder)" stop >/dev/null 2>&1 || true
		"$(target etc/init.d/sms-feishu-forwarder)" disable >/dev/null 2>&1 || true
	fi
	for rel in $MANAGED_PATHS; do
		restore_managed_path "$rel"
	done
	restore_legacy_state
}

trap rollback_install EXIT

mkdir -p "$(target var/lib/sms-feishu-forwarder)" "$BACKUP_DIR"
chmod 700 "$(target var/lib/sms-feishu-forwarder)"
record_legacy_state
smsforward_enabled=0
smsforward_running=0
sms_forwarder_enabled=0
sms_forwarder_running=0
. "$(target etc/sms-feishu-forwarder/legacy-state)"

install_file "$SRC_DIR/files/usr/bin/sms-feishu-forwarder" "usr/bin/sms-feishu-forwarder" 700
install_file "$SRC_DIR/files/etc/init.d/sms-feishu-forwarder" "etc/init.d/sms-feishu-forwarder" 755
if [ ! -e "$(target etc/config/sms-feishu-forwarder)" ]; then
	install_file "$SRC_DIR/files/etc/config/sms-feishu-forwarder" "etc/config/sms-feishu-forwarder" 600
else
	backup_path "etc/config/sms-feishu-forwarder"
fi

if [ "$RUN_TARGET_ACTIONS" = "1" ]; then
	if [ -n "${SMSFF_INSTALL_FORWARDER_CMD:-}" ]; then
		FORWARDER_CMD="$SMSFF_INSTALL_FORWARDER_CMD"
	else
		FORWARDER_CMD="$(target usr/bin/sms-feishu-forwarder)"
	fi
	if [ -n "${SMSFF_INSTALL_INIT_CMD:-}" ]; then
		INIT_CMD="$SMSFF_INSTALL_INIT_CMD"
	else
		INIT_CMD="$(target etc/init.d/sms-feishu-forwarder)"
	fi
	"$FORWARDER_CMD" --seed
	"$FORWARDER_CMD" --once
	disable_legacy_after_success
	"$INIT_CMD" enable
	if ! "$INIT_CMD" restart; then
		exit 1
	fi
	sleep 1
	if ! "$INIT_CMD" running; then
		exit 1
	fi
else
	chmod 600 "$(target etc/config/sms-feishu-forwarder)" 2>/dev/null || true
	printf '%s\n' "Installed into ROOT=$ROOT. Run seeding and service enable on the target root."
fi

INSTALL_SUCCEEDED=1
