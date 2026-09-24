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
CUSTOM_ENABLED=0
CUSTOM_RUNNING=0
CUSTOM_STATE_RECORDED=0
CUSTOM_CUTOVER_STARTED=0
TASKPLAN_BACKED_UP=0
SMSFORWARD_CONFIG_BACKED_UP=0
SMSFORWARD_CONFIG_EXISTED=0
CUTOVER_STATE_BACKED_UP=0
CUTOVER_TASKPLAN_SNAPSHOT=0
MANAGED_PATHS="usr/bin/sms-feishu-forwarder usr/bin/sms-feishu-scheduler usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk usr/lib/sms-feishu-forwarder/quota.sh usr/lib/sms-feishu-forwarder/mt5700m-cutover etc/init.d/sms-feishu-forwarder etc/config/sms-feishu-forwarder usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json usr/share/rpcd/ucode/sms-feishu-forwarder.uc www/luci-static/resources/view/sms-feishu-forwarder.js"

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

backup_taskplan()
{
	[ "$TASKPLAN_BACKED_UP" = "1" ] && return 0
	if [ "$CUTOVER_TASKPLAN_SNAPSHOT" = "1" ]; then
		TASKPLAN_BACKED_UP=1
		return 0
	fi
	[ -e "$(target etc/config/taskplan)" ] || return 0
	backup_path "etc/config/taskplan"
	TASKPLAN_BACKED_UP=1
}

backup_taskplan_before_cutover()
{
	[ "$CUTOVER_TASKPLAN_SNAPSHOT" = "1" ] && return 0
	[ -e "$(target etc/config/taskplan)" ] || return 0
	backup_path "etc/config/taskplan"
	CUTOVER_TASKPLAN_SNAPSHOT=1
}

backup_smsforward_config()
{
	SMSFORWARD_CONFIG_BACKED_UP=1
	if [ -e "$(target etc/config/smsforward)" ]; then
		SMSFORWARD_CONFIG_EXISTED=1
		backup_path "etc/config/smsforward"
	else
		SMSFORWARD_CONFIG_EXISTED=0
	fi
}

backup_cutover_state()
{
	local rel
	CUTOVER_STATE_BACKED_UP=1
	for rel in \
		etc/sms-feishu-forwarder/legacy-cutover-state \
		etc/sms-feishu-forwarder/mt5700m-cutover.complete \
		etc/sms-feishu-forwarder/taskplan.before-mt5700m-cutover; do
		backup_path "$rel"
	done
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
	[ -f "$f" ] && return 0
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

restart_taskplan()
{
	[ "$RUN_TARGET_ACTIONS" = "1" ] || return 0
	[ -x "$(target etc/init.d/taskplan)" ] || return 0
	"$(target etc/init.d/taskplan)" restart >/dev/null 2>&1 || true
}

restart_taskplan_required()
{
	[ "$RUN_TARGET_ACTIONS" = "1" ] || return 0
	[ -x "$(target etc/init.d/taskplan)" ] || return 0
	"$(target etc/init.d/taskplan)" restart >/dev/null 2>&1
}

restart_rpcd_required()
{
	[ "$RUN_TARGET_ACTIONS" = "1" ] || return 0
	[ -x "$(target etc/init.d/rpcd)" ] || return 0
	"$(target etc/init.d/rpcd)" restart >/dev/null 2>&1
}

restart_rpcd_best_effort()
{
	[ "$RUN_TARGET_ACTIONS" = "1" ] || return 0
	[ -x "$(target etc/init.d/rpcd)" ] || return 0
	"$(target etc/init.d/rpcd)" restart >/dev/null 2>&1 || true
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

ensure_schedule_defaults()
{
	local cfg
	cfg="$(target etc/config/sms-feishu-forwarder)"
	if ! grep -q "config schedule 'traffic_hourly'" "$cfg"; then
		cat >> "$cfg" <<'EOS'

config schedule 'traffic_hourly'
	option enabled '1'
	option name 'traffic_hourly'
	option recipient '10086'
	option content 'CXLL'
	option hour '*'
	option minute '0'
	option weekdays '*'
EOS
	fi
	if ! grep -q "config schedule 'balance_daily'" "$cfg"; then
		cat >> "$cfg" <<'EOS'

config schedule 'balance_daily'
	option enabled '1'
	option name 'balance_daily'
	option recipient '10086'
	option content 'CXYE'
	option hour '9'
	option minute '5'
	option weekdays '*'
EOS
	fi
}

disable_legacy_taskplan_sms()
{
	local cfg tmp marker
	cfg="$(target etc/config/taskplan)"
	[ -f "$cfg" ] || return 0
	if ! grep -q "/root/send_10086_sms.sh" "$cfg"; then
		return 0
	fi
	backup_taskplan
	marker="$(target etc/sms-feishu-forwarder/legacy-send_10086_sms.sh.path)"
	mkdir -p "$(dirname "$marker")"
	printf '%s\n' "/root/send_10086_sms.sh" > "$marker"
	chmod 600 "$marker"
	tmp="$(mktemp "$(dirname "$cfg")/.taskplan.XXXXXX")"
	awk '
		function flush_section(    i, disable) {
			if (count == 0)
				return
			disable = (stype == "12" && (section_legacy_customscript == 1 || (section_has_customscript == 0 && global_legacy_customscript == 1)))
			for (i = 1; i <= count; i++) {
				if (disable && lines[i] ~ /^[[:space:]]*option[[:space:]]+enable[[:space:]]+/)
					print "\toption enable '\''0'\''"
				else
					print lines[i]
			}
			count = 0
			stype = ""
			section_has_customscript = 0
			section_legacy_customscript = 0
			in_global = 0
		}
		/^config[[:space:]]/ {
			flush_section()
			if ($0 ~ /^config[[:space:]]+global([[:space:]]|$)/)
				in_global = 1
		}
		{
			count++
			lines[count] = $0
			if ($0 ~ /^[[:space:]]*option[[:space:]]+customscript[[:space:]]+/) {
				if (in_global && $0 ~ /\/root\/send_10086_sms\.sh/)
					global_legacy_customscript = 1
				if (!in_global) {
					section_has_customscript = 1
					if ($0 ~ /\/root\/send_10086_sms\.sh/)
						section_legacy_customscript = 1
				}
			}
			if ($0 ~ /^[[:space:]]*option[[:space:]]+stype[[:space:]]+'\''12'\''/)
				stype = "12"
		}
		END { flush_section() }
	' "$cfg" > "$tmp"
	chmod 600 "$tmp"
	mv "$tmp" "$cfg"
}

has_legacy_taskplan_sms()
{
	local cfg
	cfg="$(target etc/config/taskplan)"
	[ -f "$cfg" ] && grep -q "/root/send_10086_sms.sh" "$cfg"
}

set_scheduler_active()
{
	local value="$1"
	local batch
	batch="$(mktemp "$(target tmp)/smsff-uci.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/smsff-uci.XXXXXX")"
	chmod 600 "$batch"
	{
		printf 'set sms-feishu-forwarder.settings.scheduler_active=%s\n' "$value"
		printf 'commit sms-feishu-forwarder\n'
	} > "$batch"
	if ! uci -c "$(target etc/config)" batch < "$batch"; then
		rm -f "$batch"
		return 1
	fi
	rm -f "$batch"
}

migrate_legacy_webhook()
{
	local webhook batch
	webhook="$(uci -c "$(target etc/config)" -q get sms-feishu-forwarder.settings.feishu_webhook 2>/dev/null || true)"
	[ -n "$webhook" ] || return 0
	case "$webhook" in
		https://open.feishu.cn/open-apis/bot/v2/hook/*) ;;
		*) return 1 ;;
	esac
	case "$webhook" in
		*[!A-Za-z0-9:/._-]*) return 1 ;;
	esac
	backup_smsforward_config
	batch="$(mktemp "$(target tmp)/smsff-uci.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/smsff-uci.XXXXXX")"
	chmod 600 "$batch"
	{
		printf "set smsforward.settings.feishu_webhook='%s'\n" "$webhook"
		printf 'delete sms-feishu-forwarder.settings.feishu_webhook\n'
		printf 'commit smsforward\n'
		printf 'commit sms-feishu-forwarder\n'
	} > "$batch"
	if ! uci -c "$(target etc/config)" batch < "$batch"; then
		rm -f "$batch"
		return 1
	fi
	rm -f "$batch"
}

candidate_checks()
{
	local scheduler_cmd="$1"
	sh -n "$(target usr/bin/sms-feishu-forwarder)"
	sh -n "$(target usr/bin/sms-feishu-scheduler)"
	sh -n "$(target etc/init.d/sms-feishu-forwarder)"
	"$scheduler_cmd" --check
}

verify_custom_instances()
{
	local init_cmd="$1"
	local states
	if [ -n "${SMSFF_INSTALL_VERIFY_CMD:-}" ]; then
		$SMSFF_INSTALL_VERIFY_CMD
		return $?
	fi
	if [ -n "${SMSFF_INSTALL_INIT_CMD:-}" ]; then
		"$init_cmd" running
		return $?
	fi
	states="$(ubus call service list '{"name":"sms-feishu-forwarder"}' 2>/dev/null |
		jsonfilter -q -e '@["sms-feishu-forwarder"].instances.forwarder.running' -e '@["sms-feishu-forwarder"].instances.scheduler.running' |
		sed -n '1,2p')"
	[ "$states" = "true
true" ]
}

start_custom_and_verify()
{
	local init_cmd="$1"
	"$init_cmd" enable
	"$init_cmd" restart
	sleep 1
	verify_custom_instances "$init_cmd"
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

record_custom_state()
{
	CUSTOM_STATE_RECORDED=1
	CUSTOM_ENABLED=0
	CUSTOM_RUNNING=0
	[ -x "$(target etc/init.d/sms-feishu-forwarder)" ] || return 0
	if "$(target etc/init.d/sms-feishu-forwarder)" enabled >/dev/null 2>&1; then
		CUSTOM_ENABLED=1
	fi
	if "$(target etc/init.d/sms-feishu-forwarder)" running >/dev/null 2>&1; then
		CUSTOM_RUNNING=1
	fi
}

stop_running_custom_service()
{
	local init_cmd
	[ "$RUN_TARGET_ACTIONS" = "1" ] || return 0
	[ "$CUSTOM_STATE_RECORDED" = "1" ] || return 0
	[ "$CUSTOM_RUNNING" = "1" ] || return 0
	init_cmd="${SMSFF_INSTALL_INIT_CMD:-$(target etc/init.d/sms-feishu-forwarder)}"
	[ -x "$init_cmd" ] || return 0
	"$init_cmd" stop >/dev/null 2>&1 || true
}

restore_custom_state()
{
	local init_cmd
	[ "$RUN_TARGET_ACTIONS" = "1" ] || return 0
	[ "$CUSTOM_STATE_RECORDED" = "1" ] || return 0
	init_cmd="${SMSFF_INSTALL_INIT_CMD:-$(target etc/init.d/sms-feishu-forwarder)}"
	[ -x "$init_cmd" ] || return 0
	if [ "$CUSTOM_ENABLED" = "1" ]; then
		"$init_cmd" enable >/dev/null 2>&1 || true
	else
		"$init_cmd" disable >/dev/null 2>&1 || true
	fi
	if [ "$CUSTOM_RUNNING" = "1" ]; then
		"$init_cmd" start >/dev/null 2>&1 || true
	else
		"$init_cmd" stop >/dev/null 2>&1 || true
	fi
}

restore_smsforward_config()
{
	[ "$SMSFORWARD_CONFIG_BACKED_UP" = "1" ] || return 0
	if [ "$SMSFORWARD_CONFIG_EXISTED" = "1" ]; then
		restore_managed_path "etc/config/smsforward"
	else
		rm -f "$(target etc/config/smsforward)"
	fi
}

restore_mt5700m_cutover_service_state()
{
	local state_file="$ROOT/etc/sms-feishu-forwarder/legacy-cutover-state"
	local init_cmd="$(target etc/init.d/ubus-at-daemon)"
	local enabled running
	[ -f "$state_file" ] || return 0
	[ -x "$init_cmd" ] || return 0
	enabled="$(sed -n 's/^ubus-at-daemon_enabled=//p' "$state_file" | sed -n '1p')"
	running="$(sed -n 's/^ubus-at-daemon_running=//p' "$state_file" | sed -n '1p')"
	case "$enabled:$running" in
		0:0|0:1|1:0|1:1) ;;
		*) return 1 ;;
	esac
	if [ "$enabled" = "1" ]; then
		"$init_cmd" enable >/dev/null 2>&1
	else
		"$init_cmd" disable >/dev/null 2>&1
	fi
	if [ "$running" = "1" ]; then
		"$init_cmd" start >/dev/null 2>&1
	else
		"$init_cmd" stop >/dev/null 2>&1
	fi
}

restore_cutover_state_files()
{
	local rel
	[ "$CUTOVER_STATE_BACKED_UP" = "1" ] || return 0
	for rel in \
		etc/sms-feishu-forwarder/legacy-cutover-state \
		etc/sms-feishu-forwarder/mt5700m-cutover.complete \
		etc/sms-feishu-forwarder/taskplan.before-mt5700m-cutover; do
		restore_managed_path "$rel"
	done
}

rollback_install()
{
	local rel
	[ "$INSTALL_SUCCEEDED" = "0" ] || return 0
	printf '%s\n' "Install failed; rolling back installed files and legacy service state." >&2
	if [ "$CUSTOM_CUTOVER_STARTED" = "1" ] && [ "$RUN_TARGET_ACTIONS" = "1" ] && [ -x "$(target etc/init.d/sms-feishu-forwarder)" ]; then
		"$(target etc/init.d/sms-feishu-forwarder)" stop >/dev/null 2>&1 || true
		"$(target etc/init.d/sms-feishu-forwarder)" disable >/dev/null 2>&1 || true
	fi
	if [ "$CUSTOM_CUTOVER_STARTED" = "1" ]; then
		restore_mt5700m_cutover_service_state || true
	fi
	for rel in $MANAGED_PATHS; do
		restore_managed_path "$rel"
	done
	if [ "$TASKPLAN_BACKED_UP" = "1" ]; then
		restore_managed_path "etc/config/taskplan"
		restart_taskplan
	fi
	restore_smsforward_config
	restart_rpcd_best_effort
	if [ "$CUSTOM_CUTOVER_STARTED" = "1" ]; then
		restore_custom_state
		restore_cutover_state_files
	fi
	restore_legacy_state
}

trap rollback_install EXIT

mkdir -p "$(target var/lib/sms-feishu-forwarder)" "$BACKUP_DIR"
chmod 700 "$(target var/lib/sms-feishu-forwarder)"
backup_cutover_state
record_legacy_state
record_custom_state
smsforward_enabled=0
smsforward_running=0
sms_forwarder_enabled=0
sms_forwarder_running=0
. "$(target etc/sms-feishu-forwarder/legacy-state)"
if [ -e "$(target var/lib/sms-feishu-forwarder/seen.keys)" ]; then
	SEEN_STATE_EXISTED=1
else
	SEEN_STATE_EXISTED=0
fi

install_file "$SRC_DIR/files/usr/bin/sms-feishu-forwarder" "usr/bin/sms-feishu-forwarder" 700
install_file "$SRC_DIR/files/usr/bin/sms-feishu-scheduler" "usr/bin/sms-feishu-scheduler" 700
install_file "$SRC_DIR/files/usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk" "usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk" 600
install_file "$SRC_DIR/files/usr/lib/sms-feishu-forwarder/quota.sh" "usr/lib/sms-feishu-forwarder/quota.sh" 600
install_file "$SRC_DIR/files/usr/lib/sms-feishu-forwarder/mt5700m-cutover" "usr/lib/sms-feishu-forwarder/mt5700m-cutover" 700
install_file "$SRC_DIR/files/etc/init.d/sms-feishu-forwarder" "etc/init.d/sms-feishu-forwarder" 755
install_file "$SRC_DIR/files/usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json" "usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json" 644
install_file "$SRC_DIR/files/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json" "usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json" 644
install_file "$SRC_DIR/files/usr/share/rpcd/ucode/sms-feishu-forwarder.uc" "usr/share/rpcd/ucode/sms-feishu-forwarder.uc" 755
install_file "$SRC_DIR/files/www/luci-static/resources/view/sms-feishu-forwarder.js" "www/luci-static/resources/view/sms-feishu-forwarder.js" 644
if [ ! -e "$(target etc/config/sms-feishu-forwarder)" ]; then
	install_file "$SRC_DIR/files/etc/config/sms-feishu-forwarder" "etc/config/sms-feishu-forwarder" 600
else
	backup_path "etc/config/sms-feishu-forwarder"
	migrate_legacy_webhook
	ensure_schedule_defaults
fi

restart_rpcd_required

if [ "$RUN_TARGET_ACTIONS" = "1" ]; then
	if [ -n "${SMSFF_INSTALL_FORWARDER_CMD:-}" ]; then
		FORWARDER_CMD="$SMSFF_INSTALL_FORWARDER_CMD"
	else
		FORWARDER_CMD="$(target usr/bin/sms-feishu-forwarder)"
	fi
	if [ -n "${SMSFF_INSTALL_SCHEDULER_CMD:-}" ]; then
		SCHEDULER_CMD="$SMSFF_INSTALL_SCHEDULER_CMD"
	else
		SCHEDULER_CMD="$(target usr/bin/sms-feishu-scheduler)"
	fi
	if [ -n "${SMSFF_INSTALL_INIT_CMD:-}" ]; then
		INIT_CMD="$SMSFF_INSTALL_INIT_CMD"
	else
		INIT_CMD="$(target etc/init.d/sms-feishu-forwarder)"
	fi
	candidate_checks "$SCHEDULER_CMD"
	if has_legacy_taskplan_sms; then
		backup_taskplan_before_cutover
	fi
	CUSTOM_CUTOVER_STARTED=1
	stop_running_custom_service
	if [ "$SEEN_STATE_EXISTED" = "0" ]; then
		"$FORWARDER_CMD" --seed
	fi
	"$FORWARDER_CMD" --once
	if has_legacy_taskplan_sms; then
		set_scheduler_active 0
		start_custom_and_verify "$INIT_CMD"
		disable_legacy_taskplan_sms
		restart_taskplan_required
		set_scheduler_active 1
		start_custom_and_verify "$INIT_CMD"
	else
		set_scheduler_active 1
		start_custom_and_verify "$INIT_CMD"
	fi
	disable_legacy_after_success
else
	chmod 600 "$(target etc/config/sms-feishu-forwarder)" 2>/dev/null || true
	printf '%s\n' "Installed into ROOT=$ROOT. Run seeding and service enable on the target root."
fi

INSTALL_SUCCEEDED=1
