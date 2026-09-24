#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DAEMON="$ROOT/files/usr/bin/sms-feishu-forwarder"
SCHEDULER="$ROOT/files/usr/bin/sms-feishu-scheduler"
TMP_ROOT="${TMPDIR:-/tmp}/sms-feishu-forwarder-tests.$$"
PASS=0
FAIL=0

cleanup()
{
	rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$TMP_ROOT"

fail()
{
	printf 'not ok - %s\n' "$1"
	FAIL=$((FAIL + 1))
}

pass()
{
	printf 'ok - %s\n' "$1"
	PASS=$((PASS + 1))
}

assert_eq()
{
	local name="$1"
	local got="$2"
	local want="$3"
	if [ "$got" = "$want" ]; then
		pass "$name"
	else
		fail "$name: got [$got], want [$want]"
	fi
}

assert_file_lines()
{
	local name="$1"
	local file="$2"
	local want="$3"
	local got
	if [ -f "$file" ]; then
		got="$(wc -l < "$file")"
	else
		got=0
	fi
	assert_eq "$name" "$got" "$want"
}

assert_file_absent()
{
	local name="$1"
	local file="$2"
	if [ ! -e "$file" ]; then
		pass "$name"
	else
		fail "$name: $file exists"
	fi
}

assert_file_content()
{
	local name="$1"
	local file="$2"
	local want="$3"
	local got
	if [ -f "$file" ]; then
		got="$(cat "$file")"
	else
		got=""
	fi
	assert_eq "$name" "$got" "$want"
}

assert_body_count()
{
	local name="$1"
	local want="$2"
	assert_file_lines "$name" "$TEST_BODIES" "$want"
}

install_jq_no_regex_wrapper()
{
	local real_jq="$1"
	cat > "$MOCK_BIN/jq" <<'EOS'
#!/bin/sh
for arg in "$@"; do
	case "$arg" in
		*'test('*|*'match('*|*'sub('*|*'gsub('*)
			printf '%s\n' "jq regex builtin is unavailable on target" >&2
			exit 97
			;;
	esac
done
exec "$TEST_REAL_JQ" "$@"
EOS
	chmod +x "$MOCK_BIN/jq"
	export TEST_REAL_JQ="$real_jq"
}

make_mocks()
{
	local dir="$1"
	mkdir -p "$dir"
cat > "$dir/uci" <<'EOS'
#!/bin/sh
[ "$1" = "-c" ] && { shift; UCI_CONFIG_DIR="$1"; shift; }
[ "$1" = "-q" ] && shift
[ "$1" = "-c" ] && { shift; UCI_CONFIG_DIR="$1"; shift; }
[ "$1" = "-q" ] && shift
[ "$1" = "batch" ] && {
	batch="$(cat)"
	[ -n "${TEST_UCI_BATCH_LOG:-}" ] && printf '%s\n' "$batch" >> "$TEST_UCI_BATCH_LOG"
	if [ -n "${TEST_UCI_FAIL_BATCH_CONTAINS:-}" ] && printf '%s\n' "$batch" | grep -q "$TEST_UCI_FAIL_BATCH_CONTAINS"; then
		exit 1
	fi
	if [ -n "${UCI_CONFIG_DIR:-}" ]; then
		smsforward_cfg="$UCI_CONFIG_DIR/smsforward"
		smsff_cfg="$UCI_CONFIG_DIR/sms-feishu-forwarder"
		webhook="$(printf '%s\n' "$batch" | sed -n "s/^set smsforward\.settings\.feishu_webhook='\(.*\)'$/\1/p" | sed -n '1p')"
		if [ -n "$webhook" ]; then
			mkdir -p "$UCI_CONFIG_DIR"
			if [ ! -f "$smsforward_cfg" ]; then
				{
					printf "config settings 'settings'\n"
					printf "\toption feishu_webhook '%s'\n" "$webhook"
				} > "$smsforward_cfg"
			elif grep -q "^[[:space:]]*option[[:space:]]\\+feishu_webhook[[:space:]]" "$smsforward_cfg"; then
				tmp="$smsforward_cfg.tmp.$$"
				sed "s#^[[:space:]]*option[[:space:]]\\+feishu_webhook[[:space:]].*#	option feishu_webhook '$webhook'#" "$smsforward_cfg" > "$tmp" && mv "$tmp" "$smsforward_cfg"
			else
				printf "\toption feishu_webhook '%s'\n" "$webhook" >> "$smsforward_cfg"
			fi
		fi
	fi
	case "$batch" in
		*"delete sms-feishu-forwarder.settings.feishu_webhook"*)
			cfg="${smsff_cfg:-${UCI_CONFIG_DIR:-/etc/config}/sms-feishu-forwarder}"
			if [ -f "$cfg" ]; then
				tmp="$cfg.tmp.$$"
				sed "/^[[:space:]]*option[[:space:]]\\+feishu_webhook[[:space:]]/d" "$cfg" > "$tmp" && mv "$tmp" "$cfg"
			fi
			;;
	esac
	exit 0
}
[ "$1" = "show" ] && [ "$2" = "sms-feishu-forwarder" ] && {
	printf '%s\n' "${TEST_UCI_SHOW:-}"
	exit 0
}
[ "$1" = "get" ] || exit 1
key="$2"
if [ -n "${UCI_CONFIG_DIR:-}" ] && [ -f "$UCI_CONFIG_DIR/${key%%.*}" ]; then
	value="$(awk -v section="${key#*.}" '
		BEGIN {
			option = section
			sub(/^[^.]*\./, "", option)
			section_name = section
			sub(/\..*$/, "", section_name)
			in_section = 0
		}
		$1 == "config" {
			in_section = ($3 == "'"'"'" section_name "'"'"'")
		}
		in_section && $1 == "option" && $2 == option {
			sub(/^[[:space:]]*option[[:space:]]+[^[:space:]]+[[:space:]]+'\''/, "")
			sub(/'\''[[:space:]]*$/, "")
			print
			found = 1
			exit
		}
		END { exit found ? 0 : 1 }
	' "$UCI_CONFIG_DIR/${key%%.*}")" && {
		printf '%s\n' "$value"
		exit 0
	}
fi
if [ -n "${TEST_UCI_GETS:-}" ] && [ -f "$TEST_UCI_GETS" ]; then
	value="$(awk -v key="$key" 'BEGIN { FS = "\t"; found = 0 } $1 == key { sub(/^[^\t]*\t/, ""); print; found = 1; exit } END { exit found ? 0 : 1 }' "$TEST_UCI_GETS")" && {
		printf '%s\n' "$value"
		exit 0
	}
fi
	case "$2" in
	sms-feishu-forwarder.settings.enabled) printf '%s\n' "${SMSFF_ENABLED:-1}" ;;
	sms-feishu-forwarder.settings.modem_section) printf '%s\n' "${SMSFF_MODEM_SECTION:-2_1}" ;;
	sms-feishu-forwarder.settings.modem_status_path) printf '%s\n' "${SMSFF_MODEM_STATUS_PATH:-$CASE_DIR/modem-status.json}" ;;
	sms-feishu-forwarder.settings.ubus_timeout) printf '%s\n' "${SMSFF_UBUS_TIMEOUT:-3}" ;;
	sms-feishu-forwarder.settings.sms_port) printf '%s\n' "${SMSFF_SMS_PORT:-/dev/ttyUSB2}" ;;
	sms-feishu-forwarder.settings.poll_interval) printf '%s\n' "${SMSFF_POLL_INTERVAL:-10}" ;;
	sms-feishu-forwarder.settings.settle_delay) printf '%s\n' "${SMSFF_SETTLE_DELAY:-0}" ;;
	sms-feishu-forwarder.settings.attach_status) printf '%s\n' "${SMSFF_ATTACH_STATUS:-0}" ;;
	sms-feishu-forwarder.settings.state_path) printf '%s\n' "$SMSFF_STATE_PATH" ;;
	sms-feishu-forwarder.settings.schedule_state_dir) printf '%s\n' "${SMSFF_SCHEDULE_STATE_DIR:-$CASE_DIR/schedule-state}" ;;
	sms-feishu-forwarder.settings.feishu_webhook) exit 1 ;;
	smsforward.settings.feishu_webhook) printf '%s\n' 'https://open.feishu.cn/open-apis/bot/v2/hook/00000000-0000-0000-0000-000000000000' ;;
	*)
		value="$(printf '%s\n' "${TEST_UCI_SHOW:-}" | sed -n "s/^$key='\\(.*\\)'$/\\1/p" | sed -n '1p')"
		[ -n "$value" ] || exit 1
		printf '%s\n' "$value"
		;;
esac
EOS
cat > "$dir/ubus" <<'EOS'
#!/bin/sh
if [ "$1" = "-t" ]; then
	printf '%s\n' "$2" >> "${TEST_UBUS_TIMEOUT_LOG:-/dev/null}"
	shift 2
fi
if [ -n "${TEST_UBUS_LOG:-}" ]; then
	printf '%s\n' "$*" >> "$TEST_UBUS_LOG"
fi
if [ "$1" = "call" ] && [ "$2" = "qmodem_sms" ] && [ "$3" = "list_sms" ]; then
	cat "$TEST_FIXTURE"
	exit 0
fi
if [ "$1" = "call" ] && [ "$2" = "qmodem_sms" ] && [ "$3" = "mark_forwarded" ]; then
	printf '%s\n' "$4" >> "$TEST_MARKS"
	exit 0
fi
if [ "$1" = "call" ] && [ "$2" = "qmodem" ] && [ "$3" = "get_connect_status" ]; then
	printf '%s\n' "${TEST_CONNECT_STATUS:-{\"status\":\"connected\"}}"
	exit 0
fi
if [ "$1" = "call" ] && [ "$2" = "qmodem" ] && [ "$3" = "base_info" ]; then
	printf '%s\n' "${TEST_BASE_INFO:-{\"temperature\":\"45\"}}"
	exit 0
fi
if [ "$1" = "call" ] && [ "$2" = "qmodem" ] && [ "$3" = "cell_info" ]; then
	printf '%s\n' "${TEST_CELL_INFO:-{\"network_mode\":\"NR5G\",\"RSRP\":\"-88\",\"RSRQ\":\"-11\",\"SINR\":\"19\",\"Physical Cell ID\":\"321\",\"ARFCN\":\"633984\"}}"
	exit 0
fi
if [ "$1" = "call" ] && [ "$2" = "at-daemon" ] && { [ "$3" = "sendat" ] || [ "$3" = "sendsms" ]; }; then
	payload="$4"
	printf '%s\n' "$3 $payload" >> "${TEST_AT_DAEMON_LOG:-/dev/null}"
	if [ "${TEST_AT_DAEMON_LOCK_STATE_DIR:-0}" = "1" ]; then
		chmod 500 "$SMSFF_SCHEDULE_STATE_DIR"
	fi
	if printf '%s' "$payload" | "$TEST_REAL_JQ" -e '.at_cmd == "AT+CMGF=0"' >/dev/null 2>&1; then
		printf '%s\n' '{"status":"success","response":"\r\nOK\r\n","end_flag_matched":"OK"}'
		exit 0
	fi
	case "${TEST_AT_DAEMON_RESPONSE:-confirmed}" in
		confirmed) printf '%s\n' '{"status":"success","response":"\r\n+CMGS: 7\r\nOK\r\n","end_flag_matched":"OK"}' ;;
		bare_ok) printf '%s\n' '{"status":"success","response":"\r\nOK\r\n","end_flag_matched":"OK"}' ;;
		cmgs_error) printf '%s\n' '{"status":"success","response":"\r\n+CMS ERROR: 500\r\n","end_flag_matched":"+CMS ERROR:"}' ;;
	esac
	exit 0
fi
if [ "$1" = "call" ] && [ "$2" = "network.interface" ] && [ "$3" = "dump" ]; then
	printf '%s\n' "${TEST_NETWORK_DUMP:-{\"interface\":[{\"interface\":\"wan\",\"route\":[{\"target\":\"0.0.0.0\",\"source\":\"10.23.45.67/32\"}]}]}}"
	exit 0
fi
exit 1
EOS
	cat > "$dir/curl" <<'EOS'
#!/bin/sh
body=""
out=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		-o)
			shift
			out="$1"
			;;
		--data-binary)
			shift
			body="${1#@}"
			;;
	esac
	shift
done
if [ -n "$body" ]; then
	jq -c . "$body" >> "$TEST_BODIES"
fi
[ -n "$out" ] || out="$TEST_CURL_RESPONSE"
printf '%s' "${CURL_BODY:-{\"code\":0}}" > "$out"
printf '%s' "${CURL_HTTP_CODE:-200}"
EOS
	cat > "$dir/logger" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "${TEST_LOGGER:-/dev/null}"
exit 0
EOS
cat > "$dir/sms_tool_q" <<'EOS'
#!/bin/sh
if [ -n "${TEST_SMS_TOOL_ASSERT_RUNNING_SECTION:-}" ]; then
	section="$TEST_SMS_TOOL_ASSERT_RUNNING_SECTION"
	[ "$(cat "$SMSFF_SCHEDULE_STATE_DIR/$section.last_slot" 2>/dev/null)" = "$SMSFF_NOW_SLOT" ] || exit 7
	[ "$(cat "$SMSFF_SCHEDULE_STATE_DIR/$section.result" 2>/dev/null)" = "running" ] || exit 8
fi
if [ -n "${TEST_SMS_TOOL_SLEEP:-}" ]; then
	sleep "$TEST_SMS_TOOL_SLEEP"
fi
printf '%s\n' "$*" >> "$TEST_SMS_TOOL_LOG"
case "${TEST_SMS_TOOL_RESPONSE:-confirmed}" in
	confirmed)
		printf '%s\n' '+CMGS: 1' 'OK'
		;;
	no_cmgs)
		printf '%s\n' 'OK'
		;;
	ok_before_cmgs)
		printf '%s\n' 'OK' '+CMGS: 1'
		;;
	cmgs_only)
		printf '%s\n' '+CMGS: 1'
		;;
	terminal_error)
		printf '%s\n' '+CMGS: 1' 'OK' 'ERROR'
		;;
	cmgs_error)
		printf '%s\n' '+CMGS: 1' '+CMS ERROR: 500'
		;;
esac
[ "${TEST_SMS_TOOL_FAIL:-0}" = "1" ] && exit 1
exit 0
EOS
	cat > "$dir/sleep" <<'EOS'
#!/bin/sh
	if [ -n "${TEST_SLEEP_LOG:-}" ]; then
		printf '%s\n' "$*" >> "$TEST_SLEEP_LOG"
	fi
	if [ "${TEST_SLEEP_FAST:-0}" = "1" ]; then
		exit 0
	fi
	if [ -n "${TEST_SLEEP_HOLD_FILE:-}" ] && [ -e "$TEST_SLEEP_HOLD_FILE" ]; then
		[ -n "${TEST_SLEEP_STARTED:-}" ] && : > "$TEST_SLEEP_STARTED"
		while [ -e "$TEST_SLEEP_HOLD_FILE" ]; do
			/bin/sleep 0.05
	done
	exit 0
fi
/bin/sleep "$@"
EOS
	chmod +x "$dir/uci" "$dir/ubus" "$dir/curl" "$dir/logger" "$dir/sms_tool_q" "$dir/sleep"
}

make_mt5700m_mock()
{
	local dir="$1"
	cat > "$dir/mt5700m-at" <<'EOS'
#!/bin/sh
case "$1" in
	sms-list)
		printf '%s\n' sms-list >> "$TEST_MT5700M_LOG"
		cat "${TEST_MT5700M_FIXTURE:-$TEST_FIXTURE}"
		;;
	command)
		printf '%s\n' "$*" >> "$TEST_MT5700M_LOG"
		case "$2" in
			'AT^HCSQ?') printf '%s\n' "${TEST_MT5700M_HCSQ:-}" ;;
			'AT^MONSC') printf '%s\n' "${TEST_MT5700M_MONSC:-}" ;;
			*) exit 1 ;;
		esac
		;;
	temperature)
		printf '%s\n' temperature >> "$TEST_MT5700M_LOG"
		printf '%s\n' "${TEST_MT5700M_TEMPERATURE:-}"
		;;
	sms-send-start)
		printf '%s\n' "$*" >> "$TEST_MT5700M_LOG"
		[ "${TEST_MT5700M_START_FAIL:-0}" = "1" ] && exit 75
		printf '%s\n' 'job=job.ABC123'
		;;
	*)
		exit 1
		;;
esac
EOS
	chmod +x "$dir/mt5700m-at"
	cat > "$dir/mt5700m-read" <<'EOS'
#!/bin/sh
case "$1" in
	sms-list)
		printf '%s\n' sms-list >> "$TEST_MT5700M_LOG"
		cat "${TEST_MT5700M_FIXTURE:-$TEST_FIXTURE}"
		;;
	sms-send-status)
		printf '%s\n' "state=${TEST_MT5700M_JOB_STATE:-done}"
		[ "${TEST_MT5700M_JOB_STATE:-done}" = done ] && printf '%s\n' "code=${TEST_MT5700M_JOB_CODE:-0}" 'SMS submitted'
		;;
	*) exec "$(dirname "$0")/mt5700m-at" "$@" ;;
esac
EOS
	cat > "$dir/mt5700m-manager" <<'EOS'
#!/bin/sh
[ "$1" = status-json ] || exit 1
printf '%s\n' '{"connected":true,"interface":"eth2","ip4_up":true,"internet4_ok":true}'
EOS
	chmod +x "$dir/mt5700m-read" "$dir/mt5700m-manager"
}

write_init_mock()
{
	local root="$1"
	local name="$2"
	local enabled="$3"
	local running="$4"
	local path="$root/etc/init.d/$name"
	mkdir -p "$root/etc/init.d" "$CASE_DIR/service-state"
	printf '%s\n' "$enabled" > "$CASE_DIR/service-state/$name.enabled"
	printf '%s\n' "$running" > "$CASE_DIR/service-state/$name.running"
	cat > "$path" <<'EOS'
#!/bin/sh
name="${0##*/}"
state_dir="$SERVICE_STATE_DIR"
printf '%s %s\n' "$name" "$1" >> "$SERVICE_LOG"
case "$1" in
	enabled)
		[ "$(cat "$state_dir/$name.enabled")" = "1" ]
		;;
	running)
		[ "$(cat "$state_dir/$name.running")" = "1" ]
		;;
	enable)
		printf '1\n' > "$state_dir/$name.enabled"
		;;
	disable)
		printf '0\n' > "$state_dir/$name.enabled"
		;;
	start)
		printf '1\n' > "$state_dir/$name.running"
		;;
	stop)
		printf '0\n' > "$state_dir/$name.running"
		;;
	restart)
		if [ "$name" = "sms-feishu-forwarder" ] && [ "${TEST_INIT_RUN_CUTOVER:-0}" = "1" ]; then
			[ -x "$INSTALL_ROOT/usr/lib/sms-feishu-forwarder/mt5700m-cutover" ] || exit 10
			ROOT="$INSTALL_ROOT" busybox ash "$INSTALL_ROOT/usr/lib/sms-feishu-forwarder/mt5700m-cutover" || exit 11
		fi
		if [ "$name" = "sms-feishu-forwarder" ] && [ "${INSTALL_FAIL_RESTART:-0}" = "1" ]; then
			exit 1
		fi
		if [ "$name" = "sms-feishu-forwarder" ] && [ "${INSTALL_RESTART_LIES:-0}" = "1" ]; then
			printf '0\n' > "$state_dir/$name.running"
			exit 0
		fi
		if [ "$name" = "taskplan" ] && [ "${INSTALL_FAIL_TASKPLAN_RESTART_AFTER_CUTOVER:-0}" = "1" ] && [ -e "$INSTALL_ROOT/etc/sms-feishu-forwarder/mt5700m-cutover.complete" ]; then
			exit 1
		fi
		if [ "$name" = "taskplan" ] && [ "${INSTALL_FAIL_TASKPLAN_RESTART:-0}" = "1" ]; then
			exit 1
		fi
		if [ "$name" = "rpcd" ] && [ -n "${TEST_RPCD_ASSERT_INSTALLED:-}" ]; then
			[ -f "$INSTALL_ROOT/usr/share/rpcd/ucode/sms-feishu-forwarder.uc" ] || exit 8
			[ -f "$INSTALL_ROOT/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json" ] || exit 9
		fi
		if [ "$name" = "rpcd" ] && [ "${INSTALL_FAIL_RPCD_RESTART:-0}" = "1" ]; then
			exit 1
		fi
		printf '1\n' > "$state_dir/$name.running"
		;;
	*)
		exit 1
		;;
esac
EOS
	chmod +x "$path"
}

setup_case()
{
	local name="$1"
	CASE_DIR="$TMP_ROOT/$name"
	MOCK_BIN="$CASE_DIR/bin"
	mkdir -p "$CASE_DIR"
	: > "$CASE_DIR/bodies"
	: > "$CASE_DIR/marks"
	make_mocks "$MOCK_BIN"
	make_mt5700m_mock "$MOCK_BIN"
	export PATH="$MOCK_BIN:$ORIG_PATH"
	export SMSFF_TESTING=1
	export SMSFF_TEST_MT5700M_AT="$MOCK_BIN/mt5700m-at"
	export SMSFF_TEST_MT5700M_READ="$MOCK_BIN/mt5700m-read"
	export SMSFF_TEST_MT5700M_MANAGER="$MOCK_BIN/mt5700m-manager"
	export SMSFF_TEST_QUOTA_HELPER="$ROOT/files/usr/lib/sms-feishu-forwarder/quota.sh"
	export SMSFF_STATE_PATH="$CASE_DIR/seen.keys"
	export SMSFF_FORWARD_STATUS_PATH="$CASE_DIR/latest.result"
	export SMSFF_MODEM_STATUS_PATH="$CASE_DIR/modem-status.json"
	export SMSFF_LOCK_DIR="$CASE_DIR/lock"
	export SMSFF_BOOT_SEED_PATH="$CASE_DIR/boot-seeded"
	export SMSFF_SEND_ATTEMPTS=1
	export SMSFF_BACKOFF_BASE=0
	export SMSFF_SETTLE_DELAY=0
	export TEST_BODIES="$CASE_DIR/bodies"
	export TEST_MARKS="$CASE_DIR/marks"
	export TEST_SMS_TOOL_LOG="$CASE_DIR/sms-tool.log"
	export TEST_LOGGER="$CASE_DIR/logger.log"
	export TEST_UBUS_LOG="$CASE_DIR/ubus.log"
	export TEST_UBUS_TIMEOUT_LOG="$CASE_DIR/ubus-timeout.log"
	export TEST_AT_DAEMON_LOG="$CASE_DIR/at-daemon.log"
	export TEST_MT5700M_LOG="$CASE_DIR/mt5700m.log"
	export TEST_CURL_RESPONSE="$CASE_DIR/curl-response"
	: > "$TEST_SMS_TOOL_LOG"
	: > "$TEST_LOGGER"
	: > "$TEST_UBUS_LOG"
	: > "$TEST_UBUS_TIMEOUT_LOG"
	: > "$TEST_AT_DAEMON_LOG"
	: > "$TEST_MT5700M_LOG"
	unset CURL_BODY CURL_HTTP_CODE || true
	unset SMSFF_ATTACH_STATUS SMSFF_UBUS_TIMEOUT SMSFF_BACKEND SMSFF_MT5700M_AT SMSFF_MT5700M_USB_HELPER SMSFF_MODEMWEBUI_INIT TEST_CONNECT_STATUS TEST_BASE_INFO TEST_CELL_INFO TEST_NETWORK_DUMP || true
	unset TEST_UCI_SHOW TEST_UCI_GETS TEST_UCI_BATCH_LOG TEST_UCI_FAIL_BATCH_CONTAINS SMSFF_SMS_PORT SMSFF_SCHEDULE_STATE_DIR SMSFF_NOW_SLOT SMSFF_NOW_WEEKDAY TEST_SMS_TOOL_FAIL TEST_SMS_TOOL_RESPONSE TEST_SMS_TOOL_ASSERT_RUNNING_SECTION TEST_SMS_TOOL_SLEEP TEST_AT_DAEMON_RESPONSE TEST_AT_DAEMON_LOCK_STATE_DIR SMSFF_SCHED_LOCK_DIR TEST_SLEEP_LOG TEST_SLEEP_HOLD_FILE TEST_SLEEP_STARTED || true
	unset TEST_MT5700M_FIXTURE TEST_MT5700M_START_FAIL TEST_MT5700M_JOB_STATE TEST_MT5700M_JOB_CODE SMSFF_NOW_EPOCH SMSFF_NOW_MESSAGE_TS SMSFF_NOW_MONTH SMSFF_QUOTA_CALIBRATION SMSFF_QUOTA_STATE_PATH SMSFF_QUOTA_STATUS_PATH SMSFF_TRAFFIC_HISTORY_PATH SMSFF_PACKAGE_ROOT SMSFF_PACKAGE_INIT_CMD SMSFF_PACKAGE_RPCD_INIT_CMD || true
	unset TEST_SLEEP_FAST || true
	export SMSFF_QUOTA_STATE_PATH="$CASE_DIR/quota-state.json"
	export SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/quota-status.json"
	export SMSFF_SCHED_LOCK_DIR="$CASE_DIR/scheduler-lock"
}

setup_install_case()
{
	local name="$1"
	setup_case "$name"
	INSTALL_ROOT="$CASE_DIR/root"
	SERVICE_LOG="$CASE_DIR/service.log"
	SERVICE_STATE_DIR="$CASE_DIR/service-state"
	mkdir -p "$INSTALL_ROOT/usr/bin" "$INSTALL_ROOT/etc/init.d" "$INSTALL_ROOT/etc/config" "$INSTALL_ROOT/var/lib"
	: > "$SERVICE_LOG"
	export INSTALL_ROOT SERVICE_LOG SERVICE_STATE_DIR
	unset INSTALL_FAIL_SEED INSTALL_FAIL_ONCE INSTALL_FAIL_RESTART INSTALL_FAIL_TASKPLAN_RESTART INSTALL_FAIL_TASKPLAN_RESTART_AFTER_CUTOVER INSTALL_FAIL_SCHED_CHECK INSTALL_FAIL_RPCD_RESTART TEST_INIT_RUN_CUTOVER || true
cat > "$MOCK_BIN/install-forwarder" <<'EOS'
#!/bin/sh
printf '%s\n' "$1" >> "$INSTALL_FORWARDER_LOG"
if [ -n "${TEST_INSTALL_ASSERT_CUSTOM_STOPPED:-}" ]; then
	[ "$(cat "$SERVICE_STATE_DIR/sms-feishu-forwarder.running" 2>/dev/null)" = "0" ] || exit 9
fi
case "$1" in
	--seed)
		[ "${INSTALL_FAIL_SEED:-0}" = "1" ] && exit 1
		;;
	--once)
		[ "${INSTALL_FAIL_ONCE:-0}" = "1" ] && exit 1
		;;
esac
exit 0
EOS
	chmod +x "$MOCK_BIN/install-forwarder"
cat > "$MOCK_BIN/install-scheduler" <<'EOS'
#!/bin/sh
printf '%s\n' "$1" >> "$INSTALL_SCHEDULER_LOG"
[ "$1" = "--check" ] || exit 1
[ "${INSTALL_FAIL_SCHED_CHECK:-0}" = "1" ] && exit 1
exit 0
EOS
	chmod +x "$MOCK_BIN/install-scheduler"
	export INSTALL_FORWARDER_LOG="$CASE_DIR/install-forwarder.log"
	export INSTALL_SCHEDULER_LOG="$CASE_DIR/install-scheduler.log"
	: > "$INSTALL_FORWARDER_LOG"
	: > "$INSTALL_SCHEDULER_LOG"
	INSTALL_INIT_ROOT="$CASE_DIR/new-init"
	write_init_mock "$INSTALL_INIT_ROOT" sms-feishu-forwarder 0 0
	export INSTALL_INIT_CMD="$INSTALL_INIT_ROOT/etc/init.d/sms-feishu-forwarder"
	export SMSFF_INSTALL_SCHEDULER_CMD="$MOCK_BIN/install-scheduler"
	write_init_mock "$INSTALL_ROOT" smsforward 1 1
	write_init_mock "$INSTALL_ROOT" sms_forwarder 1 1
}

run_forwarder()
{
	if [ "${TEST_TRACE:-0}" = "1" ]; then
		busybox ash -x "$DAEMON" "$@"
		return
	fi
	busybox ash "$DAEMON" "$@"
}

run_scheduler()
{
	if [ "${TEST_TRACE:-0}" = "1" ]; then
		busybox ash -x "$SCHEDULER" "$@"
		return
	fi
	busybox ash "$SCHEDULER" "$@"
}

body_contents()
{
	jq -r '.card.elements[]? | select(.text?.content != null) | .text.content' "$TEST_BODIES" | grep -v '^短信内容$'
}

body_contents_json()
{
	jq -s -c '[.[].card.elements[]? | select(.text?.content != null) | .text.content | select(. != "短信内容")]' "$TEST_BODIES"
}

test_chronological_order()
{
	setup_case chronological
	export TEST_FIXTURE="$ROOT/tests/fixtures/unsorted.json"
	run_forwarder --once
	assert_eq "unsorted API input sends chronological order" "$(body_contents | paste -sd ',' -)" "first,second,third"
}

test_incomplete_blocks_later()
{
	setup_case incomplete
	export TEST_FIXTURE="$ROOT/tests/fixtures/incomplete_oldest.json"
	if run_forwarder --once; then
		fail "incomplete oldest returns failure"
	else
		pass "incomplete oldest returns failure"
	fi
	assert_body_count "incomplete oldest blocks later sends" 0
}

test_failed_oldest_blocks_later()
{
	setup_case failed_oldest
	export TEST_FIXTURE="$ROOT/tests/fixtures/unsorted.json"
	export CURL_BODY='{"code":9499,"msg":"application error"}'
	if run_forwarder --once; then
		fail "Feishu application-error response fails"
	else
		pass "Feishu application-error response fails"
	fi
	assert_body_count "failed oldest blocks later" 1
	assert_file_lines "failed oldest is not marked seen" "$SMSFF_STATE_PATH" 0
}

test_seed_prevents_replay()
{
	setup_case seed
	export TEST_FIXTURE="$ROOT/tests/fixtures/seed.json"
	run_forwarder --seed
	run_forwarder --once
	assert_body_count "seeded historical messages are not sent" 0
	assert_file_lines "seed writes seen keys" "$SMSFF_STATE_PATH" 2
}

test_seed_without_external_base64()
{
	setup_case seed_no_base64
	export TEST_FIXTURE="$ROOT/tests/fixtures/seed.json"
	printf '#!/bin/sh\nexit 127\n' > "$MOCK_BIN/base64"
	chmod +x "$MOCK_BIN/base64"
	run_forwarder --seed
	assert_file_lines "seed works without external base64 applet" "$SMSFF_STATE_PATH" 2
}

test_boot_seeds_backlog_once_then_forwards_new_sms_after_service_restart()
{
	setup_case boot_seed_once
	export TEST_FIXTURE="$ROOT/tests/fixtures/seed.json"
	export SMSFF_POLL_INTERVAL=30

	busybox ash "$DAEMON" > "$CASE_DIR/first.log" 2>&1 &
	local first_pid=$!
	local i=0
	while [ "$i" -lt 100 ] && [ ! -e "$SMSFF_BOOT_SEED_PATH" ]; do
		/bin/sleep 0.02
		i=$((i + 1))
	done
	kill -TERM "$first_pid" 2>/dev/null || true
	wait "$first_pid" 2>/dev/null || true
	[ -e "$SMSFF_BOOT_SEED_PATH" ] && pass "first daemon start records boot seed marker" || fail "first daemon start records boot seed marker"
	assert_body_count "first daemon start does not forward modem backlog" 0
	assert_file_lines "first daemon start records backlog as seen" "$SMSFF_STATE_PATH" 2

	jq '.conversations[0].messages += [{"id":"102","timestamp":1002,"type":"received","sender":"+155****0102","content":"new after boot","total":1,"multipart":false,"part_ids":[]}]' \
		"$ROOT/tests/fixtures/seed.json" > "$CASE_DIR/after-boot.json"
	export TEST_FIXTURE="$CASE_DIR/after-boot.json"
	: > "$TEST_BODIES"
	rm -rf "$SMSFF_LOCK_DIR"

	busybox ash "$DAEMON" > "$CASE_DIR/restart.log" 2>&1 &
	local restart_pid=$!
	i=0
	while [ "$i" -lt 100 ] && [ "$(wc -l < "$TEST_BODIES")" -lt 1 ]; do
		/bin/sleep 0.02
		i=$((i + 1))
	done
	kill -TERM "$restart_pid" 2>/dev/null || true
	wait "$restart_pid" 2>/dev/null || true
	assert_body_count "service restart in same boot forwards only newly arrived sms" 1
	assert_eq "service restart forwarded content" "$(body_contents)" "new after boot"
}

test_multipart_complete()
{
	setup_case multipart
	export TEST_FIXTURE="$ROOT/tests/fixtures/multipart_complete.json"
	run_forwarder --once
	assert_eq "multipart completeness" "$(body_contents_json)" '["part one\npart two","after multipart"]'
	assert_file_lines "multipart and later marked seen" "$SMSFF_STATE_PATH" 2
	assert_eq "mark_forwarded uses qmodem ids array" "$(jq -sc 'map(.ids) | .[0]' "$TEST_MARKS")" '["p1","p2"]'
}

test_dedupe_restart()
{
	setup_case dedupe
	export TEST_FIXTURE="$ROOT/tests/fixtures/unsorted.json"
	run_forwarder --once
	: > "$TEST_BODIES"
	rm -rf "$SMSFF_LOCK_DIR"
	run_forwarder --once
	assert_body_count "dedupe across restart" 0
}

test_json_content_survives()
{
	setup_case json_content
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	run_forwarder --once
	assert_eq "JSON newlines and quotes survive" "$(body_contents_json)" '["line 1\nquoted \"value\" and slash \\"]'
	assert_eq "qmodem timestamp avoids double timezone offset" "$(jq -r '.card.elements[0].fields[0].text.content' "$TEST_BODIES")" "**接收时间**
1970-01-01 00:01:40"
}

test_mt5700m_auto_backend_parses_gsm7_without_qmodem()
{
	setup_case mt5700m_gsm7
	make_mt5700m_mock "$MOCK_BIN"
	export SMSFF_BACKEND=auto
	export SMSFF_MT5700M_AT="$MOCK_BIN/mt5700m-at"
	export SMSFF_MT5700M_DECODER="$ROOT/files/usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk"
	export TEST_MT5700M_FIXTURE="$ROOT/tests/fixtures/mt5700m_gsm7.txt"
	export TEST_FIXTURE="$TEST_MT5700M_FIXTURE"
	if run_forwarder --once; then
		pass "MT5700M GSM7 poll succeeds"
	else
		fail "MT5700M GSM7 poll succeeds"
	fi
	assert_eq "MT5700M card title identifies backend" "$(jq -r '.card.header.title.content' "$TEST_BODIES")" "MT5700M 短信"
	assert_eq "MT5700M GSM7 content is decoded" "$(body_contents)" "MT5700M GSM7"
	assert_eq "MT5700M card keeps modem wall-clock time" "$(jq -r '.card.elements[0].fields[0].text.content' "$TEST_BODIES")" "**接收时间**
2026-01-02 03:04:05"
	assert_file_lines "MT5700M message is marked seen locally" "$SMSFF_STATE_PATH" 1
	if grep -Eq 'qmodem|qmodem_sms' "$TEST_UBUS_LOG"; then
		fail "MT5700M backend does not call qmodem"
	else
		pass "MT5700M backend does not call qmodem"
	fi
}

test_mt5700m_ucs2_multipart_merges_across_segment_timestamps()
{
	setup_case mt5700m_ucs2_multipart
	make_mt5700m_mock "$MOCK_BIN"
	export SMSFF_BACKEND=mt5700m
	export SMSFF_MT5700M_AT="$MOCK_BIN/mt5700m-at"
	export SMSFF_MT5700M_DECODER="$ROOT/files/usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk"
	export TEST_MT5700M_FIXTURE="$ROOT/tests/fixtures/mt5700m_ucs2_multipart.txt"
	export TEST_FIXTURE="$TEST_MT5700M_FIXTURE"
	if run_forwarder --once; then
		pass "MT5700M UCS2 multipart poll succeeds"
	else
		fail "MT5700M UCS2 multipart poll succeeds"
	fi
	assert_body_count "MT5700M multipart sends one merged card" 1
	assert_eq "MT5700M UCS2 multipart content is merged" "$(body_contents)" "你好"
	assert_file_lines "MT5700M multipart message has one seen key" "$SMSFF_STATE_PATH" 1
}

test_mt5700m_status_uses_safe_hcsq_and_temperature_sources()
{
	setup_case mt5700m_safe_status
	make_mt5700m_mock "$MOCK_BIN"
	export SMSFF_BACKEND=mt5700m
	export SMSFF_MT5700M_AT="$MOCK_BIN/mt5700m-at"
	export TEST_MT5700M_HCSQ='^HCSQ: "NR",54,191,30'
	export TEST_MT5700M_MONSC='^MONSC: NR,460,00,504990,30,123456789,204,1001,-87,-5,18'
	export TEST_MT5700M_TEMPERATURE='temp_modem1=41.0
temperature=43.0
temperature_sensor=sub6g_pa'
	export TEST_NETWORK_DUMP='{"interface":[{"interface":"MT5700M","up":true,"l3_device":"eth2","ipv4-address":[{"address":"198.51.100.23","mask":24}],"route":[{"target":"0.0.0.0","mask":0}]}]}'
	cat > "$MOCK_BIN/mt5700m-manager" <<'EOS'
#!/bin/sh
[ "$1" = status-json ] || exit 1
printf '%s\n' '{"connected":true,"mode":"NCM / ECM","interface":"MT5700M","network":"eth2","imei":"867530900000000"}'
EOS
	chmod +x "$MOCK_BIN/mt5700m-manager"
	export SMSFF_MT5700M_MANAGER="$MOCK_BIN/mt5700m-manager"
	status="$(run_forwarder --status-json)"
	assert_eq "MT5700M status reports HCSQ radio mode, not eth interface" "$(printf '%s' "$status" | jq -r .network_mode)" "NR"
	assert_eq "MT5700M status converts HCSQ RSRP" "$(printf '%s' "$status" | jq -r .rsrp)" "-87 dBm"
	assert_eq "MT5700M status converts HCSQ RSRQ" "$(printf '%s' "$status" | jq -r .rsrq)" "-5.0 dB"
	assert_eq "MT5700M status converts HCSQ SINR" "$(printf '%s' "$status" | jq -r .sinr)" "18.0 dB"
	assert_eq "MT5700M status uses safe temperature projection" "$(printf '%s' "$status" | jq -r .temperature)" "43.0°C"
	assert_eq "MT5700M status parses serving PCI without identity fields" "$(printf '%s' "$status" | jq -r .pci)" "204"
	assert_eq "MT5700M status parses serving ARFCN without identity fields" "$(printf '%s' "$status" | jq -r .arfcn)" "504990"
	assert_eq "MT5700M status reads WAN IPv4 from the active MT5700M interface" "$(printf '%s' "$status" | jq -r .wan)" "198.51.100.23"
	if printf '%s' "$status" | grep -Eq 'eth2|867530900000000'; then
		fail "MT5700M status excludes interface names and identity"
	else
		pass "MT5700M status excludes interface names and identity"
	fi
}

test_poll_queries_live_status_only_when_forwarding_and_adds_quota_remaining()
{
	setup_case status_only_on_forward
	make_mt5700m_mock "$MOCK_BIN"
	export SMSFF_BACKEND=mt5700m
	export SMSFF_MT5700M_DECODER="$ROOT/files/usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk"
	export SMSFF_ATTACH_STATUS=1
	export TEST_FIXTURE="$ROOT/tests/fixtures/mt5700m_gsm7.txt"
	export TEST_MT5700M_FIXTURE="$TEST_FIXTURE"
	export TEST_MT5700M_HCSQ='^HCSQ: "NR",54,191,30'
	export TEST_MT5700M_MONSC='^MONSC: NR,460,00,504990,30,123456789,204,1001,-87,-5,18'
	export TEST_MT5700M_TEMPERATURE='temperature=43.0'
	export TEST_NETWORK_DUMP='{"interface":[{"interface":"eth2","up":true,"l3_device":"eth2","ipv4-address":[{"address":"198.51.100.23","mask":24}],"route":[{"target":"0.0.0.0","mask":0}]}]}'
	export SMSFF_QUOTA_CALIBRATION=7
	export SMSFF_QUOTA_STATE_PATH="$CASE_DIR/quota-state.json"
	export SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/quota-status.json"
	export SMSFF_TRAFFIC_HISTORY_PATH="$CASE_DIR/traffic-history"
	export SMSFF_NOW_MONTH=2026-09
	printf '%s\n' '{"interval":"7","result":"ok","carrier_total_centi":10000,"carrier_centi":1234,"last_calibration_stamp":"20260924100000","month":"2026-09","base_rx":"3000000000","base_tx":"4000000000","next_due_epoch":1780826400}' > "$SMSFF_QUOTA_STATE_PATH"
	printf '%s\n' 'month eth2 2026-09 4000000000 5000000000' > "$SMSFF_TRAFFIC_HISTORY_PATH"
	run_forwarder --seed
	: > "$TEST_MT5700M_LOG"
	run_forwarder --once
	assert_eq "poll without unseen SMS does not issue status AT commands" "$(grep -Ec 'AT\^HCSQ|AT\^MONSC|^temperature$' "$TEST_MT5700M_LOG" || true)" "0"
	: > "$SMSFF_STATE_PATH"
	: > "$TEST_MT5700M_LOG"
	: > "$TEST_BODIES"
	run_forwarder --once
	assert_eq "one forwarding batch queries HCSQ once" "$(grep -c 'command AT\^HCSQ?' "$TEST_MT5700M_LOG" || true)" "1"
	assert_eq "one forwarding batch queries MONSC once" "$(grep -c 'command AT\^MONSC' "$TEST_MT5700M_LOG" || true)" "1"
	assert_eq "one forwarding batch queries temperature once" "$(grep -c '^temperature$' "$TEST_MT5700M_LOG" || true)" "1"
	assert_eq "forwarded card labels estimated remaining traffic" "$(jq -r '.. | strings' "$TEST_BODIES" | grep -c '剩余流量（估算）' || true)" "1"
	assert_eq "forwarded card includes current estimated remaining traffic" "$(jq -r '.. | strings' "$TEST_BODIES" | grep -c '10.34GB' || true)" "1"
}

test_status_enriched_card()
{
	setup_case status_card
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	export SMSFF_ATTACH_STATUS=1
	export SMSFF_UPTIME_PATH="$CASE_DIR/uptime"
	export SMSFF_DHCP_LEASES_PATH="$CASE_DIR/dhcp.leases"
	printf '%s\n' '90061.25 0.00' > "$SMSFF_UPTIME_PATH"
	printf '%s\n' \
		'4102444800 02:00:00:00:00:01 192.0.2.10 phone *' \
		'4102444800 02:00:00:00:00:02 192.0.2.11 laptop *' \
		'1 02:00:00:00:00:03 192.0.2.12 expired *' > "$SMSFF_DHCP_LEASES_PATH"
	export TEST_NETWORK_DUMP='{"interface":[{"interface":"wan","route":[{"target":"0.0.0.0","source":"10.23.45.67/32"}]}]}'
	run_forwarder --once
	assert_eq "status card has divider" "$(jq -r '[.card.elements[]?.tag] | index("hr") != null' "$TEST_BODIES")" "true"
	assert_eq "status card omits redundant CPE online field" "$(jq -r '.. | strings' "$TEST_BODIES" | grep -c 'CPE 状态' || true)" "0"
	assert_eq "status card includes online DHCP device count" "$(jq -r '.. | strings' "$TEST_BODIES" | grep -c '2台' || true)" "1"
	assert_eq "status card includes remaining modem fields" "$(jq -r '.card.elements[]? | select(.fields) | .fields[].text.content' "$TEST_BODIES" | grep -E '在线设备|网络模式|RSRP|RSRQ / SINR|模组温度|PCI / ARFCN|WAN 地址|运行时间' | wc -l)" "8"
	assert_eq "status card uptime includes minutes" "$(jq -r '.. | strings' "$TEST_BODIES" | grep -c '1天1小时1分钟' || true)" "1"
	assert_eq "status card strips WAN CIDR" "$(jq -r '.card.elements[]? | select(.fields) | .fields[].text.content' "$TEST_BODIES" | grep '10.23.45.67' | wc -l)" "1"
	if jq -r '.. | strings' "$TEST_BODIES" | grep -E 'IMEI|IMSI|ICCID|open-apis/bot|00000000-0000'; then
		fail "status card redacts identity and webhook"
	else
		pass "status card redacts identity and webhook"
	fi
}

test_forwarder_parses_real_qmodem_modem_info()
{
	setup_case real_modem_info
	install_jq_no_regex_wrapper "$(PATH="$ORIG_PATH" command -v jq)"
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	export SMSFF_ATTACH_STATUS=1
	export TEST_CONNECT_STATUS='{"connection_status":"Yes"}'
	export TEST_BASE_INFO='{"modem_info":[{"key":"temperature","value":"42","unit":"C"},{"key":"IMEI","value":"867530900000000"},{"key":"ICCID","value":"89860000000000000000"}]}'
	export TEST_CELL_INFO='{"modem_info":[{"key":"network_mode","value":"NR5G-SA Mode"},{"key":"RSRP","value":"-76","unit":"dBm"},{"key":"RSRQ","value":"-9","unit":"dB"},{"key":"SINR","value":"21","unit":"dB"},{"key":"Physical Cell ID","value":"321"},{"key":"ARFCN","value":"633984"},{"key":"IMSI","value":"460001234567890"}]}'
	run_forwarder --once
	assert_eq "real modem_info connection_status Yes is parsed without jq regex" "$("$TEST_REAL_JQ" -r '.online' "$SMSFF_MODEM_STATUS_PATH")" "在线"
	assert_eq "SMS card omits parsed online status" "$("$TEST_REAL_JQ" -r '.. | strings' "$TEST_BODIES" | grep -c '^在线$' || true)" "0"
	assert_eq "real modem_info network_mode is extracted" "$("$TEST_REAL_JQ" -r '.. | strings' "$TEST_BODIES" | grep -c 'NR5G-SA Mode')" "1"
	assert_eq "real modem_info radio values include units" "$("$TEST_REAL_JQ" -r '.. | strings' "$TEST_BODIES" | grep -Ec -- '-76 dBm|-9 dB / 21 dB')" "2"
	assert_eq "real modem_info temperature is extracted" "$("$TEST_REAL_JQ" -r '.. | strings' "$TEST_BODIES" | grep -c '42 C')" "1"
	if "$TEST_REAL_JQ" -r '.. | strings' "$TEST_BODIES" | grep -E '867530900000000|89860000000000000000|460001234567890'; then
		fail "real modem_info identity fields are not exposed"
	else
		pass "real modem_info identity fields are not exposed"
	fi
}

test_status_normalizers_are_busybox_tr_safe()
{
	if grep -R '\[:upper:\]' "$ROOT/files" >/dev/null || grep -R '\[:lower:\]' "$ROOT/files" >/dev/null; then
		fail "production status normalizers avoid tr character classes"
	else
		pass "production status normalizers avoid tr character classes"
	fi
}

test_forwarder_records_latest_result()
{
	setup_case forward_status
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	run_forwarder --once
	assert_file_content "forwarder records latest success" "$SMSFF_FORWARD_STATUS_PATH" "ok"
}

test_modem_status_cache_created_without_unseen_sms_and_bounded_status_ubus()
{
	setup_case modem_cache_no_unseen
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	export SMSFF_ATTACH_STATUS=1
	export SMSFF_UBUS_TIMEOUT=7
	run_forwarder --seed
	: > "$TEST_UBUS_LOG"
	: > "$TEST_UBUS_TIMEOUT_LOG"
	run_forwarder --once
	jq -e . "$SMSFF_MODEM_STATUS_PATH" >/dev/null && pass "modem status cache is valid JSON after no-unseen poll" || fail "modem status cache is valid JSON after no-unseen poll"
	assert_eq "modem status cache mode is 0600" "$(stat -c '%a' "$SMSFF_MODEM_STATUS_PATH" 2>/dev/null || stat -f '%Lp' "$SMSFF_MODEM_STATUS_PATH")" "600"
	assert_eq "status-only ubus calls use configured timeout" "$(cat "$TEST_UBUS_TIMEOUT_LOG" | paste -sd ',' -)" "7,7,7,7"
	assert_eq "list_sms remains unbounded" "$(grep -c '^call qmodem_sms list_sms' "$TEST_UBUS_LOG")" "1"
}

test_live_sms_card_refreshes_modem_status_cache_and_excludes_identity()
{
	setup_case modem_cache_live_sms
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	export SMSFF_ATTACH_STATUS=1
	export TEST_BASE_INFO='{"temperature":"45","IMEI":"867530900000000","ICCID":"89860000000000000000"}'
	export TEST_CELL_INFO='{"network_mode":"NR5G","RSRP":"-88","RSRQ":"-11","SINR":"19","Physical Cell ID":"321","ARFCN":"633984","IMSI":"460001234567890"}'
	run_forwarder --once
	assert_body_count "live SMS sends one card" 1
	jq -e . "$SMSFF_MODEM_STATUS_PATH" >/dev/null && pass "live SMS writes modem status cache" || fail "live SMS writes modem status cache"
	assert_eq "modem cache only keeps safe allowlisted keys" "$(jq -r 'keys | sort | join(",")' "$SMSFF_MODEM_STATUS_PATH")" "arfcn,network_mode,online,online_devices,pci,rsrp,rsrq,sinr,temperature,uptime,wan"
	if jq -r '.. | strings' "$SMSFF_MODEM_STATUS_PATH" | grep -E '867530900000000|89860000000000000000|460001234567890|open-apis/bot'; then
		fail "modem cache excludes identity and webhook"
	else
		pass "modem cache excludes identity and webhook"
	fi
}

test_test_mode_uses_cached_modem_status_only()
{
	setup_case test_mode_cached_status
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	export SMSFF_ATTACH_STATUS=1
	mkdir -p "${SMSFF_MODEM_STATUS_PATH%/*}"
	printf '%s\n' '{"online":"缓存在线","online_devices":"3台","network_mode":"缓存NR","rsrp":"-70 dBm","rsrq":"-8 dB","sinr":"20 dB","temperature":"40 C","pci":"123","arfcn":"456","wan":"10.0.0.9","uptime":"9分钟"}' > "$SMSFF_MODEM_STATUS_PATH"
	: > "$TEST_UBUS_LOG"
	run_forwarder --test
	assert_eq "test card uses cached modem status" "$(jq -r '.. | strings' "$TEST_BODIES" | grep -c '缓存NR')" "1"
	assert_eq "test card uses cached online device count" "$(jq -r '.. | strings' "$TEST_BODIES" | grep -c '3台')" "1"
	assert_eq "test card omits cached online status" "$(jq -r '.. | strings' "$TEST_BODIES" | grep -c '缓存在线' || true)" "0"
	if grep -Eq 'qmodem|get_connect_status|base_info|cell_info|network.interface' "$TEST_UBUS_LOG"; then
		fail "test mode does not call qmodem status methods"
	else
		pass "test mode does not call qmodem status methods"
	fi
}

test_test_mode_unknown_status_when_cache_absent()
{
	setup_case test_mode_no_cache
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	export SMSFF_ATTACH_STATUS=1
	rm -f "$SMSFF_MODEM_STATUS_PATH"
	: > "$TEST_UBUS_LOG"
	run_forwarder --test
	assert_eq "test card reports unknown when caches are absent" "$(jq -r '.. | strings' "$TEST_BODIES" | grep -o '未知' | wc -l)" "11"
	if grep -Eq 'qmodem|get_connect_status|base_info|cell_info|network.interface' "$TEST_UBUS_LOG"; then
		fail "test mode with absent cache avoids live modem calls"
	else
		pass "test mode with absent cache avoids live modem calls"
	fi
}

test_forwarder_live_lock_contention_fails_but_test_uses_test_lock()
{
	setup_case forwarder_lock_contention
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	mkdir "$SMSFF_LOCK_DIR"
	printf '%s\n' "$$" > "$SMSFF_LOCK_DIR/pid"
	if run_forwarder --once; then
		fail "live forwarder lock contention returns failure"
	else
		pass "live forwarder lock contention returns failure"
	fi
	assert_body_count "busy forwarder lock does not false-success send" 0
	run_forwarder --test
	assert_body_count "test mode sends while daemon lock is live" 1
	assert_file_absent "test mode does not create seen state" "$SMSFF_STATE_PATH"
}

test_forwarder_test_mode_reports_send_failure_with_live_daemon_lock()
{
	setup_case forwarder_test_failure_lock
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	mkdir "$SMSFF_LOCK_DIR"
	printf '%s\n' "$$" > "$SMSFF_LOCK_DIR/pid"
	export CURL_HTTP_CODE=500
	if run_forwarder --test; then
		fail "test mode send failure returns failure despite live daemon lock"
	else
		pass "test mode send failure returns failure despite live daemon lock"
	fi
	assert_body_count "test mode attempted curl despite live daemon lock" 1
	assert_file_absent "failed test mode does not create seen state" "$SMSFF_STATE_PATH"
}

test_scheduler_due_slot_sends_once()
{
	setup_case scheduler_once
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.traffic_hourly=schedule
sms-feishu-forwarder.traffic_hourly.enabled='1'
sms-feishu-forwarder.traffic_hourly.name='traffic_hourly'
sms-feishu-forwarder.traffic_hourly.recipient='10086'
sms-feishu-forwarder.traffic_hourly.content='CXLL'
sms-feishu-forwarder.traffic_hourly.hour='9'
sms-feishu-forwarder.traffic_hourly.minute='5'
sms-feishu-forwarder.traffic_hourly.weekdays='*'"
	run_scheduler --once
	run_scheduler --once
	assert_file_lines "scheduler sends due slot once" "$TEST_SMS_TOOL_LOG" 1
	assert_eq "scheduler uses sms side port" "$(cat "$TEST_SMS_TOOL_LOG")" "-d /dev/ttyUSB2 send 10086 CXLL"
	assert_file_content "scheduler records last successful slot" "$SMSFF_SCHEDULE_STATE_DIR/traffic_hourly.last_slot" "2026-07-30-09-05"
	assert_file_content "scheduler records success result" "$SMSFF_SCHEDULE_STATE_DIR/traffic_hourly.result" "ok"
}

test_scheduler_rejects_exit_zero_without_cmgs()
{
	setup_case scheduler_exit_zero_without_cmgs
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='10086'
sms-feishu-forwarder.balance_daily.content='CXYE'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	cat > "$MOCK_BIN/sms_tool_q" <<'EOS'
#!/bin/sh
printf '%s\n' 'OK'
exit 0
EOS
	chmod +x "$MOCK_BIN/sms_tool_q"
	if run_scheduler --once; then
		fail "scheduler rejects exit zero without +CMGS"
	else
		pass "scheduler rejects exit zero without +CMGS"
	fi
	assert_file_content "exit zero without +CMGS records failure" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.result" "failed"
}

test_scheduler_requires_terminal_ok_after_cmgs()
{
	setup_case scheduler_nonterminal_cmgs
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export TEST_SMS_TOOL_RESPONSE=ok_before_cmgs
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='10086'
sms-feishu-forwarder.balance_daily.content='CXYE'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	run_scheduler --once || true
	assert_file_content "nonterminal +CMGS records failure" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.result" "failed"
}

test_scheduler_mt5700m_auto_detects_pcui_port()
{
	setup_case scheduler_mt5700m_pcui_port
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_BACKEND=mt5700m
	export SMSFF_SMS_PORT=auto
	export SMSFF_MT5700M_USB_HELPER="$CASE_DIR/mt5700m-usb.sh"
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='10086'
sms-feishu-forwarder.balance_daily.content='CXYE'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	cat > "$SMSFF_MT5700M_USB_HELPER" <<'EOS'
#!/bin/sh
mt5700m_pcui_port()
{
	printf '%s\n' '/dev/ttyUSB1'
}
EOS
	chmod +x "$SMSFF_MT5700M_USB_HELPER"
	cat > "$MOCK_BIN/od" <<'EOS'
#!/bin/sh
printf '%s\n' 'od is unavailable on target' >&2
exit 97
EOS
	chmod +x "$MOCK_BIN/od"
	export SMSFF_MODEMWEBUI_INIT="$CASE_DIR/modemwebui-init"
	export TEST_MODEMWEBUI_LOG="$CASE_DIR/modemwebui.log"
	cat > "$SMSFF_MODEMWEBUI_INIT" <<'EOS'
#!/bin/sh
printf '%s\n' "$1" >> "$TEST_MODEMWEBUI_LOG"
case "$1" in status|stop|start) exit 0 ;; esac
exit 1
EOS
	chmod +x "$SMSFF_MODEMWEBUI_INIT"
	run_scheduler --once
	assert_file_lines "MT5700M send does not call sms_tool_q" "$TEST_SMS_TOOL_LOG" 0
	assert_file_lines "MT5700M send uses one atomic at-daemon call" "$TEST_AT_DAEMON_LOG" 1
	assert_eq "MT5700M uses prompt-aware sendsms method" "$(sed -n '1s/ .*//p' "$TEST_AT_DAEMON_LOG")" "sendsms"
	assert_eq "MT5700M submits exact UCS2 PDU" "$(sed -n '1s/^[^ ]* //p' "$TEST_AT_DAEMON_LOG" | jq -r '.pdu')" "00110005810180F60008B0080043005800590045"
	assert_eq "MT5700M submits exact TPDU length" "$(sed -n '1s/^[^ ]* //p' "$TEST_AT_DAEMON_LOG" | jq -r '.tpdu_length')" "19"
	assert_eq "MT5700M pauses and restores modem WebUI around submit" "$(tr '\n' ' ' < "$TEST_MODEMWEBUI_LOG")" "status stop start "
	assert_file_content "MT5700M confirmed at-daemon submit records success" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.result" "ok"
}

test_scheduler_mt5700m_rejects_bare_ok_without_cmgs()
{
	setup_case scheduler_mt5700m_bare_ok
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_BACKEND=mt5700m
	export SMSFF_SMS_PORT=auto
	export SMSFF_MT5700M_USB_HELPER="$CASE_DIR/mt5700m-usb.sh"
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_AT_DAEMON_RESPONSE=bare_ok
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='10086'
sms-feishu-forwarder.balance_daily.content='CXYE'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	cat > "$SMSFF_MT5700M_USB_HELPER" <<'EOS'
#!/bin/sh
mt5700m_pcui_port()
{
	printf '%s\n' '/dev/ttyUSB1'
}
EOS
	chmod +x "$SMSFF_MT5700M_USB_HELPER"
	if run_scheduler --once; then
		fail "MT5700M at-daemon rejects bare OK without +CMGS"
	else
		pass "MT5700M at-daemon rejects bare OK without +CMGS"
	fi
	assert_file_content "MT5700M bare OK records failure" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.result" "failed"
}

test_scheduler_mt5700m_reports_failure_when_success_state_cannot_persist()
{
	setup_case scheduler_mt5700m_state_write_failure
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_BACKEND=mt5700m
	export SMSFF_SMS_PORT=auto
	export SMSFF_MT5700M_USB_HELPER="$CASE_DIR/mt5700m-usb.sh"
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_AT_DAEMON_LOCK_STATE_DIR=1
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='10086'
sms-feishu-forwarder.balance_daily.content='CXYE'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	cat > "$SMSFF_MT5700M_USB_HELPER" <<'EOS'
#!/bin/sh
mt5700m_pcui_port()
{
	printf '%s\n' '/dev/ttyUSB1'
}
EOS
	chmod +x "$SMSFF_MT5700M_USB_HELPER"
	if run_scheduler --once 2> "$CASE_DIR/scheduler.stderr"; then
		fail "MT5700M does not report success when success state cannot persist"
	else
		pass "MT5700M does not report success when success state cannot persist"
	fi
	chmod 700 "$SMSFF_SCHEDULE_STATE_DIR"
	assert_file_content "failed success persistence leaves prior running state visible" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.result" "running"
}

test_scheduler_mt5700m_encodes_chinese_as_ucs2()
{
	setup_case scheduler_mt5700m_chinese
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_BACKEND=mt5700m
	export SMSFF_SMS_PORT=auto
	export SMSFF_MT5700M_USB_HELPER="$CASE_DIR/mt5700m-usb.sh"
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='10086'
sms-feishu-forwarder.balance_daily.content='查询'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	cat > "$SMSFF_MT5700M_USB_HELPER" <<'EOS'
#!/bin/sh
mt5700m_pcui_port()
{
	printf '%s\n' '/dev/ttyUSB1'
}
EOS
	chmod +x "$SMSFF_MT5700M_USB_HELPER"
	run_scheduler --once
	assert_eq "MT5700M Chinese content is encoded as UCS2" "$(sed -n '1s/^[^ ]* //p' "$TEST_AT_DAEMON_LOG" | jq -r '.pdu')" "00110005810180F60008B00467E58BE2"
}

test_scheduler_mt5700m_preserves_international_toa_for_short_plus_number()
{
	setup_case scheduler_mt5700m_plus_toa
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_BACKEND=mt5700m
	export SMSFF_SMS_PORT=auto
	export SMSFF_MT5700M_USB_HELPER="$CASE_DIR/mt5700m-usb.sh"
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='+12345'
sms-feishu-forwarder.balance_daily.content='CXYE'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	cat > "$SMSFF_MT5700M_USB_HELPER" <<'EOS'
#!/bin/sh
mt5700m_pcui_port()
{
	printf '%s\n' '/dev/ttyUSB1'
}
EOS
	chmod +x "$SMSFF_MT5700M_USB_HELPER"
	run_scheduler --once
	assert_eq "MT5700M explicit plus number uses international TOA" "$(sed -n '1s/^[^ ]* //p' "$TEST_AT_DAEMON_LOG" | jq -r '.pdu')" "00110005912143F50008B0080043005800590045"
}

test_scheduler_rejects_zero_padded_step_before_arithmetic()
{
	setup_case scheduler_zero_padded_step
	export SMSFF_SMS_PORT="$CASE_DIR/ttyUSB2"
	: > "$SMSFF_SMS_PORT"
	export TEST_UCI_SHOW="sms-feishu-forwarder.bad_step=schedule
sms-feishu-forwarder.bad_step.enabled='1'
sms-feishu-forwarder.bad_step.name='bad_step'
sms-feishu-forwarder.bad_step.recipient='10086'
sms-feishu-forwarder.bad_step.content='CXLL'
sms-feishu-forwarder.bad_step.hour='*/08'
sms-feishu-forwarder.bad_step.minute='5'
sms-feishu-forwarder.bad_step.weekdays='*'"
	if run_scheduler --check; then
		fail "scheduler rejects zero-padded cron step"
	else
		pass "scheduler rejects zero-padded cron step"
	fi
}

test_scheduler_parses_zero_padded_busybox_time()
{
	setup_case scheduler_zero_padded
	export SMSFF_NOW_SLOT="2026-07-30-08-09"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.zero_padded=schedule
sms-feishu-forwarder.zero_padded.enabled='1'
sms-feishu-forwarder.zero_padded.name='zero_padded'
sms-feishu-forwarder.zero_padded.recipient='10086'
sms-feishu-forwarder.zero_padded.content='CXLL'
sms-feishu-forwarder.zero_padded.hour='8'
sms-feishu-forwarder.zero_padded.minute='9'
sms-feishu-forwarder.zero_padded.weekdays='*'"
	run_scheduler --once
	assert_file_lines "scheduler parses 08/09 without 10 arithmetic prefix" "$TEST_SMS_TOOL_LOG" 1
	if grep -q '10#' "$SCHEDULER"; then
		fail "scheduler avoids BusyBox-incompatible 10# arithmetic"
	else
		pass "scheduler avoids BusyBox-incompatible 10# arithmetic"
	fi
}

test_scheduler_failure_and_recipient_validation()
{
	setup_case scheduler_failure
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_SMS_TOOL_FAIL=1
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='10086'
sms-feishu-forwarder.balance_daily.content='CXYE'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	if run_scheduler --once; then
		fail "scheduler send failure returns failure"
	else
		pass "scheduler send failure returns failure"
	fi
	assert_file_content "scheduler records failed result" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.result" "failed"
	if grep -q 'CXYE' "$TEST_LOGGER"; then
		fail "scheduler does not log message content"
	else
		pass "scheduler does not log message content"
	fi

	setup_case scheduler_bad_recipient
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.bad_recipient=schedule
sms-feishu-forwarder.bad_recipient.enabled='1'
sms-feishu-forwarder.bad_recipient.name='bad_recipient'
sms-feishu-forwarder.bad_recipient.recipient='10086;reboot'
sms-feishu-forwarder.bad_recipient.content='CXLL'
sms-feishu-forwarder.bad_recipient.hour='9'
sms-feishu-forwarder.bad_recipient.minute='5'
sms-feishu-forwarder.bad_recipient.weekdays='*'"
	if run_scheduler --once; then
		fail "scheduler invalid recipient returns failure"
	else
		pass "scheduler invalid recipient returns failure"
	fi
	assert_file_lines "scheduler blocks invalid recipient send" "$TEST_SMS_TOOL_LOG" 0
	assert_file_content "scheduler records invalid recipient result" "$SMSFF_SCHEDULE_STATE_DIR/bad_recipient.result" "failed"
}

test_scheduler_persists_running_before_send_and_blocks_same_slot_retry()
{
	setup_case scheduler_running_before_send
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_SMS_TOOL_ASSERT_RUNNING_SECTION=balance_daily
	export TEST_SMS_TOOL_FAIL=1
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='+10086'
sms-feishu-forwarder.balance_daily.content='CXYE'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	if run_scheduler --once; then
		fail "scheduler failure after running slot returns failure"
	else
		pass "scheduler failure after running slot returns failure"
	fi
	unset TEST_SMS_TOOL_FAIL TEST_SMS_TOOL_ASSERT_RUNNING_SECTION
	run_scheduler --once
	assert_file_lines "failed send cannot retry in same persisted slot" "$TEST_SMS_TOOL_LOG" 1
	assert_file_content "scheduler failed slot remains recorded" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.last_slot" "2026-07-30-09-05"
	assert_file_content "scheduler final failed result recorded" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.result" "failed"
}

test_scheduler_strict_content_recipient_lock_and_sleep()
{
	setup_case scheduler_strict_validation
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.empty_content=schedule
sms-feishu-forwarder.empty_content.enabled='1'
sms-feishu-forwarder.empty_content.name='empty_content'
sms-feishu-forwarder.empty_content.recipient='10086'
sms-feishu-forwarder.empty_content.content=''
sms-feishu-forwarder.empty_content.hour='9'
sms-feishu-forwarder.empty_content.minute='5'
sms-feishu-forwarder.empty_content.weekdays='*'
sms-feishu-forwarder.bad_plus=schedule
sms-feishu-forwarder.bad_plus.enabled='1'
sms-feishu-forwarder.bad_plus.name='bad_plus'
sms-feishu-forwarder.bad_plus.recipient='12+34'
sms-feishu-forwarder.bad_plus.content='CXLL'
sms-feishu-forwarder.bad_plus.hour='9'
sms-feishu-forwarder.bad_plus.minute='5'
sms-feishu-forwarder.bad_plus.weekdays='*'
sms-feishu-forwarder.good_plus=schedule
sms-feishu-forwarder.good_plus.enabled='1'
sms-feishu-forwarder.good_plus.name='good_plus'
sms-feishu-forwarder.good_plus.recipient='+10086'
sms-feishu-forwarder.good_plus.content='CXLL'
sms-feishu-forwarder.good_plus.hour='9'
sms-feishu-forwarder.good_plus.minute='5'
sms-feishu-forwarder.good_plus.weekdays='*'"
	if run_scheduler --once; then
		fail "scheduler invalid content or recipient returns failure"
	else
		pass "scheduler invalid content or recipient returns failure"
	fi
	assert_file_lines "scheduler sends only valid optional-plus recipient with content" "$TEST_SMS_TOOL_LOG" 1
	assert_eq "scheduler passes optional leading plus recipient" "$(cat "$TEST_SMS_TOOL_LOG")" "-d /dev/ttyUSB2 send +10086 CXLL"
	grep -q 'acquire_lock' "$SCHEDULER" && grep -q 'kill -0' "$SCHEDULER" && pass "scheduler has stale-safe lock" || fail "scheduler has stale-safe lock"
	grep -q 'interruptible_sleep' "$SCHEDULER" && pass "scheduler loop sleep is interruptible" || fail "scheduler loop sleep is interruptible"
}

test_scheduler_atomic_symlink_lock_and_state_writes()
{
	setup_case scheduler_atomic_lock_state
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='10086'
sms-feishu-forwarder.balance_daily.content='CXYE'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	run_scheduler --once
	assert_file_content "scheduler atomic state writes last_slot" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.last_slot" "2026-07-30-09-05"
	assert_eq "scheduler last_slot mode is 0600" "$(stat -c '%a' "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.last_slot" 2>/dev/null || stat -f '%Lp' "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.last_slot")" "600"
	assert_eq "scheduler result mode is 0600" "$(stat -c '%a' "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.result" 2>/dev/null || stat -f '%Lp' "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.result")" "600"
	assert_eq "scheduler timestamp mode is 0600" "$(stat -c '%a' "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.timestamp" 2>/dev/null || stat -f '%Lp' "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.timestamp")" "600"
	assert_eq "scheduler message mode is 0600" "$(stat -c '%a' "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.message" 2>/dev/null || stat -f '%Lp' "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.message")" "600"
	if grep -q 'ln -s "$$"' "$SCHEDULER" && grep -q 'readlink "$LOCK_DIR"' "$SCHEDULER" && grep -q 'rm -rf "$LOCK_DIR"' "$SCHEDULER"; then
		fail "scheduler lock uses symlink and avoids directory/pid lock removal"
	else
		grep -q 'ln -s "$$"' "$SCHEDULER" && grep -q 'readlink "$LOCK_DIR"' "$SCHEDULER" && pass "scheduler lock uses atomic PID symlink" || fail "scheduler lock uses atomic PID symlink"
	fi
	if grep -Eq '> "\$STATE_DIR/\$section\.(last_slot|result|timestamp|message)"' "$SCHEDULER"; then
		fail "scheduler state files are not written directly"
	else
		pass "scheduler state files are not written directly"
	fi
	grep -q 'mktemp "$dir/.' "$SCHEDULER" && grep -q 'chmod 600 "$tmp"' "$SCHEDULER" && grep -q 'mv -f "$tmp" "$path"' "$SCHEDULER" && pass "scheduler state writes use same-directory temp chmod mv" || fail "scheduler state writes use same-directory temp chmod mv"
}

test_scheduler_manual_send_works_while_loop_sleeps_and_busy_lock_fails()
{
	setup_case scheduler_lock_scope
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_SLEEP_LOG="$CASE_DIR/sleep.log"
	export TEST_SLEEP_HOLD_FILE="$CASE_DIR/sleep.hold"
	export TEST_SLEEP_STARTED="$CASE_DIR/sleep.started"
	touch "$TEST_SLEEP_HOLD_FILE"
	export TEST_UCI_SHOW="sms-feishu-forwarder.traffic_hourly=schedule
sms-feishu-forwarder.traffic_hourly.enabled='0'
sms-feishu-forwarder.traffic_hourly.name='traffic_hourly'
sms-feishu-forwarder.traffic_hourly.recipient='10086'
sms-feishu-forwarder.traffic_hourly.content='CXLL'
sms-feishu-forwarder.traffic_hourly.hour='9'
sms-feishu-forwarder.traffic_hourly.minute='5'
sms-feishu-forwarder.traffic_hourly.weekdays='*'"
	run_scheduler >/dev/null 2>&1 &
	scheduler_pid=$!
	i=0
	while [ ! -e "$TEST_SLEEP_STARTED" ] && [ "$i" -lt 100 ]; do
		/bin/sleep 0.05
		i=$((i + 1))
	done
	if [ -e "$TEST_SLEEP_STARTED" ]; then
		pass "scheduler loop reaches interruptible sleep"
	else
		fail "scheduler loop reaches interruptible sleep"
	fi
	run_scheduler --send traffic_hourly
	assert_file_lines "manual send executes while scheduler loop sleeps" "$TEST_SMS_TOOL_LOG" 1
	rm -f "$TEST_SLEEP_HOLD_FILE"
	kill "$scheduler_pid" 2>/dev/null || true
	wait "$scheduler_pid" 2>/dev/null || true

	export TEST_SMS_TOOL_SLEEP=1
	run_scheduler --send traffic_hourly >/dev/null 2>&1 &
	busy_pid=$!
	i=0
	while [ ! -r "$SMSFF_SCHED_LOCK_DIR/pid" ] && [ "$i" -lt 100 ]; do
		[ -L "$SMSFF_SCHED_LOCK_DIR" ] && break
		/bin/sleep 0.05
		i=$((i + 1))
	done
	if run_scheduler --send traffic_hourly; then
		fail "busy scheduler lock contention returns failure"
	else
		pass "busy scheduler lock contention returns failure"
	fi
	wait "$busy_pid" || true
	assert_file_lines "busy lock blocks duplicate manual send" "$TEST_SMS_TOOL_LOG" 2
}

test_scheduler_manual_send_does_not_claim_due_slot_same_minute()
{
	setup_case scheduler_manual_no_slot_claim
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance_daily=schedule
sms-feishu-forwarder.balance_daily.enabled='1'
sms-feishu-forwarder.balance_daily.name='balance_daily'
sms-feishu-forwarder.balance_daily.recipient='10086'
sms-feishu-forwarder.balance_daily.content='CXYE'
sms-feishu-forwarder.balance_daily.hour='9'
sms-feishu-forwarder.balance_daily.minute='5'
sms-feishu-forwarder.balance_daily.weekdays='*'"
	run_scheduler --send balance_daily
	assert_file_absent "manual send does not write last_slot" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.last_slot"
	assert_file_content "manual send records success result" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.result" "ok"
	assert_file_content "manual send records message" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.message" "sent"
	run_scheduler --once
	assert_file_lines "due scheduled send still runs in same minute after manual send" "$TEST_SMS_TOOL_LOG" 2
	assert_file_content "scheduled due send claims last_slot" "$SMSFF_SCHEDULE_STATE_DIR/balance_daily.last_slot" "2026-07-30-09-05"
}

test_scheduler_weekday_rejects_zero_padded_and_multi_digit_values()
{
	setup_case scheduler_weekday_strict
	export SMSFF_SMS_PORT="$CASE_DIR/sms-port"
	touch "$SMSFF_SMS_PORT"
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.bad_zero=schedule
sms-feishu-forwarder.bad_zero.enabled='1'
sms-feishu-forwarder.bad_zero.name='bad_zero'
sms-feishu-forwarder.bad_zero.recipient='10086'
sms-feishu-forwarder.bad_zero.content='CXLL'
sms-feishu-forwarder.bad_zero.hour='*'
sms-feishu-forwarder.bad_zero.minute='*'
sms-feishu-forwarder.bad_zero.weekdays='00'"
	if run_scheduler --check; then
		fail "scheduler rejects zero-padded weekday 00"
	else
		pass "scheduler rejects zero-padded weekday 00"
	fi
	export TEST_UCI_SHOW="sms-feishu-forwarder.good_list=schedule
sms-feishu-forwarder.good_list.enabled='1'
sms-feishu-forwarder.good_list.name='good_list'
sms-feishu-forwarder.good_list.recipient='10086'
sms-feishu-forwarder.good_list.content='CXLL'
sms-feishu-forwarder.good_list.hour='*'
sms-feishu-forwarder.good_list.minute='*'
sms-feishu-forwarder.good_list.weekdays='0,6'"
	run_scheduler --check && pass "scheduler accepts weekday comma list of single digits" || fail "scheduler accepts weekday comma list of single digits"
}

test_scheduler_loop_sleep_aligns_to_next_minute()
{
	setup_case scheduler_minute_aligned_sleep
	export TEST_SLEEP_FAST=1
	if grep -q 'interruptible_sleep 60' "$SCHEDULER"; then
		fail "scheduler loop does not use fixed post-run sleep 60"
	else
		pass "scheduler loop does not use fixed post-run sleep 60"
	fi
	grep -q 'next_minute_sleep' "$SCHEDULER" && grep -q "date '+%S'" "$SCHEDULER" && pass "scheduler computes sleep from current seconds" || fail "scheduler computes sleep from current seconds"
}

test_package_lifecycle_preserves_state_and_propagates_failure()
{
	setup_case package_lifecycle
	local root state prerm postinst
	root="$CASE_DIR/package-root"
	state="$root/etc/sms-feishu-forwarder/package-service-state"
	SERVICE_STATE_DIR="$CASE_DIR/service-state"
	SERVICE_LOG="$CASE_DIR/service.log"
	mkdir -p "$SERVICE_STATE_DIR"
	export SERVICE_STATE_DIR SERVICE_LOG
	: > "$SERVICE_LOG"
	prerm="$ROOT/packaging/ipk/prerm"
	postinst="$ROOT/packaging/ipk/postinst"
	mkdir -p "$root/etc/config" "$root/usr/share/sms-feishu-forwarder"
	write_init_mock "$root" sms-feishu-forwarder 1 1
	write_init_mock "$root" rpcd 1 1
	printf '%s\n' "config settings 'settings'" "	option enabled '1'" > "$root/etc/config/sms-feishu-forwarder"
	cp "$ROOT/packaging/ipk/default-config" "$root/usr/share/sms-feishu-forwarder/default-config"
	export SMSFF_PACKAGE_ROOT="$root"
	export SMSFF_PACKAGE_INIT_CMD="$root/etc/init.d/sms-feishu-forwarder"
	export SMSFF_PACKAGE_RPCD_INIT_CMD="$root/etc/init.d/rpcd"

	if sh "$prerm" >/dev/null 2>&1; then
		pass "package prerm records live service state"
	else
		fail "package prerm records live service state"
	fi
	assert_eq "package prerm preserves enabled intent" "$(sed -n 's/^enabled=//p' "$state" 2>/dev/null)" "1"
	assert_eq "package prerm preserves running intent" "$(sed -n 's/^running=//p' "$state" 2>/dev/null)" "1"
	assert_file_content "package prerm stops service before replacement" "$SERVICE_STATE_DIR/sms-feishu-forwarder.running" "0"
	assert_file_content "package prerm disables service before replacement" "$SERVICE_STATE_DIR/sms-feishu-forwarder.enabled" "0"

	if sh "$postinst" >/dev/null 2>&1; then
		pass "package post-upgrade reconciles prior service state"
	else
		fail "package post-upgrade reconciles prior service state"
	fi
	assert_file_content "package post-upgrade restores enabled state" "$SERVICE_STATE_DIR/sms-feishu-forwarder.enabled" "1"
	assert_file_content "package post-upgrade restores running state" "$SERVICE_STATE_DIR/sms-feishu-forwarder.running" "1"

	if sh "$prerm" >/dev/null 2>&1 && sh "$postinst" >/dev/null 2>&1; then
		pass "package force reinstall preserves service state"
	else
		fail "package force reinstall preserves service state"
	fi
	assert_file_content "force reinstall keeps service enabled" "$SERVICE_STATE_DIR/sms-feishu-forwarder.enabled" "1"
	assert_file_content "force reinstall keeps service running" "$SERVICE_STATE_DIR/sms-feishu-forwarder.running" "1"

	export INSTALL_FAIL_RESTART=1
	sh "$prerm" >/dev/null 2>&1
	if sh "$postinst" >/dev/null 2>&1; then
		fail "package restart failure is returned to package manager"
	else
		pass "package restart failure is returned to package manager"
	fi
	assert_file_content "package restart failure does not claim service is running" "$SERVICE_STATE_DIR/sms-feishu-forwarder.running" "0"
	unset INSTALL_FAIL_RESTART

	export INSTALL_FAIL_RPCD_RESTART=1
	if sh "$postinst" >/dev/null 2>&1; then
		fail "package rpcd restart failure is returned to package manager"
	else
		pass "package rpcd restart failure is returned to package manager"
	fi
	unset INSTALL_FAIL_RPCD_RESTART SMSFF_PACKAGE_ROOT SMSFF_PACKAGE_INIT_CMD SMSFF_PACKAGE_RPCD_INIT_CMD

	export SMSFF_PACKAGE_ROOT="$root"
	export SMSFF_PACKAGE_INIT_CMD="$root/etc/init.d/sms-feishu-forwarder"
	export SMSFF_PACKAGE_RPCD_INIT_CMD="$root/etc/init.d/rpcd"
	printf '1\n' > "$SERVICE_STATE_DIR/sms-feishu-forwarder.enabled"
	printf '1\n' > "$SERVICE_STATE_DIR/sms-feishu-forwarder.running"
	export INSTALL_RESTART_LIES=1
	sh "$prerm" >/dev/null 2>&1
	if sh "$postinst" >/dev/null 2>&1; then
		fail "package postinst rejects successful restart with service still down"
	else
		pass "package postinst rejects successful restart with service still down"
	fi
	assert_file_content "package postinst does not claim lying restart is running" "$SERVICE_STATE_DIR/sms-feishu-forwarder.running" "0"
	unset INSTALL_RESTART_LIES SMSFF_PACKAGE_ROOT SMSFF_PACKAGE_INIT_CMD SMSFF_PACKAGE_RPCD_INIT_CMD
}

test_scheduler_direct_get_preserves_apostrophe_and_backslash_content()
{
	setup_case scheduler_quoted_content
	export SMSFF_NOW_SLOT="2026-07-30-09-05"
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="$(cat <<'EOS'
sms-feishu-forwarder.quote_text=schedule
sms-feishu-forwarder.quote_text.enabled='1'
sms-feishu-forwarder.quote_text.name='quote_text'
sms-feishu-forwarder.quote_text.recipient='10086'
sms-feishu-forwarder.quote_text.content='Bob'\''s backslash \\ done'
sms-feishu-forwarder.quote_text.hour='9'
sms-feishu-forwarder.quote_text.minute='5'
sms-feishu-forwarder.quote_text.weekdays='*'
EOS
)"
	export TEST_UCI_GETS="$CASE_DIR/uci-gets"
	{
		printf '%s\t%s\n' "sms-feishu-forwarder.quote_text.content" "Bob's backslash \\ done"
	} > "$TEST_UCI_GETS"
	run_scheduler --once
	assert_eq "scheduler preserves apostrophe and backslash content through direct uci get" "$(cat "$TEST_SMS_TOOL_LOG")" "-d /dev/ttyUSB2 send 10086 Bob's backslash \\ done"
}

test_shipped_scheduler_defaults_and_init()
{
	assert_eq "default config auto-detects SMS port" "$(grep -c "option sms_port 'auto'" "$ROOT/files/etc/config/sms-feishu-forwarder")" "1"
	assert_eq "source-install defaults disable global forwarding and both schedules" "$(grep -c "option enabled '0'" "$ROOT/files/etc/config/sms-feishu-forwarder")" "3"
	assert_eq "default config has no enabled-on-install flags" "$(grep -c "option enabled '1'" "$ROOT/files/etc/config/sms-feishu-forwarder" || true)" "0"
	assert_eq "default config has traffic_hourly schedule" "$(grep -c "config schedule 'traffic_hourly'" "$ROOT/files/etc/config/sms-feishu-forwarder")" "1"
	assert_eq "default config has balance_daily schedule" "$(grep -c "config schedule 'balance_daily'" "$ROOT/files/etc/config/sms-feishu-forwarder")" "1"
	assert_eq "init supervises scheduler instance" "$(grep -c '/usr/bin/sms-feishu-scheduler' "$ROOT/files/etc/init.d/sms-feishu-forwarder")" "1"
}

test_install_seed_failure_rolls_back_replaced_files()
{
	setup_install_case install_seed_failure
	printf 'old bin\n' > "$INSTALL_ROOT/usr/bin/sms-feishu-forwarder"
	printf 'old init\n' > "$INSTALL_ROOT/etc/init.d/sms-feishu-forwarder"
	printf 'old config\n' > "$INSTALL_ROOT/etc/config/sms-feishu-forwarder"
	export INSTALL_FAIL_SEED=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "install seed failure returns failure"
	else
		pass "install seed failure returns failure"
	fi
	assert_file_content "seed failure restores binary" "$INSTALL_ROOT/usr/bin/sms-feishu-forwarder" "old bin"
	assert_file_content "seed failure restores init script" "$INSTALL_ROOT/etc/init.d/sms-feishu-forwarder" "old init"
	assert_file_content "seed failure restores config" "$INSTALL_ROOT/etc/config/sms-feishu-forwarder" "old config"
}

test_install_upgrade_stops_old_custom_service_skips_seed_and_runs_once()
{
	setup_install_case install_upgrade_custom_stop
	write_init_mock "$INSTALL_ROOT" sms-feishu-forwarder 1 1
	mkdir -p "$INSTALL_ROOT/var/lib/sms-feishu-forwarder"
	printf 'already-seen\n' > "$INSTALL_ROOT/var/lib/sms-feishu-forwarder/seen.keys"
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		pass "upgrade install succeeds with prior seen state"
	else
		fail "upgrade install succeeds with prior seen state"
	fi
	assert_eq "upgrade stops old custom service" "$(grep -c '^sms-feishu-forwarder stop$' "$SERVICE_LOG")" "1"
	assert_eq "upgrade skips seed when seen state exists" "$(grep -c '^--seed$' "$INSTALL_FORWARDER_LOG")" "0"
	assert_eq "upgrade runs once to forward pending messages" "$(grep -c '^--once$' "$INSTALL_FORWARDER_LOG")" "1"
}

test_install_candidate_failure_keeps_existing_custom_and_taskplan()
{
	setup_install_case install_candidate_failure_keeps_old
	write_init_mock "$INSTALL_ROOT" sms-feishu-forwarder 1 1
	write_init_mock "$INSTALL_ROOT" taskplan 1 1
	mkdir -p "$INSTALL_ROOT/var/lib/sms-feishu-forwarder"
	printf 'already-seen\n' > "$INSTALL_ROOT/var/lib/sms-feishu-forwarder/seen.keys"
	cat > "$INSTALL_ROOT/etc/config/taskplan" <<'EOS'
config stime
	option enable '1'
	option stype '12'
	option customscript '/root/send_10086_sms.sh'
EOS
	export INSTALL_FAIL_SCHED_CHECK=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" SMSFF_INSTALL_SCHEDULER_CMD="$SMSFF_INSTALL_SCHEDULER_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "candidate scheduler check failure returns failure"
	else
		pass "candidate scheduler check failure returns failure"
	fi
	assert_file_content "candidate failure leaves old custom running" "$SERVICE_STATE_DIR/sms-feishu-forwarder.running" "1"
	assert_file_content "candidate failure leaves old custom enabled" "$SERVICE_STATE_DIR/sms-feishu-forwarder.enabled" "1"
	assert_eq "candidate failure does not stop old custom before check" "$(grep -c '^sms-feishu-forwarder stop$' "$SERVICE_LOG")" "0"
	assert_eq "candidate failure performs zero custom stop/disable/start actions" "$(grep -c '^sms-feishu-forwarder \(stop\|disable\|start\)$' "$SERVICE_LOG")" "0"
	assert_eq "candidate failure leaves legacy taskplan enabled" "$(grep -c "option enable '1'" "$INSTALL_ROOT/etc/config/taskplan")" "1"
	assert_eq "candidate failure does not restart taskplan" "$(grep -c '^taskplan restart$' "$SERVICE_LOG")" "0"
}

test_install_rpcd_precheck_failure_keeps_existing_custom_live()
{
	setup_install_case install_rpcd_precheck_keeps_custom_live
	write_init_mock "$INSTALL_ROOT" sms-feishu-forwarder 1 1
	write_init_mock "$INSTALL_ROOT" rpcd 1 1
	mkdir -p "$INSTALL_ROOT/var/lib/sms-feishu-forwarder"
	printf 'already-seen\n' > "$INSTALL_ROOT/var/lib/sms-feishu-forwarder/seen.keys"
	rm -f "$INSTALL_ROOT/usr/share/rpcd/ucode/sms-feishu-forwarder.uc" "$INSTALL_ROOT/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json"
	export INSTALL_FAIL_RPCD_RESTART=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "rpcd pre-cutover failure returns failure"
	else
		pass "rpcd pre-cutover failure returns failure"
	fi
	assert_file_absent "rpcd pre-cutover failure removes new ucode" "$INSTALL_ROOT/usr/share/rpcd/ucode/sms-feishu-forwarder.uc"
	assert_file_absent "rpcd pre-cutover failure removes new ACL" "$INSTALL_ROOT/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json"
	assert_file_content "rpcd pre-cutover failure leaves old custom running" "$SERVICE_STATE_DIR/sms-feishu-forwarder.running" "1"
	assert_file_content "rpcd pre-cutover failure leaves old custom enabled" "$SERVICE_STATE_DIR/sms-feishu-forwarder.enabled" "1"
	assert_eq "rpcd pre-cutover failure performs zero custom stop/disable/start actions" "$(grep -c '^sms-feishu-forwarder \(stop\|disable\|start\)$' "$SERVICE_LOG")" "0"
	assert_eq "rpcd pre-cutover failure never seeds or runs once" "$(wc -l < "$INSTALL_FORWARDER_LOG")" "0"
	assert_eq "rpcd pre-cutover failure attempts required and rollback rpcd restarts" "$(grep -c '^rpcd restart$' "$SERVICE_LOG")" "2"
}

test_install_migrates_webhook_with_stdin_batch_and_deletes_old_option()
{
	setup_install_case install_webhook_migration
	export TEST_UCI_BATCH_LOG="$CASE_DIR/uci-batch.log"
	cat > "$INSTALL_ROOT/etc/config/sms-feishu-forwarder" <<'EOS'
config settings 'settings'
	option enabled '1'
	option feishu_webhook 'https://open.feishu.cn/open-apis/bot/v2/hook/old-secret-token'
EOS
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		pass "install succeeds with legacy webhook migration"
	else
		fail "install succeeds with legacy webhook migration"
	fi
	grep -q "set smsforward.settings.feishu_webhook='https://open.feishu.cn/open-apis/bot/v2/hook/old-secret-token'" "$TEST_UCI_BATCH_LOG" && pass "installer migrates webhook through stdin UCI batch" || fail "installer migrates webhook through stdin UCI batch"
	if grep -q 'old-secret-token' "$SERVICE_LOG" "$INSTALL_FORWARDER_LOG" 2>/dev/null; then
		fail "installer does not pass webhook through service argv/log"
	else
		pass "installer does not pass webhook through service argv/log"
	fi
	if grep -q 'feishu_webhook' "$INSTALL_ROOT/etc/config/sms-feishu-forwarder"; then
		fail "installer deletes old browser-readable webhook option"
	else
		pass "installer deletes old browser-readable webhook option"
	fi
}

test_install_rollback_restores_webhook_migration_configs()
{
	setup_install_case install_webhook_migration_rollback
	export TEST_UCI_BATCH_LOG="$CASE_DIR/uci-batch.log"
	cat > "$INSTALL_ROOT/etc/config/smsforward" <<'EOS'
config settings 'settings'
	option feishu_webhook 'https://open.feishu.cn/open-apis/bot/v2/hook/original-token'
	option keep 'smsforward'
EOS
	cat > "$INSTALL_ROOT/etc/config/sms-feishu-forwarder" <<'EOS'
config settings 'settings'
	option enabled '1'
	option feishu_webhook 'https://open.feishu.cn/open-apis/bot/v2/hook/migrated-token'
	option keep 'sms-feishu-forwarder'
EOS
	export INSTALL_FAIL_ONCE=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "migration followed by failure returns failure"
	else
		pass "migration followed by failure returns failure"
	fi
	assert_eq "rollback restores prior smsforward webhook config" "$(grep -c 'original-token' "$INSTALL_ROOT/etc/config/smsforward")" "1"
	assert_eq "rollback removes migrated smsforward webhook" "$(grep -c 'migrated-token' "$INSTALL_ROOT/etc/config/smsforward")" "0"
	assert_eq "rollback restores prior sms-feishu-forwarder webhook config" "$(grep -c 'migrated-token' "$INSTALL_ROOT/etc/config/sms-feishu-forwarder")" "1"
	if grep -q 'migrated-token' "$SERVICE_LOG" "$INSTALL_FORWARDER_LOG" 2>/dev/null; then
		fail "rollback migration does not expose webhook through service argv/log"
	else
		pass "rollback migration does not expose webhook through service argv/log"
	fi
}

test_install_rollback_removes_created_smsforward_config()
{
	setup_install_case install_webhook_migration_remove_created
	cat > "$INSTALL_ROOT/etc/config/sms-feishu-forwarder" <<'EOS'
config settings 'settings'
	option enabled '1'
	option feishu_webhook 'https://open.feishu.cn/open-apis/bot/v2/hook/migrated-token'
EOS
	export INSTALL_FAIL_ONCE=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "migration creating smsforward followed by failure returns failure"
	else
		pass "migration creating smsforward followed by failure returns failure"
	fi
	assert_file_absent "rollback removes smsforward config created by migration" "$INSTALL_ROOT/etc/config/smsforward"
	assert_eq "rollback restores sms-feishu-forwarder config after created smsforward migration" "$(grep -c 'migrated-token' "$INSTALL_ROOT/etc/config/sms-feishu-forwarder")" "1"
}

test_install_webhook_migration_batch_failure_cleans_secret_temp()
{
	setup_install_case install_webhook_batch_failure_temp_cleanup
	local case_tmpdir
	case_tmpdir="$CASE_DIR/tmpdir"
	mkdir -p "$INSTALL_ROOT/tmp" "$case_tmpdir"
	printf 'old bin\n' > "$INSTALL_ROOT/usr/bin/sms-feishu-forwarder"
	cat > "$INSTALL_ROOT/etc/config/sms-feishu-forwarder" <<'EOS'
config settings 'settings'
	option enabled '1'
	option feishu_webhook 'https://open.feishu.cn/open-apis/bot/v2/hook/batch-fail-secret'
	option keep 'sms-feishu-forwarder'
EOS
	export TEST_UCI_FAIL_BATCH_CONTAINS="smsforward.settings.feishu_webhook"
	if ROOT="$INSTALL_ROOT" TMPDIR="$case_tmpdir" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "webhook migration UCI batch failure returns failure"
	else
		pass "webhook migration UCI batch failure returns failure"
	fi
	assert_file_content "webhook migration batch failure rolls back installed binary" "$INSTALL_ROOT/usr/bin/sms-feishu-forwarder" "old bin"
	assert_eq "webhook migration batch failure restores old webhook config" "$(grep -c 'batch-fail-secret' "$INSTALL_ROOT/etc/config/sms-feishu-forwarder")" "1"
	if find "$INSTALL_ROOT/tmp" "$case_tmpdir" -type f -name 'smsff-uci.*' -exec grep -l 'batch-fail-secret' {} + 2>/dev/null | grep -q .; then
		fail "webhook migration batch failure removes secret UCI temp files"
	else
		pass "webhook migration batch failure removes secret UCI temp files"
	fi
	if grep -q 'batch-fail-secret' "$SERVICE_LOG" "$INSTALL_FORWARDER_LOG" 2>/dev/null; then
		fail "webhook migration batch failure does not expose webhook through service argv/log"
	else
		pass "webhook migration batch failure does not expose webhook through service argv/log"
	fi
}

test_install_rollback_restores_prior_custom_service_state()
{
	setup_install_case install_custom_rollback
	write_init_mock "$INSTALL_ROOT" sms-feishu-forwarder 1 1
	mkdir -p "$INSTALL_ROOT/var/lib/sms-feishu-forwarder"
	printf 'already-seen\n' > "$INSTALL_ROOT/var/lib/sms-feishu-forwarder/seen.keys"
	export TEST_INSTALL_ASSERT_CUSTOM_STOPPED=1
	export INSTALL_FAIL_ONCE=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "custom rollback failure returns failure"
	else
		pass "custom rollback failure returns failure"
	fi
	assert_eq "rollback restarts prior running custom service" "$(grep -c '^sms-feishu-forwarder start$' "$SERVICE_LOG")" "1"
	assert_file_content "rollback restores prior custom enabled state" "$SERVICE_STATE_DIR/sms-feishu-forwarder.enabled" "1"
	assert_file_content "rollback restores prior custom running state" "$SERVICE_STATE_DIR/sms-feishu-forwarder.running" "1"
}

test_install_restart_failure_removes_new_files_and_restores_legacy()
{
	setup_install_case install_restart_failure
	rm -f "$INSTALL_ROOT/usr/bin/sms-feishu-forwarder" "$INSTALL_ROOT/etc/init.d/sms-feishu-forwarder" "$INSTALL_ROOT/etc/config/sms-feishu-forwarder"
	export INSTALL_FAIL_RESTART=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "install restart failure returns failure"
	else
		pass "install restart failure returns failure"
	fi
	assert_file_absent "restart failure removes new binary" "$INSTALL_ROOT/usr/bin/sms-feishu-forwarder"
	assert_file_absent "restart failure removes new init script" "$INSTALL_ROOT/etc/init.d/sms-feishu-forwarder"
	assert_file_absent "restart failure removes new config" "$INSTALL_ROOT/etc/config/sms-feishu-forwarder"
	assert_file_content "restart failure restores smsforward enabled" "$SERVICE_STATE_DIR/smsforward.enabled" "1"
	assert_file_content "restart failure restores smsforward running" "$SERVICE_STATE_DIR/smsforward.running" "1"
	assert_file_content "restart failure restores sms_forwarder enabled" "$SERVICE_STATE_DIR/sms_forwarder.enabled" "1"
	assert_file_content "restart failure restores sms_forwarder running" "$SERVICE_STATE_DIR/sms_forwarder.running" "1"
}

test_install_success_leaves_disabled_vendor_untouched()
{
	setup_install_case install_vendor_disabled
	printf '0\n' > "$SERVICE_STATE_DIR/smsforward.enabled"
	printf '1\n' > "$SERVICE_STATE_DIR/smsforward.running"
	printf '0\n' > "$SERVICE_STATE_DIR/sms_forwarder.enabled"
	printf '1\n' > "$SERVICE_STATE_DIR/sms_forwarder.running"
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		pass "install success with disabled vendor service"
	else
		fail "install success with disabled vendor service"
	fi
	assert_file_content "running legacy smsforward is stopped" "$SERVICE_STATE_DIR/smsforward.running" "0"
	assert_file_content "legacy smsforward remains disabled" "$SERVICE_STATE_DIR/smsforward.enabled" "0"
	assert_file_content "disabled vendor remains disabled" "$SERVICE_STATE_DIR/sms_forwarder.enabled" "0"
	assert_file_content "disabled vendor running state untouched" "$SERVICE_STATE_DIR/sms_forwarder.running" "1"
	if grep -q '^sms_forwarder \(stop\|disable\|start\|enable\)$' "$SERVICE_LOG"; then
		fail "disabled vendor service was not touched"
	else
		pass "disabled vendor service was not touched"
	fi
}

test_install_success_disables_legacy_taskplan_sms_job()
{
	setup_install_case install_taskplan_migration
	cat > "$INSTALL_ROOT/etc/config/taskplan" <<'EOS'
config global 'global'
	option customscript '/root/send_10086_sms.sh'
	option customscript2 '/root/unrelated.sh'

config stime
	option enable '1'
	option stype '12'
	option remarks 'old sms traffic'

config stime
	option enable '1'
	option stype '15'
	option remarks 'unrelated customscript2'
EOS
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		pass "install success with taskplan migration"
	else
		fail "install success with taskplan migration"
	fi
	assert_eq "legacy taskplan customscript job disabled" "$(grep -c "option enable '0'" "$INSTALL_ROOT/etc/config/taskplan")" "1"
	assert_eq "unrelated taskplan job remains enabled" "$(grep -c "option enable '1'" "$INSTALL_ROOT/etc/config/taskplan")" "1"
	assert_file_content "old taskplan script backup exists" "$INSTALL_ROOT/etc/sms-feishu-forwarder/legacy-send_10086_sms.sh.path" "/root/send_10086_sms.sh"
}

test_taskplan_parser_isolates_customscript_per_section()
{
	setup_install_case install_taskplan_section_isolation
	write_init_mock "$INSTALL_ROOT" taskplan 1 1
	cat > "$INSTALL_ROOT/etc/config/taskplan" <<'EOS'
config global 'global'
	option customscript '/root/send_10086_sms.sh'

config stime
	option enable '1'
	option stype '12'
	option remarks 'legacy via global'

config stime
	option enable '1'
	option stype '12'
	option customscript '/root/other.sh'
	option remarks 'explicit other script'

config stime
	option enable '1'
	option stype '12'
	option customscript '/root/send_10086_sms.sh'
	option remarks 'explicit legacy script'

config stime
	option enable '1'
	option stype '15'
	option customscript '/root/send_10086_sms.sh'
	option remarks 'wrong stype'
EOS
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		pass "install success with isolated taskplan parser"
	else
		fail "install success with isolated taskplan parser"
	fi
	assert_eq "taskplan disables only two legacy sms sections" "$(grep -c "option enable '0'" "$INSTALL_ROOT/etc/config/taskplan")" "2"
	assert_eq "taskplan preserves explicit other script and unrelated stype" "$(grep -c "option enable '1'" "$INSTALL_ROOT/etc/config/taskplan")" "2"
}

test_install_restarts_taskplan_and_preserves_existing_legacy_state()
{
	setup_install_case install_taskplan_restart_preserve
	write_init_mock "$INSTALL_ROOT" taskplan 1 1
	mkdir -p "$INSTALL_ROOT/etc/sms-feishu-forwarder"
	cat > "$INSTALL_ROOT/etc/sms-feishu-forwarder/legacy-state" <<'EOS'
smsforward_enabled=0
smsforward_running=0
sms_forwarder_enabled=0
sms_forwarder_running=0
EOS
	cat > "$INSTALL_ROOT/etc/config/taskplan" <<'EOS'
config stime
	option enable '1'
	option stype '12'
	option customscript '/root/send_10086_sms.sh'
EOS
	ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1
	assert_eq "install restarts taskplan after disabling legacy job" "$(grep -c '^taskplan restart$' "$SERVICE_LOG")" "1"
	assert_file_content "install preserves existing original legacy-state during upgrade" "$INSTALL_ROOT/etc/sms-feishu-forwarder/legacy-state" "smsforward_enabled=0
smsforward_running=0
sms_forwarder_enabled=0
sms_forwarder_running=0"
}

test_install_taskplan_restart_failure_rolls_back_cutover()
{
	setup_install_case install_taskplan_restart_failure
	write_init_mock "$INSTALL_ROOT" sms-feishu-forwarder 1 1
	write_init_mock "$INSTALL_ROOT" taskplan 1 1
	mkdir -p "$INSTALL_ROOT/var/lib/sms-feishu-forwarder"
	printf 'already-seen\n' > "$INSTALL_ROOT/var/lib/sms-feishu-forwarder/seen.keys"
	cat > "$INSTALL_ROOT/etc/config/taskplan" <<'EOS'
config stime
	option enable '1'
	option stype '12'
	option customscript '/root/send_10086_sms.sh'
EOS
	export INSTALL_FAIL_TASKPLAN_RESTART=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "taskplan restart failure fails install"
	else
		pass "taskplan restart failure fails install"
	fi
	assert_eq "rollback restores taskplan enabled after restart failure" "$(grep -c "option enable '1'" "$INSTALL_ROOT/etc/config/taskplan")" "1"
	assert_file_content "rollback restores prior custom enabled after taskplan failure" "$SERVICE_STATE_DIR/sms-feishu-forwarder.enabled" "1"
	assert_file_content "rollback restores prior custom running after taskplan failure" "$SERVICE_STATE_DIR/sms-feishu-forwarder.running" "1"
	assert_eq "taskplan restart attempted required and rollback best effort" "$(grep -c '^taskplan restart$' "$SERVICE_LOG")" "2"
}

test_install_late_failure_restores_mt5700m_cutover_state()
{
	setup_install_case install_mt5700m_cutover_rollback
	write_init_mock "$INSTALL_ROOT" sms-feishu-forwarder 1 1
	write_init_mock "$INSTALL_ROOT" taskplan 1 1
	write_init_mock "$INSTALL_ROOT" ubus-at-daemon 1 1
	mkdir -p "$INSTALL_ROOT/usr/sbin"
	for helper in mt5700m-at mt5700m-read mt5700m-manager; do
		printf '#!/bin/sh\nexit 0\n' > "$INSTALL_ROOT/usr/sbin/$helper"
		chmod 755 "$INSTALL_ROOT/usr/sbin/$helper"
	done
	cat > "$INSTALL_ROOT/etc/config/taskplan" <<'EOS'
config stime
	option enable '1'
	option stype '12'
	option customscript '/root/send_10086_sms.sh'
EOS
	export TEST_INIT_RUN_CUTOVER=1
	export INSTALL_FAIL_TASKPLAN_RESTART_AFTER_CUTOVER=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" SMSFF_INSTALL_SCHEDULER_CMD="$SMSFF_INSTALL_SCHEDULER_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "late cutover failure returns failure"
	else
		pass "late cutover failure returns failure"
	fi
	assert_eq "late failure exercised MT5700M cutover" "$(grep -c '^ubus-at-daemon stop$' "$SERVICE_LOG")" "1"
	assert_file_content "cutover rollback restores ubus-at-daemon enabled state" "$SERVICE_STATE_DIR/ubus-at-daemon.enabled" "1"
	assert_file_content "cutover rollback restores ubus-at-daemon running state" "$SERVICE_STATE_DIR/ubus-at-daemon.running" "1"
	assert_file_absent "cutover rollback removes newly-created cutover marker" "$INSTALL_ROOT/etc/sms-feishu-forwarder/mt5700m-cutover.complete"
	assert_file_absent "cutover rollback removes newly-created cutover state" "$INSTALL_ROOT/etc/sms-feishu-forwarder/legacy-cutover-state"
	assert_file_absent "cutover rollback removes newly-created taskplan backup" "$INSTALL_ROOT/etc/sms-feishu-forwarder/taskplan.before-mt5700m-cutover"
	assert_eq "cutover rollback restores legacy taskplan enable flag" "$(grep -c "option enable '1'" "$INSTALL_ROOT/etc/config/taskplan")" "1"
	unset TEST_INIT_RUN_CUTOVER INSTALL_FAIL_TASKPLAN_RESTART_AFTER_CUTOVER
}

test_install_success_restarts_rpcd_after_plugin_files()
{
	setup_install_case install_rpcd_restart
	write_init_mock "$INSTALL_ROOT" rpcd 1 1
	export TEST_RPCD_ASSERT_INSTALLED=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		pass "install success restarts rpcd"
	else
		fail "install success restarts rpcd"
	fi
	assert_eq "install restarts rpcd once after plugin files" "$(grep -c '^rpcd restart$' "$SERVICE_LOG")" "1"
}

test_install_without_target_actions_does_not_restart_rpcd()
{
	setup_install_case install_root_no_target_rpcd
	write_init_mock "$INSTALL_ROOT" rpcd 1 1
	ROOT="$INSTALL_ROOT" SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1
	assert_eq "ROOT test install without target actions skips rpcd restart" "$(grep -c '^rpcd restart$' "$SERVICE_LOG")" "0"
}

test_install_rpcd_restart_failure_rolls_back_and_restarts_rpcd_best_effort()
{
	setup_install_case install_rpcd_restart_failure
	write_init_mock "$INSTALL_ROOT" rpcd 1 1
	rm -f "$INSTALL_ROOT/usr/share/rpcd/ucode/sms-feishu-forwarder.uc" "$INSTALL_ROOT/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json"
	export INSTALL_FAIL_RPCD_RESTART=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "install rpcd restart failure returns failure"
	else
		pass "install rpcd restart failure returns failure"
	fi
	assert_file_absent "rpcd restart failure removes new ucode" "$INSTALL_ROOT/usr/share/rpcd/ucode/sms-feishu-forwarder.uc"
	assert_file_absent "rpcd restart failure removes new ACL" "$INSTALL_ROOT/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json"
	assert_eq "rollback restarts rpcd best effort after restore" "$(grep -c '^rpcd restart$' "$SERVICE_LOG")" "2"
}

test_install_rollback_restarts_taskplan_after_restore()
{
	setup_install_case install_rollback_taskplan_restart
	write_init_mock "$INSTALL_ROOT" taskplan 1 1
	cat > "$INSTALL_ROOT/etc/config/taskplan" <<'EOS'
config stime
	option enable '1'
	option stype '12'
	option customscript '/root/send_10086_sms.sh'
EOS
	export INSTALL_FAIL_RESTART=1
	if ROOT="$INSTALL_ROOT" SMSFF_INSTALL_RUN_TARGET_ACTIONS=1 SMSFF_INSTALL_FORWARDER_CMD="$MOCK_BIN/install-forwarder" SMSFF_INSTALL_INIT_CMD="$INSTALL_INIT_CMD" sh "$ROOT/install.sh" >/dev/null 2>&1; then
		fail "install rollback taskplan failure returns failure"
	else
		pass "install rollback taskplan failure returns failure"
	fi
	assert_eq "early rollback does not restart untouched taskplan" "$(grep -c '^taskplan restart$' "$SERVICE_LOG")" "0"
	assert_eq "rollback restores taskplan enabled job" "$(grep -c "option enable '1'" "$INSTALL_ROOT/etc/config/taskplan")" "1"
}

test_uninstall_removes_phase2_files_restores_taskplan_and_managed_prior_files()
{
	setup_install_case uninstall_phase2
	write_init_mock "$INSTALL_ROOT" taskplan 1 1
	write_init_mock "$INSTALL_ROOT" rpcd 1 1
	mkdir -p "$INSTALL_ROOT/etc/sms-feishu-forwarder/backups/20260730-090000/usr/bin" \
		"$INSTALL_ROOT/etc/sms-feishu-forwarder/backups/20260730-090000/etc/config" \
		"$INSTALL_ROOT/etc/sms-feishu-forwarder/backups/20260730-090000/www/luci-static/resources/view"
	printf 'prior forwarder\n' > "$INSTALL_ROOT/etc/sms-feishu-forwarder/backups/20260730-090000/usr/bin/sms-feishu-forwarder"
	printf 'prior taskplan\n' > "$INSTALL_ROOT/etc/sms-feishu-forwarder/backups/20260730-090000/etc/config/taskplan"
	printf 'prior luci\n' > "$INSTALL_ROOT/etc/sms-feishu-forwarder/backups/20260730-090000/www/luci-static/resources/view/sms-feishu-forwarder.js"
	mkdir -p "$INSTALL_ROOT/usr/bin" "$INSTALL_ROOT/usr/share/rpcd/ucode" "$INSTALL_ROOT/usr/share/rpcd/acl.d" "$INSTALL_ROOT/usr/share/luci/menu.d" "$INSTALL_ROOT/www/luci-static/resources/view" "$INSTALL_ROOT/etc/config" "$INSTALL_ROOT/etc/init.d"
	printf 'new forwarder\n' > "$INSTALL_ROOT/usr/bin/sms-feishu-forwarder"
	printf 'new scheduler\n' > "$INSTALL_ROOT/usr/bin/sms-feishu-scheduler"
	printf 'new init\n' > "$INSTALL_ROOT/etc/init.d/sms-feishu-forwarder"
	printf 'new rpcd\n' > "$INSTALL_ROOT/usr/share/rpcd/ucode/sms-feishu-forwarder.uc"
	printf 'new acl\n' > "$INSTALL_ROOT/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json"
	printf 'new menu\n' > "$INSTALL_ROOT/usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json"
	printf 'new luci\n' > "$INSTALL_ROOT/www/luci-static/resources/view/sms-feishu-forwarder.js"
	printf 'new taskplan\n' > "$INSTALL_ROOT/etc/config/taskplan"
	ROOT="$INSTALL_ROOT" SERVICE_LOG="$SERVICE_LOG" SERVICE_STATE_DIR="$SERVICE_STATE_DIR" sh "$ROOT/uninstall.sh" >/dev/null
	assert_file_content "uninstall restores managed prior forwarder" "$INSTALL_ROOT/usr/bin/sms-feishu-forwarder" "prior forwarder"
	assert_file_absent "uninstall removes scheduler without prior" "$INSTALL_ROOT/usr/bin/sms-feishu-scheduler"
	assert_file_absent "uninstall removes rpcd ucode" "$INSTALL_ROOT/usr/share/rpcd/ucode/sms-feishu-forwarder.uc"
	assert_file_absent "uninstall removes rpcd acl" "$INSTALL_ROOT/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json"
	assert_file_absent "uninstall removes luci menu" "$INSTALL_ROOT/usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json"
	assert_file_content "uninstall restores managed prior luci view" "$INSTALL_ROOT/www/luci-static/resources/view/sms-feishu-forwarder.js" "prior luci"
	assert_file_content "uninstall restores taskplan config" "$INSTALL_ROOT/etc/config/taskplan" "prior taskplan"
	assert_eq "uninstall restarts taskplan after restore" "$(grep -c '^taskplan restart$' "$SERVICE_LOG")" "1"
	assert_eq "uninstall restarts rpcd after plugin removal" "$(grep -c '^rpcd restart$' "$SERVICE_LOG")" "1"
}

test_uninstall_without_taskplan_backup_preserves_current_taskplan()
{
	setup_install_case uninstall_no_taskplan_backup
	mkdir -p "$INSTALL_ROOT/etc/sms-feishu-forwarder/backups/20260730-090000/usr/bin" \
		"$INSTALL_ROOT/usr/bin" "$INSTALL_ROOT/etc/config"
	printf 'prior forwarder\n' > "$INSTALL_ROOT/etc/sms-feishu-forwarder/backups/20260730-090000/usr/bin/sms-feishu-forwarder"
	printf 'new forwarder\n' > "$INSTALL_ROOT/usr/bin/sms-feishu-forwarder"
	cat > "$INSTALL_ROOT/etc/config/taskplan" <<'EOS'
config stime
	option enable '1'
	option stype '15'
	option remarks 'unrelated job'
EOS
	ROOT="$INSTALL_ROOT" SERVICE_LOG="$SERVICE_LOG" SERVICE_STATE_DIR="$SERVICE_STATE_DIR" sh "$ROOT/uninstall.sh" >/dev/null
	assert_eq "uninstall without taskplan backup preserves unrelated current job" "$(grep -c "unrelated job" "$INSTALL_ROOT/etc/config/taskplan")" "1"
	assert_file_content "uninstall still restores managed forwarder backup" "$INSTALL_ROOT/usr/bin/sms-feishu-forwarder" "prior forwarder"
}

test_luci_webui_least_privilege_files()
{
	local menu="$ROOT/files/usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json"
	local acl="$ROOT/files/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json"
	local view="$ROOT/files/www/luci-static/resources/view/sms-feishu-forwarder.js"
	local rpcd="$ROOT/files/usr/share/rpcd/ucode/sms-feishu-forwarder.uc"
	jq -e '."admin/modem/sms-feishu".title == "短信飞书助手"' "$menu" >/dev/null && pass "LuCI menu path and title" || fail "LuCI menu path and title"
	jq -e '."luci-app-sms-feishu-forwarder".write.ubus."sms-feishu-forwarder" | index("send_schedule")' "$acl" >/dev/null && pass "ACL grants custom manual send method" || fail "ACL grants custom manual send method"
	if jq -e '.. | objects | .execute? // empty' "$acl" >/dev/null; then
		fail "ACL does not expose arbitrary execute"
	else
		pass "ACL does not expose arbitrary execute"
	fi
	grep -q 'valid_section' "$rpcd" && pass "rpcd validates schedule section" || fail "rpcd validates schedule section"
	grep -q "feishu_webhook" "$view" && grep -q "o.password = true" "$view" && pass "WebUI masks webhook input" || fail "WebUI masks webhook input"
	assert_eq "LuCI action RPCs preserve response objects instead of extracting scalar code" "$(grep -F -c "expect: { '': { code: 1 } }" "$view")" "5"
	apply_block="$(sed -n '/handleSaveApply: function(ev, mode)/,/^[[:space:]]*},$/p' "$view")"
	if printf '%s\n' "$apply_block" | grep -q "ui.changes.apply(mode == '0')" && printf '%s\n' "$apply_block" | grep -q 'callRestart()'; then
		pass "LuCI Save and Apply synchronizes init enable and runtime state"
	else
		fail "LuCI Save and Apply synchronizes init enable and runtime state"
	fi
	if grep -q 'get.*feishu_webhook' "$rpcd"; then
		fail "status RPC does not return webhook"
	else
		pass "status RPC does not return webhook"
	fi
}

test_luci_parses_real_modem_info_and_allows_chinese_schedule_name()
{
	local view="$ROOT/files/www/luci-static/resources/view/sms-feishu-forwarder.js"
	grep -q 'data\[1\].*modem' "$view" && pass "LuCI renders modem data from safe status RPC" || fail "LuCI renders modem data from safe status RPC"
	grep -q 'online_devices: modem.online_devices' "$ROOT/files/usr/share/rpcd/ucode/sms-feishu-forwarder.uc" && pass "status RPC exposes safe online device count" || fail "status RPC exposes safe online device count"
	grep -q 'table-layout:fixed' "$view" && grep -q 'o.render = function() { return status; };' "$view" && ! grep -q "_('概览')" "$view" && pass "LuCI status overview is full-width without nested overview label" || fail "LuCI status overview is full-width without nested overview label"
	for field in "在线设备" "网络模式" "RSRP" "RSRQ / SINR" "模组温度" "PCI / ARFCN" "WAN 地址" "运行时间"; do
		grep -q "$field" "$view" || fail "LuCI overview displays $field"
	done
	if grep -q 'RSRQ / SINR' "$view" && grep -q 'PCI / ARFCN' "$view" && grep -q 'WAN 地址' "$view" && grep -q '运行时间' "$view"; then
		pass "LuCI overview displays all safe modem fields"
	fi
	if grep -Eq 'modem_info|connection_status' "$view"; then
		fail "LuCI does not parse raw qmodem identity-bearing payloads"
	else
		pass "LuCI does not parse raw qmodem identity-bearing payloads"
	fi
	if grep -q "o.datatype = 'uciname'" "$view"; then
		fail "LuCI schedule display name does not use uciname datatype"
	else
		pass "LuCI schedule display name does not use uciname datatype"
	fi
	grep -q 'o.cfgvalue = function() { return '\'''\''; };' "$view" && grep -q 'if (value)' "$view" && pass "LuCI webhook remains write-only blank-preserving" || fail "LuCI webhook remains write-only blank-preserving"
}

test_rpcd_openwrt_plugin_shape_and_safe_status()
{
	local rpcd="$ROOT/files/usr/share/rpcd/ucode/sms-feishu-forwarder.uc"
	local acl="$ROOT/files/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json"
	grep -q "^[[:space:]]*'sms-feishu-forwarder': {[[:space:]]*$" "$rpcd" && pass "rpcd returns outer plugin object" || fail "rpcd returns outer plugin object"
	grep -q 'get_all' "$rpcd" && grep -q "'.type'.*schedule" "$rpcd" && pass "rpcd validates section with UCI get_all type" || fail "rpcd validates section with UCI get_all type"
	grep -q "instance_state('forwarder')" "$rpcd" && grep -q "instance_state('scheduler')" "$rpcd" && pass "rpcd separates forwarder and scheduler procd status" || fail "rpcd separates forwarder and scheduler procd status"
	grep -q 'function scheduler_send_command(section)' "$rpcd" && pass "rpcd keeps schedule send command behind validator" || fail "rpcd keeps schedule send command behind validator"
	grep -q "scheduler_send_command(section)" "$rpcd" && pass "rpcd uses fixed validated scheduler command helper" || fail "rpcd uses fixed validated scheduler command helper"
	grep -q '/etc/init.d/sms-feishu-forwarder stop' "$rpcd" && grep -q '/usr/bin/sms-feishu-forwarder --seed' "$rpcd" && grep -q '/etc/init.d/sms-feishu-forwarder restart' "$rpcd" && grep -q 'exit $rc' "$rpcd" && pass "rpcd seed uses fixed stop seed restart command and returns seed status" || fail "rpcd seed uses fixed stop seed restart command and returns seed status"
	grep -q "function restart_service()" "$rpcd" && grep -q "config_value('enabled', '1')" "$rpcd" && pass "rpcd restart reads UCI enabled flag" || fail "rpcd restart reads UCI enabled flag"
	grep -q "/etc/init.d/sms-feishu-forwarder enable >/dev/null 2>&1; /etc/init.d/sms-feishu-forwarder restart >/dev/null 2>&1" "$rpcd" && pass "rpcd restart enabled branch enables boot then restarts" || fail "rpcd restart enabled branch enables boot then restarts"
	grep -q "/etc/init.d/sms-feishu-forwarder stop >/dev/null 2>&1; /etc/init.d/sms-feishu-forwarder disable >/dev/null 2>&1" "$rpcd" && pass "rpcd restart disabled branch stops then disables boot" || fail "rpcd restart disabled branch stops then disables boot"
	if jq -e '.. | objects | select(has("rc"))' "$acl" >/dev/null || sed -n '/function restart_service()/,/^}/p' "$rpcd" | grep -Eq "system\\([^']|\\+"; then
		fail "rpcd restart avoids generic rc ACL and shell interpolation"
	else
		pass "rpcd restart avoids generic rc ACL and shell interpolation"
	fi
	grep -A6 'send_schedule: {' "$rpcd" | grep -q 'args: { section: "" }' && pass "rpcd send_schedule declares args policy" || fail "rpcd send_schedule declares args policy"
	grep -A8 'send_schedule: {' "$rpcd" | grep -q 'request.args.section' && pass "rpcd send_schedule reads request.args.section" || fail "rpcd send_schedule reads request.args.section"
	grep -A6 'set_webhook: {' "$rpcd" | grep -q 'args: { webhook: "" }' && pass "rpcd set_webhook declares args policy" || fail "rpcd set_webhook declares args policy"
	grep -A8 'set_webhook: {' "$rpcd" | grep -q 'request.args.webhook' && pass "rpcd set_webhook reads request.args.webhook" || fail "rpcd set_webhook reads request.args.webhook"
	grep -q "c.set('smsforward', 'settings', 'settings')" "$rpcd" && ! grep -q "c.add('smsforward', 'settings'" "$rpcd" && pass "rpcd creates named webhook UCI section" || fail "rpcd creates named webhook UCI section"
	grep -q "if (!c.set('smsforward', 'settings', 'feishu_webhook', url))" "$rpcd" && grep -q "if (!c.commit('smsforward'))" "$rpcd" && pass "rpcd reports webhook UCI write failures" || fail "rpcd reports webhook UCI write failures"
}

test_browser_identity_secret_containment()
{
	local acl="$ROOT/files/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json"
	local view="$ROOT/files/www/luci-static/resources/view/sms-feishu-forwarder.js"
	local rpcd="$ROOT/files/usr/share/rpcd/ucode/sms-feishu-forwarder.uc"
	local config="$ROOT/files/etc/config/sms-feishu-forwarder"
	local status keys

	if jq -e '.. | objects | select(has("qmodem"))' "$acl" >/dev/null; then
		fail "ACL does not grant browser qmodem status methods"
	else
		pass "ACL does not grant browser qmodem status methods"
	fi
	if grep -Eq 'call(ConnectStatus|BaseInfo|CellInfo)|object: '\''qmodem'\''' "$view"; then
		fail "LuCI does not call qmodem directly"
	else
		pass "LuCI does not call qmodem directly"
	fi
	if grep -Eq "uci\\.(set|get|load).*feishu_webhook|form\\.Value, 'feishu_webhook'" "$view"; then
		fail "LuCI webhook pseudo field never reads or writes browser-readable UCI"
	else
		pass "LuCI webhook pseudo field never reads or writes browser-readable UCI"
	fi
	if grep -q -- '--status-json' "$rpcd"; then
		fail "rpcd status never spawns status-json"
	else
		pass "rpcd status never spawns status-json"
	fi
	if grep -Eq 'qmodem|get_connect_status|base_info|cell_info|network\.interface' "$rpcd"; then
		fail "rpcd status never calls qmodem or network ubus"
	else
		pass "rpcd status never calls qmodem or network ubus"
	fi
	grep -q 'modem_status_path' "$config" && pass "shipped config exposes modem status cache path" || fail "shipped config exposes modem status cache path"
	if grep -q 'ubus_timeout' "$config"; then
		fail "shipped config contains no legacy status timeout"
	else
		pass "shipped config contains no legacy status timeout"
	fi
	grep -q 'set_webhook' "$rpcd" && pass "rpcd exposes custom set_webhook" || fail "rpcd exposes custom set_webhook"
	if grep -q 'feishu_webhook' "$config"; then
		fail "shipped config has no browser-readable webhook option"
	else
		pass "shipped config has no browser-readable webhook option"
	fi

	setup_case status_json_allowlist
	export TEST_FIXTURE="$ROOT/tests/fixtures/json_content.json"
	export SMSFF_ATTACH_STATUS=1
	export TEST_BASE_INFO='{"temperature":"45","IMEI":"867530900000000","ICCID":"89860000000000000000"}'
	export TEST_CELL_INFO='{"network_mode":"NR5G","RSRP":"-88","RSRQ":"-11","SINR":"19","Physical Cell ID":"321","ARFCN":"633984","IMSI":"460001234567890"}'
	status="$(run_forwarder --status-json)"
	keys="$(printf '%s' "$status" | jq -r 'keys | sort | join(",")')"
	assert_eq "status-json only emits allowlisted modem keys" "$keys" "arfcn,network_mode,online,online_devices,pci,rsrp,rsrq,sinr,temperature,uptime,wan"
	if printf '%s' "$status" | jq -r '.. | strings' | grep -E '867530900000000|89860000000000000000|460001234567890|open-apis/bot'; then
		fail "status-json excludes identity and webhook"
	else
		pass "status-json excludes identity and webhook"
	fi
}

test_production_uses_only_mt5700m_plugin_transport()
{
	local forwarder="$ROOT/files/usr/bin/sms-feishu-forwarder"
	local scheduler="$ROOT/files/usr/bin/sms-feishu-scheduler"
	local config="$ROOT/files/etc/config/sms-feishu-forwarder"
	local default_config="$ROOT/packaging/ipk/default-config"
	local package_files="$ROOT/packaging/build-apk.py $ROOT/packaging/build-ipk.sh"
	local runtime_files="$forwarder $scheduler $config $default_config $ROOT/files/www/luci-static/resources/view/sms-feishu-forwarder.js"

	grep -q '/usr/sbin/mt5700m-read' "$forwarder" && grep -q 'sms-list' "$forwarder" &&
		pass "forwarder receives SMS through mt5700m-read" || fail "forwarder receives SMS through mt5700m-read"
	grep -q '/usr/sbin/mt5700m-at' "$scheduler" && grep -q 'sms-send-start' "$scheduler" && grep -q 'sms-send-status' "$scheduler" &&
		pass "scheduler submits and observes SMS through mt5700m plugin jobs" || fail "scheduler submits and observes SMS through mt5700m plugin jobs"
	if grep -Eiq 'qmodem|qmodem_sms|ubus-at-daemon|at-daemon|sms_tool|sms-tool|/dev/tty|modemwebui' $runtime_files $package_files; then
		fail "production runtime and package metadata contain no legacy modem transport"
	else
		pass "production runtime and package metadata contain no legacy modem transport"
	fi
	grep -q 'luci-app-mt5700m' $package_files && pass "packages depend on luci-app-mt5700m" || fail "packages depend on luci-app-mt5700m"
}

test_release_gate_documents_current_mt5700m_live_contract()
{
	local gate="$ROOT/packaging/release-gate.sh"
	local release_doc="$ROOT/packaging/RELEASE.md"
	[ -x "$gate" ] && pass "release gate is executable" || fail "release gate is executable"
	if sh "$gate" >/dev/null 2>&1; then
		pass "release gate accepts current MT5700M-only source contract"
	else
		fail "release gate accepts current MT5700M-only source contract"
	fi
	grep -q 'MT5700M v3\.0\.3' "$release_doc" &&
		grep -q '/usr/sbin/mt5700m-read.*sms-list' "$release_doc" &&
		grep -q '/usr/sbin/mt5700m-at.*sms-send-start' "$release_doc" &&
		grep -q '/usr/sbin/mt5700m-read.*sms-send-status' "$release_doc" &&
		pass "release gate documents live helper version and commands" || fail "release gate documents live helper version and commands"
	if grep -Eq 'research[^[:space:]]*[[:space:]]+(is[[:space:]]+)?authoritative|authoritative[^[:space:]]*[[:space:]]+research' "$gate"; then
		fail "release gate does not trust stale research snapshot"
	else
		pass "release gate does not trust stale research snapshot"
	fi
}

test_scheduler_uses_mt5700m_async_job_and_fails_closed()
{
	setup_case scheduler_mt5700m_job
	export SMSFF_NOW_SLOT="2026-09-23-18-30"
	export SMSFF_NOW_WEEKDAY=3
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance=schedule
sms-feishu-forwarder.balance.enabled='1'
sms-feishu-forwarder.balance.recipient='10086'
sms-feishu-forwarder.balance.content='CXLL'
sms-feishu-forwarder.balance.hour='18'
sms-feishu-forwarder.balance.minute='30'
sms-feishu-forwarder.balance.weekdays='3'"
	run_scheduler --once
	grep -qx 'sms-send-start 10086 CXLL' "$TEST_MT5700M_LOG" && pass "scheduler starts one native MT5700M SMS job" || fail "scheduler starts one native MT5700M SMS job"
	assert_file_content "native job success is persisted" "$SMSFF_SCHEDULE_STATE_DIR/balance.result" "ok"

	setup_case scheduler_mt5700m_job_failed
	export SMSFF_NOW_SLOT="2026-09-23-18-30"
	export SMSFF_NOW_WEEKDAY=3
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export TEST_MT5700M_JOB_CODE=124
	export TEST_UCI_SHOW="sms-feishu-forwarder.balance=schedule
sms-feishu-forwarder.balance.enabled='1'
sms-feishu-forwarder.balance.recipient='10086'
sms-feishu-forwarder.balance.content='CXLL'
sms-feishu-forwarder.balance.hour='18'
sms-feishu-forwarder.balance.minute='30'
sms-feishu-forwarder.balance.weekdays='3'"
	if run_scheduler --once; then
		fail "scheduler rejects an unconfirmed native SMS job"
	else
		pass "scheduler rejects an unconfirmed native SMS job"
	fi
	assert_file_content "native job failure is persisted" "$SMSFF_SCHEDULE_STATE_DIR/balance.result" "failed"
}

test_mt5700m_failed_webhook_retries_without_replaying_success()
{
	setup_case mt5700m_webhook_retry
	export TEST_MT5700M_FIXTURE="$ROOT/tests/fixtures/mt5700m_gsm7.txt"
	export SMSFF_MT5700M_DECODER="$ROOT/files/usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk"
	export CURL_BODY='{"code":19001}'
	if run_forwarder --once; then
		fail "failed Feishu response keeps MT5700M SMS pending"
	else
		pass "failed Feishu response keeps MT5700M SMS pending"
	fi
	assert_file_lines "failed webhook does not persist seen key" "$SMSFF_STATE_PATH" 0
	export CURL_BODY='{"code":0}'
	run_forwarder --once
	assert_file_lines "pending MT5700M SMS retries once" "$TEST_BODIES" 2
	assert_file_lines "successful retry persists one seen key" "$SMSFF_STATE_PATH" 1
	run_forwarder --once
	assert_file_lines "persisted MT5700M SMS is not replayed" "$TEST_BODIES" 2
}

test_busybox_awk_decodes_mt5700m_gsm7()
{
	local pdu out
	out="$TMP_ROOT/busybox-awk-decoder"
	mkdir -p "$out"
	pdu="$(awk '/^\+CMGL:/ { seen = 1; next } seen && /^[0-9A-F]+$/ { print; exit }' "$ROOT/tests/fixtures/mt5700m_gsm7.txt")"
	if busybox awk -v pdu="$pdu" -v out="$out" -f "$ROOT/files/usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk" </dev/null; then
		assert_file_content "BusyBox awk decodes GSM7 without optional libm" "$out/content" "MT5700M GSM7"
	else
		fail "BusyBox awk decodes GSM7 without optional libm"
	fi
}

test_source_installer_manages_pdu_decoder()
{
	local root
	root="$TMP_ROOT/source-install-decoder"
	mkdir -p "$root"
	ROOT="$root" sh "$ROOT/install.sh" >/dev/null
	[ -f "$root/usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk" ] && pass "source installer installs PDU decoder" || fail "source installer installs PDU decoder"
	grep -q 'usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk' "$ROOT/uninstall.sh" && pass "source uninstaller manages PDU decoder" || fail "source uninstaller manages PDU decoder"
	[ -f "$root/usr/lib/sms-feishu-forwarder/quota.sh" ] && pass "source installer installs quota helper" || fail "source installer installs quota helper"
	grep -q 'usr/lib/sms-feishu-forwarder/quota.sh' "$ROOT/uninstall.sh" && pass "source uninstaller manages quota helper" || fail "source uninstaller manages quota helper"
}

test_all_install_paths_ship_prestart_legacy_cutover()
{
	local helper init apk_builder ipk_builder
	helper="$ROOT/files/usr/lib/sms-feishu-forwarder/mt5700m-cutover"
	init="$ROOT/files/etc/init.d/sms-feishu-forwarder"
	apk_builder="$ROOT/packaging/build-apk.py"
	ipk_builder="$ROOT/packaging/build-ipk.sh"
	[ -x "$helper" ] && pass "legacy cutover helper exists" || fail "legacy cutover helper exists"
	grep -q '/usr/lib/sms-feishu-forwarder/mt5700m-cutover' "$init" && pass "service runs cutover before procd instances" || fail "service runs cutover before procd instances"
	grep -q 'mt5700m-cutover' "$apk_builder" && grep -q 'mt5700m-cutover' "$ipk_builder" && pass "APK and IPK ship legacy cutover helper" || fail "APK and IPK ship legacy cutover helper"
	grep -q 'mt5700m-cutover' "$ROOT/install.sh" && grep -q 'mt5700m-cutover' "$ROOT/uninstall.sh" && pass "source installer manages legacy cutover helper" || fail "source installer manages legacy cutover helper"
}

test_legacy_cutover_disables_competing_serial_services_and_task()
{
	local device_root helper service
	device_root="$TMP_ROOT/legacy-cutover"
	helper="$ROOT/files/usr/lib/sms-feishu-forwarder/mt5700m-cutover"
	mkdir -p "$device_root/usr/sbin" "$device_root/etc/init.d" "$device_root/etc/config" "$device_root/tmp"
	for service in mt5700m-at mt5700m-read mt5700m-manager; do
		printf '#!/bin/sh\nexit 0\n' > "$device_root/usr/sbin/$service"
		chmod 755 "$device_root/usr/sbin/$service"
	done
	for service in smsforward sms_forwarder ubus-at-daemon taskplan; do
		cat > "$device_root/etc/init.d/$service" <<'EOS'
#!/bin/sh
name="${0##*/}"
printf '%s\n' "$1" >> "$ROOT/tmp/$name.log"
case "$1" in enabled|running|stop|disable|restart) exit 0 ;; *) exit 1 ;; esac
EOS
		chmod 755 "$device_root/etc/init.d/$service"
	done
	cat > "$device_root/etc/config/taskplan" <<'EOS'
config global 'global'
	option customscript '/root/send_10086_sms.sh'
config task 'legacy'
	option stype '12'
	option enable '1'
config task 'other'
	option stype '1'
	option enable '1'
EOS
	ROOT="$device_root" busybox ash "$helper"
	grep -qx stop "$device_root/tmp/ubus-at-daemon.log" && grep -qx disable "$device_root/tmp/ubus-at-daemon.log" && pass "cutover disables competing AT broker" || fail "cutover disables competing AT broker"
	[ "$(sed -n "/config task 'legacy'/,/^config /s/^[[:space:]]*option enable '\([^']*\)'.*/\1/p" "$device_root/etc/config/taskplan")" = "0" ] && pass "cutover disables legacy scheduled sender" || fail "cutover disables legacy scheduled sender"
	[ -f "$device_root/etc/sms-feishu-forwarder/mt5700m-cutover.complete" ] && pass "cutover records idempotent completion" || fail "cutover records idempotent completion"
}

test_quota_history_fixed_point_helpers()
{
	setup_case quota_history_fixed_point
	local history helper output
	history="$CASE_DIR/traffic-history"
	helper="$ROOT/files/usr/lib/sms-feishu-forwarder/quota.sh"
	cat > "$history" <<'EOF'
version 1
month eth2 2026-08 999 999
month eth2 2026-09 1200000000 3400000000
month eth2 2026-09 bad 500
month wlan0 2026-09 9000000000 9000000000
EOF
	if output="$(SMSFF_TRAFFIC_HISTORY_PATH="$history" SMSFF_NOW_MONTH=2026-09 \
		busybox ash -c '. "$1"; quota_read_current_counters | tr -d "\\n"; printf "|"; quota_bytes_to_centi_gb 1234567890 | tr -d "\\n"; printf "|"; quota_format_centi 1234' sh "$helper")"; then
		pass "quota helper reads current MT5700M month history"
	else
		fail "quota helper reads current MT5700M month history"
		output=""
	fi
	assert_eq "quota helper keeps valid RX/TX counters and fixed-point GB" "$output" "2026-09|1200000000|3400000000|123|12.34GB"
}

test_scheduler_quota_claims_fixed_query_once_per_interval()
{
	setup_case scheduler_quota_claim
	local gets
	gets="$CASE_DIR/uci-gets"
	printf '%s	%s\n' 'sms-feishu-forwarder.settings.quota_calibration' '7' > "$gets"
	export TEST_UCI_GETS="$gets"
	export SMSFF_NOW_SLOT="2026-09-24-10-00"
	export SMSFF_NOW_EPOCH=1780221600
	export SMSFF_NOW_MESSAGE_TS=20260924100000
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export SMSFF_QUOTA_STATE_PATH="$CASE_DIR/quota-state.json"
	export SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/quota-status.json"
	export TEST_UCI_SHOW="sms-feishu-forwarder.traffic_hourly=schedule
sms-feishu-forwarder.traffic_hourly.enabled='1'
sms-feishu-forwarder.traffic_hourly.name='traffic_hourly'
sms-feishu-forwarder.traffic_hourly.recipient='+8610086'
sms-feishu-forwarder.traffic_hourly.content='CXLL'
sms-feishu-forwarder.traffic_hourly.hour='10'
sms-feishu-forwarder.traffic_hourly.minute='0'
sms-feishu-forwarder.traffic_hourly.weekdays='*'"
	run_scheduler --once
	run_scheduler --once
	assert_file_lines "quota interval makes one native attempt" "$TEST_MT5700M_LOG" 1
	assert_eq "quota attempt is fixed 10086 CXLL" "$(cat "$TEST_MT5700M_LOG")" "sms-send-start 10086 CXLL"
	assert_eq "quota success is persisted" "$(jq -r .result "$SMSFF_QUOTA_STATE_PATH")" "ok"
	assert_eq "quota next due is one seven-day interval later" "$(jq -r .next_due_epoch "$SMSFF_QUOTA_STATE_PATH")" "1780826400"
	assert_file_lines "generic 10086 CXLL is suppressed while quota owns interval" "$TEST_SMS_TOOL_LOG" 0
}

test_scheduler_quota_failure_is_not_retried_until_next_interval()
{
	setup_case scheduler_quota_failure
	local gets
	gets="$CASE_DIR/uci-gets"
	printf '%s	%s\n' 'sms-feishu-forwarder.settings.quota_calibration' '14' > "$gets"
	export TEST_UCI_GETS="$gets"
	export SMSFF_NOW_SLOT="2026-09-24-10-00"
	export SMSFF_NOW_EPOCH=1780221600
	export SMSFF_NOW_MESSAGE_TS=20260924100000
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export SMSFF_QUOTA_STATE_PATH="$CASE_DIR/quota-state.json"
	export SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/quota-status.json"
	export TEST_MT5700M_JOB_CODE=124
	if run_scheduler --once; then
		fail "quota async failure returns failure"
	else
		pass "quota async failure returns failure"
	fi
	run_scheduler --once || true
	assert_file_lines "quota failure is not retried in same interval" "$TEST_MT5700M_LOG" 1
	assert_eq "quota failure result is persisted" "$(jq -r .result "$SMSFF_QUOTA_STATE_PATH")" "failed"
}

test_scheduler_suppresses_manual_fixed_query_when_quota_owns_interval()
{
	setup_case scheduler_quota_manual_suppression
	local gets
	gets="$CASE_DIR/uci-gets"
	printf '%s	%s\n' 'sms-feishu-forwarder.settings.quota_calibration' '7' > "$gets"
	export TEST_UCI_GETS="$gets"
	export SMSFF_NOW_SLOT="2026-09-24-10-00"
	export SMSFF_NOW_EPOCH=1780221600
	export SMSFF_NOW_WEEKDAY=4
	export SMSFF_SCHEDULE_STATE_DIR="$CASE_DIR/schedule-state"
	export SMSFF_QUOTA_STATE_PATH="$CASE_DIR/quota-state.json"
	export SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/quota-status.json"
	export TEST_UCI_SHOW="sms-feishu-forwarder.manual_query=schedule
sms-feishu-forwarder.manual_query.enabled='1'
sms-feishu-forwarder.manual_query.name='manual_query'
sms-feishu-forwarder.manual_query.recipient='10086'
sms-feishu-forwarder.manual_query.content='CXLL'
sms-feishu-forwarder.manual_query.hour='10'
sms-feishu-forwarder.manual_query.minute='0'
sms-feishu-forwarder.manual_query.weekdays='*'"
	if run_scheduler --send manual_query; then
		fail "manual fixed query is suppressed while quota owns interval"
	else
		pass "manual fixed query is suppressed while quota owns interval"
	fi
	assert_file_lines "suppressed manual query does not call modem" "$TEST_MT5700M_LOG" 0
	assert_file_content "suppressed manual query records suppression" "$SMSFF_SCHEDULE_STATE_DIR/manual_query.result" "suppressed"
}

test_forwarder_applies_quota_reply_once_after_successful_send()
{
	setup_case forwarder_quota_reply
	local decoder history state
	decoder="$CASE_DIR/quota-decoder.awk"
	history="$CASE_DIR/traffic-history"
	state="$CASE_DIR/quota-state.json"
	cat > "$decoder" <<'EOF'
BEGIN {
	printf "%s", "+" > out "/sender"
	printf "%s", "8610086" >> out "/sender"
	print "20260924103000" > out "/timestamp"
	print "2026-09-24 10:30:00" > out "/display_time"
	print "" > out "/concat_ref"
	print "1" > out "/concat_total"
	print "1" > out "/concat_seq"
	printf "%s", "本月国内通用流量共100GB,剩余12.34GB" > out "/content"
	exit 0
}
EOF
	printf '%s\n' 'month eth2 2026-09 3000000000 4000000000' > "$history"
	printf '%s\n' '{"interval":"7","result":"ok","last_success_stamp":"20260924100000","last_success_epoch":1780221600,"next_due_epoch":1780826400,"month":"2026-09","base_rx":"1000000000","base_tx":"2000000000"}' > "$state"
	export SMSFF_QUOTA_CALIBRATION=7
	export SMSFF_QUOTA_STATE_PATH="$state"
	export SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/quota-status.json"
	export SMSFF_TRAFFIC_HISTORY_PATH="$history"
	export SMSFF_NOW_MONTH=2026-09
	export SMSFF_NOW_MESSAGE_TS=20260924110000
	export SMSFF_MT5700M_DECODER="$decoder"
	export TEST_MT5700M_FIXTURE="$CASE_DIR/quota-reply.txt"
	export TEST_FIXTURE="$TEST_MT5700M_FIXTURE"
	cat > "$TEST_FIXTURE" <<'EOF'
MT5700M SMS list
+CMGL: 1,0,,2
AA
OK
EOF
	run_forwarder --once
	assert_eq "quota reply stores carrier remaining in fixed point" "$(jq -r .carrier_centi "$state")" "1234"
	assert_eq "quota reply stores carrier monthly total in fixed point" "$(jq -r .carrier_total_centi "$state")" "10000"
	assert_eq "quota calibration keeps modem reply timestamp" "$(jq -r .last_calibration_stamp "$state")" "20260924103000"
	assert_eq "quota reply stores calibration sender key but no body" "$(jq -r 'has("reply_key") and (has("content") | not)' "$state")" "true"
	assert_file_lines "quota reply is marked seen after calibration" "$SMSFF_STATE_PATH" 1
	assert_eq "quota reply sends one Feishu card" "$(wc -l < "$TEST_BODIES")" "1"
	printf '%s\n' 'month eth2 2026-09 4000000000 5000000000' > "$history"
	run_forwarder --once
	assert_eq "local usage remains full current-month traffic" "$(jq -r .local_usage "$SMSFF_QUOTA_STATUS_PATH")" "9.00GB"
	assert_eq "estimated remaining subtracts local delta" "$(jq -r .estimated_remaining "$SMSFF_QUOTA_STATUS_PATH")" "10.34GB"
	assert_eq "duplicate quota reply is not forwarded again" "$(wc -l < "$TEST_BODIES")" "1"
	jq 'del(.carrier_centi,.reply_key,.last_calibration_stamp,.month,.base_rx,.base_tx)' "$state" > "$CASE_DIR/quota-state-reset.json"
	mv "$CASE_DIR/quota-state-reset.json" "$state"
	run_forwarder --quota-reconcile
	assert_eq "quota reconcile reapplies a previously seen valid reply" "$(jq -r .carrier_centi "$state")" "1234"
	assert_eq "quota reconcile does not resend a Feishu card" "$(wc -l < "$TEST_BODIES")" "1"
	if grep -R -F '本月国内通用流量共100GB' "$state" "$SMSFF_QUOTA_STATUS_PATH" "$TEST_LOGGER" 2>/dev/null; then
		fail "quota state and logs do not persist raw reply body"
	else
		pass "quota state and logs do not persist raw reply body"
	fi
}

test_forwarder_rejects_quota_reply_without_latest_success()
{
	setup_case forwarder_quota_reply_gate
	local decoder history state
	decoder="$CASE_DIR/quota-decoder.awk"
	history="$CASE_DIR/traffic-history"
	state="$CASE_DIR/quota-state.json"
	cat > "$decoder" <<'EOF'
BEGIN {
	printf "%s", "+" > out "/sender"
	printf "%s", "8610086" >> out "/sender"
	print "20260924103000" > out "/timestamp"
	print "2026-09-24 10:30:00" > out "/display_time"
	print "" > out "/concat_ref"
	print "1" > out "/concat_total"
	print "1" > out "/concat_seq"
	printf "%s", "本月国内通用流量共100GB,剩余12.34GB" > out "/content"
	exit 0
}
EOF
	printf '%s\n' 'month eth2 2026-09 3000000000 4000000000' > "$history"
	printf '%s\n' '{"interval":"7","result":"failed","last_success_stamp":"20260924110000","last_success_epoch":1780225200,"next_due_epoch":1780826400}' > "$state"
	export SMSFF_QUOTA_CALIBRATION=7
	export SMSFF_QUOTA_STATE_PATH="$state"
	export SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/quota-status.json"
	export SMSFF_TRAFFIC_HISTORY_PATH="$history"
	export SMSFF_NOW_MONTH=2026-09
	export SMSFF_MT5700M_DECODER="$decoder"
	export TEST_MT5700M_FIXTURE="$CASE_DIR/quota-reply.txt"
	cat > "$TEST_MT5700M_FIXTURE" <<'EOF'
MT5700M SMS list
+CMGL: 1,0,,2
AA
OK
EOF
	run_forwarder --once
	assert_eq "reply before latest successful quota send is not calibrated" "$(jq -r 'has("carrier_centi")' "$state")" "false"
}

test_quota_status_marks_counter_decrease_unknown_and_rollover_stale()
{
	setup_case quota_status_edges
	local helper history state status
	helper="$ROOT/files/usr/lib/sms-feishu-forwarder/quota.sh"
	history="$CASE_DIR/traffic-history"
	state="$CASE_DIR/quota-state.json"
	printf '%s\n' '{"interval":"7","result":"ok","carrier_total_centi":10000,"carrier_centi":1234,"last_calibration_stamp":"20260924100000","month":"2026-09","base_rx":"3000000000","base_tx":"4000000000","next_due_epoch":1780826400}' > "$state"
	printf '%s\n' 'month eth2 2026-09 2000000000 5000000000' > "$history"
	status="$(SMSFF_QUOTA_STATE_PATH="$state" SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/status.json" SMSFF_TRAFFIC_HISTORY_PATH="$history" SMSFF_NOW_MONTH=2026-09 \
		busybox ash -c '. "$1"; quota_refresh_status 7; cat "$2"' sh "$helper" "$CASE_DIR/status.json")"
	assert_eq "same-month counter decrease is unknown" "$(printf '%s' "$status" | jq -r .status)" "unknown"
	assert_eq "counter decrease hides local usage" "$(printf '%s' "$status" | jq -r .local_usage)" "未知"

	printf '%s\n' 'month eth2 2026-10 2000000000 5000000000' > "$history"
	status="$(SMSFF_QUOTA_STATE_PATH="$state" SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/status.json" SMSFF_TRAFFIC_HISTORY_PATH="$history" SMSFF_NOW_MONTH=2026-10 \
		busybox ash -c '. "$1"; quota_refresh_status 7; cat "$2"' sh "$helper" "$CASE_DIR/status.json")"
	assert_eq "month rollover marks calibrated status stale" "$(printf '%s' "$status" | jq -r .status)" "stale"
	assert_eq "rollover hides estimate but preserves carrier calibration" "$(printf '%s' "$status" | jq -r '.estimated_remaining + ":" + .calibrated_remaining')" "未知:12.34GB"
	assert_eq "rollover preserves carrier monthly total" "$(printf '%s' "$status" | jq -r .carrier_total)" "100.00GB"
	assert_eq "quota status cache is an allowlisted object" "$(printf '%s' "$status" | jq -r 'keys | sort | join(",")')" "calibrated_remaining,carrier_total,estimated_remaining,interval,last_calibration,local_usage,next_due,status"
	assert_eq "quota status cache mode is 0600" "$(stat -c '%a' "$CASE_DIR/status.json" 2>/dev/null || stat -f '%Lp' "$CASE_DIR/status.json")" "600"
}

test_quota_status_always_shows_full_local_month_usage()
{
	setup_case quota_local_month_usage
	local helper history state status
	helper="$ROOT/files/usr/lib/sms-feishu-forwarder/quota.sh"
	history="$CASE_DIR/traffic-history"
	state="$CASE_DIR/quota-state.json"
	printf '%s\n' 'month eth2 2026-09 4000000000 5000000000' > "$history"
	printf '%s\n' '{}' > "$state"
	status="$(SMSFF_QUOTA_STATE_PATH="$state" SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/status.json" SMSFF_TRAFFIC_HISTORY_PATH="$history" SMSFF_NOW_MONTH=2026-09 \
		busybox ash -c '. "$1"; quota_refresh_status off; cat "$2"' sh "$helper" "$CASE_DIR/status.json")"
	assert_eq "quota off still shows full current-month local traffic" "$(printf '%s' "$status" | jq -r .local_usage)" "9.00GB"

	printf '%s\n' '{"interval":"7","result":"ok","carrier_total_centi":10000,"carrier_centi":1234,"last_calibration_stamp":"20260924100000","month":"2026-09","base_rx":"3000000000","base_tx":"4000000000","next_due_epoch":1780826400}' > "$state"
	status="$(SMSFF_QUOTA_STATE_PATH="$state" SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/status.json" SMSFF_TRAFFIC_HISTORY_PATH="$history" SMSFF_NOW_MONTH=2026-09 \
		busybox ash -c '. "$1"; quota_refresh_status 7; cat "$2"' sh "$helper" "$CASE_DIR/status.json")"
	assert_eq "calibrated quota keeps local traffic as full month total" "$(printf '%s' "$status" | jq -r .local_usage)" "9.00GB"
	assert_eq "calibrated quota exposes carrier monthly total" "$(printf '%s' "$status" | jq -r .carrier_total)" "100.00GB"
	assert_eq "remaining estimate still subtracts only post-calibration delta" "$(printf '%s' "$status" | jq -r .estimated_remaining)" "10.34GB"
}

test_quota_config_rpc_ui_and_package_contract()
{
	local config="$ROOT/files/etc/config/sms-feishu-forwarder"
	local default_config="$ROOT/packaging/ipk/default-config"
	local rpcd="$ROOT/files/usr/share/rpcd/ucode/sms-feishu-forwarder.uc"
	local view="$ROOT/files/www/luci-static/resources/view/sms-feishu-forwarder.js"
	local apk_builder="$ROOT/packaging/build-apk.py"
	local ipk_builder="$ROOT/packaging/build-ipk.sh"
	local apk_test="$ROOT/packaging/test-apk.py"
	local ipk_test="$ROOT/packaging/test-ipk.sh"

	grep -q "option quota_calibration 'off'" "$config" && grep -q "option quota_calibration 'off'" "$default_config" &&
		pass "fresh and upgrade defaults disable quota calibration" || fail "fresh and upgrade defaults disable quota calibration"
	grep -q "option quota_state_path '/var/lib/sms-feishu-forwarder/quota-state.json'" "$config" &&
		grep -q "option quota_status_path '/var/lib/sms-feishu-forwarder/quota-status.json'" "$config" &&
		pass "UCI defaults expose quota state and status paths" || fail "UCI defaults expose quota state and status paths"
	grep -q 'quota_state_path.*\/var\/lib\/sms-feishu-forwarder\/quota-state.json' "$ROOT/files/usr/bin/sms-feishu-scheduler" &&
		grep -q 'quota_status_path.*\/var\/lib\/sms-feishu-forwarder\/quota-status.json' "$ROOT/files/usr/bin/sms-feishu-scheduler" &&
		pass "scheduler upgrade fallback shares forwarder quota paths" || fail "scheduler upgrade fallback shares forwarder quota paths"
	grep -q "quota_status_path" "$rpcd" && grep -q "quota_calibration" "$rpcd" && grep -q "carrier_total" "$rpcd" &&
		pass "RPC exposes allowlisted quota status" || fail "RPC exposes allowlisted quota status"
	for label in '校准周期' '本地月用量' '本月通用总量' '校准剩余' '估算剩余' '上次校准' '下次到期'; do
		grep -q "$label" "$view" || { fail "LuCI renders quota field $label"; return; }
	done
	pass "LuCI renders quota interval usage remaining and due fields"
	grep -q 'usr/lib/sms-feishu-forwarder/quota.sh' "$apk_builder" &&
		grep -q 'usr/lib/sms-feishu-forwarder/quota.sh' "$ipk_builder" &&
		pass "APK and IPK include quota helper" || fail "APK and IPK include quota helper"
	grep -q 'RELEASE.*24\|r24\|1.0.0-24' "$apk_builder" "$ipk_builder" "$apk_test" "$ipk_test" &&
		pass "package metadata and tests target r24" || fail "package metadata and tests target r24"
}

test_quota_sender_normalization_is_exact()
{
	local helper="$ROOT/files/usr/lib/sms-feishu-forwarder/quota.sh"
	grep -q '10086|+8610086)' "$helper" && pass "quota sender matcher uses exact normalized forms" || fail "quota sender matcher uses exact normalized forms"
	if busybox ash -c '. "$1"; quota_sender_is_10086 +8610086' sh "$helper"; then
		pass "quota accepts normalized international 10086"
	else
		fail "quota accepts normalized international 10086"
	fi
	if busybox ash -c '. "$1"; quota_sender_is_10086 +86199986' sh "$helper"; then
		fail "quota rejects other +8 sender ending in 86"
	else
		pass "quota rejects other +8 sender ending in 86"
	fi
	if busybox ash -c '. "$1"; quota_sender_is_10086 +8123486' sh "$helper"; then
		fail "quota rejects non-10086 international sender"
	else
		pass "quota rejects non-10086 international sender"
	fi
}

test_quota_reply_parser_is_strict_bounded_and_contract_safe()
{
	local helper="$ROOT/files/usr/lib/sms-feishu-forwarder/quota.sh"
	local valid observed huge body
	valid='本月国内通用流量共100GB,剩余12.34GB'
	observed='【温馨提醒】尊敬的客户,您好!【流量查询】您好!截至9月24日13时8分,您本月国内通用流量共100GB,剩余12.34GB。所有流量资源使用详情,点击 http://dx.10086.cn/-N0K 查询。 点击 https://dx.10086.cn/A/tAahGg 签到享好礼!流量话费等你来领,签满7次还可抽100元话费!【中国移动】'
	huge='本月国内通用流量共100GB,剩余99999999999999999999999999999999999999999999999999GB'

	assert_eq "quota parser accepts exact carrier sentence" \
		"$(busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 "$valid")" "1234"
	assert_eq "quota parser accepts observed carrier continuation contract" \
		"$(busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 "$observed")" "1234"
	assert_eq "quota scheduler stamp follows modem UTC+8 wall clock" \
		"$(SMSFF_NOW_EPOCH=0 SMSFF_MODEM_TIME_OFFSET=28800 busybox ash -c '. "$1"; quota_message_stamp_now' sh "$helper")" "19700101080000"
	assert_eq "quota next-due display follows modem UTC+8 wall clock" \
		"$(TZ=UTC SMSFF_MODEM_TIME_OFFSET=28800 busybox ash -c '. "$1"; quota_epoch_display 0' sh "$helper")" "1970-01-01 08:00:00"

	if busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 "$valid
unrelated"; then
		fail "quota parser rejects multiline injection"
	else
		pass "quota parser rejects multiline injection"
	fi
	if busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 "prefix $valid"; then
		fail "quota parser rejects unrelated prefix"
	else
		pass "quota parser rejects unrelated prefix"
	fi
	if busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 "$valid
$valid"; then
		fail "quota parser rejects duplicate carrier sentences"
	else
		pass "quota parser rejects duplicate carrier sentences"
	fi
	if busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 '本月国内通用流量共100GB,剩余101GB'; then
		fail "quota parser rejects remaining over fixed 100GB total"
	else
		pass "quota parser rejects remaining over fixed 100GB total"
	fi
	if busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 '本月国内通用流量共100GB,剩余100.01GB'; then
		fail "quota parser rejects remaining greater than total"
	else
		pass "quota parser rejects remaining greater than total"
	fi
	if busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 "$huge"; then
		fail "quota parser rejects 50-digit decimal overflow"
	else
		pass "quota parser rejects 50-digit decimal overflow"
	fi
	if busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 '本月国内通用流量共100GB,剩余12.345GB'; then
		fail "quota parser rejects excess fractional digits"
	else
		pass "quota parser rejects excess fractional digits"
	fi
	if busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 '本月国内通用流量共100GB,剩余12.GB'; then
		fail "quota parser rejects malformed decimal"
	else
		pass "quota parser rejects malformed decimal"
	fi
	if busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 '本月国内通用流量共100GB,剩余.5GB'; then
		fail "quota parser rejects missing integer"
	else
		pass "quota parser rejects missing integer"
	fi
	body="$(printf 'x%.0s' $(seq 1 3000))"
	if busybox ash -c '. "$1"; quota_parse_reply_remaining "$2" "$3"' sh "$helper" 10086 "${valid}${body}"; then
		fail "quota parser bounds whole body length"
	else
		pass "quota parser bounds whole body length"
	fi
}

test_quota_fixed_point_math_avoids_large_counter_float_rounding()
{
	local helper="$ROOT/files/usr/lib/sms-feishu-forwarder/quota.sh"
	local output
	output="$(busybox ash -c '. "$1"; printf "%s|" "$(quota_add_decimal 9007199254740992 1)"; printf "%s|" "$(quota_sub_decimal 9007199254740993 1)"; printf "%s|" "$(quota_sub_decimal 9007199254740992 9007199254740993)"; quota_bytes_to_centi_gb 90071992547409930000000' sh "$helper")"
	assert_eq "fixed-point add/subtract preserve large counters" "$output" "9007199254740993|9007199254740992|-1|9007199254740993"
}

test_forwarder_rejects_quota_reply_at_success_stamp()
{
	setup_case forwarder_quota_equal_gate
	local decoder history state
	decoder="$CASE_DIR/quota-decoder.awk"
	history="$CASE_DIR/traffic-history"
	state="$CASE_DIR/quota-state.json"
	cat > "$decoder" <<'EOF'
BEGIN {
	printf "%s", "+" > out "/sender"
	printf "%s", "8610086" >> out "/sender"
	print "20260924103000" > out "/timestamp"
	print "2026-09-24 10:30:00" > out "/display_time"
	print "" > out "/concat_ref"
	print "1" > out "/concat_total"
	print "1" > out "/concat_seq"
	printf "%s", "本月国内通用流量共100GB,剩余12.34GB" > out "/content"
	exit 0
}
EOF
	printf '%s\n' 'month eth2 2026-09 3000000000 4000000000' > "$history"
	printf '%s\n' '{"interval":"7","result":"ok","last_success_stamp":"20260924103000","last_success_epoch":1780223400,"next_due_epoch":1780826400}' > "$state"
	export SMSFF_QUOTA_CALIBRATION=7
	export SMSFF_QUOTA_STATE_PATH="$state"
	export SMSFF_QUOTA_STATUS_PATH="$CASE_DIR/quota-status.json"
	export SMSFF_TRAFFIC_HISTORY_PATH="$history"
	export SMSFF_NOW_MONTH=2026-09
	export SMSFF_MT5700M_DECODER="$decoder"
	export TEST_MT5700M_FIXTURE="$CASE_DIR/quota-reply.txt"
	cat > "$TEST_MT5700M_FIXTURE" <<'EOF'
MT5700M SMS list
+CMGL: 1,0,,2
AA
OK
EOF
	run_forwarder --once
	assert_eq "reply at successful send stamp is not calibrated" "$(jq -r 'has("carrier_centi")' "$state")" "false"
}

test_mt5700m_multipart_requires_exact_unique_sequence_set()
{
	setup_case mt5700m_exact_sequences
	local decoder
	decoder="$CASE_DIR/exact-sequence-decoder.awk"
	cat > "$decoder" <<'EOF'
BEGIN {
	ref="8:7"; total=2
	if (pdu == "A1") { seq=1; content="first"; stamp="20260924100000" }
	else if (pdu == "A1D") { seq=1; content="duplicate"; stamp="20260924100001" }
	else if (pdu == "A2") { seq=2; content="second"; stamp="20260924100002" }
	else exit 1
	print "+15550000001" > out "/sender"
	print stamp > out "/timestamp"
	print "2026-09-24 10:00:00" > out "/display_time"
	print ref > out "/concat_ref"
	print total > out "/concat_total"
	print seq > out "/concat_seq"
	printf "%s", content > out "/content"
	exit 0
}
EOF
	export SMSFF_MT5700M_DECODER="$decoder"
	export TEST_MT5700M_FIXTURE="$CASE_DIR/exact-sequences.txt"
	cat > "$TEST_MT5700M_FIXTURE" <<'EOF'
MT5700M SMS list
+CMGL: 1,0,,2
A1
+CMGL: 2,0,,2
A1D
+CMGL: 3,0,,2
A2
OK
EOF
	if run_forwarder --once; then
		fail "duplicate multipart sequence blocks unsafe merged send"
	else
		pass "duplicate multipart sequence blocks unsafe merged send"
	fi
	assert_file_lines "duplicate multipart sequence is not forwarded" "$TEST_BODIES" 0
}

test_mt5700m_concat_reference_reuse_stays_separate()
{
	setup_case mt5700m_concat_ref_reuse
	local decoder
	decoder="$CASE_DIR/reused-reference-decoder.awk"
	cat > "$decoder" <<'EOF'
BEGIN {
	ref="8:9"; total=2
	if (pdu == "C1") { seq=1; content="first one"; stamp="20260924100000" }
	else if (pdu == "C2") { seq=2; content="first two"; stamp="20260924100001" }
	else if (pdu == "D1") { seq=1; content="second one"; stamp="20260924101000" }
	else if (pdu == "D2") { seq=2; content="second two"; stamp="20260924101001" }
	else exit 1
	print "+15550000002" > out "/sender"
	print stamp > out "/timestamp"
	print "2026-09-24 10:00:00" > out "/display_time"
	print ref > out "/concat_ref"
	print total > out "/concat_total"
	print seq > out "/concat_seq"
	printf "%s", content > out "/content"
	exit 0
}
EOF
	export SMSFF_MT5700M_DECODER="$decoder"
	export TEST_MT5700M_FIXTURE="$CASE_DIR/reused-reference.txt"
	cat > "$TEST_MT5700M_FIXTURE" <<'EOF'
MT5700M SMS list
+CMGL: 1,0,,2
C1
+CMGL: 2,0,,2
C2
+CMGL: 3,0,,2
D1
+CMGL: 4,0,,2
D2
OK
EOF
	run_forwarder --once
	assert_file_lines "reused concat reference produces two cards" "$TEST_BODIES" 2
	assert_eq "reused concat reference keeps message order" "$(body_contents | paste -sd ',' -)" "first onefirst two,second onesecond two"
}

ORIG_PATH="$PATH"

run_test()
{
	local name="$1"
	if [ -n "${TEST_ONLY:-}" ] && [ "$TEST_ONLY" != "$name" ]; then
		return 0
	fi
	"$name"
}

run_test test_mt5700m_auto_backend_parses_gsm7_without_qmodem
run_test test_mt5700m_ucs2_multipart_merges_across_segment_timestamps
run_test test_mt5700m_status_uses_safe_hcsq_and_temperature_sources
run_test test_poll_queries_live_status_only_when_forwarding_and_adds_quota_remaining
run_test test_mt5700m_failed_webhook_retries_without_replaying_success
run_test test_busybox_awk_decodes_mt5700m_gsm7
run_test test_source_installer_manages_pdu_decoder
run_test test_all_install_paths_ship_prestart_legacy_cutover
run_test test_legacy_cutover_disables_competing_serial_services_and_task
run_test test_quota_history_fixed_point_helpers
run_test test_scheduler_quota_claims_fixed_query_once_per_interval
run_test test_scheduler_quota_failure_is_not_retried_until_next_interval
run_test test_scheduler_suppresses_manual_fixed_query_when_quota_owns_interval
run_test test_forwarder_applies_quota_reply_once_after_successful_send
run_test test_forwarder_rejects_quota_reply_without_latest_success
run_test test_quota_status_marks_counter_decrease_unknown_and_rollover_stale
run_test test_quota_status_always_shows_full_local_month_usage
run_test test_quota_config_rpc_ui_and_package_contract
run_test test_quota_sender_normalization_is_exact
run_test test_quota_reply_parser_is_strict_bounded_and_contract_safe
run_test test_quota_fixed_point_math_avoids_large_counter_float_rounding
run_test test_forwarder_rejects_quota_reply_at_success_stamp
run_test test_mt5700m_multipart_requires_exact_unique_sequence_set
run_test test_mt5700m_concat_reference_reuse_stays_separate
run_test test_status_normalizers_are_busybox_tr_safe
run_test test_test_mode_uses_cached_modem_status_only
run_test test_test_mode_unknown_status_when_cache_absent
run_test test_forwarder_live_lock_contention_fails_but_test_uses_test_lock
run_test test_forwarder_test_mode_reports_send_failure_with_live_daemon_lock
run_test test_scheduler_uses_mt5700m_async_job_and_fails_closed
run_test test_scheduler_rejects_zero_padded_step_before_arithmetic
run_test test_scheduler_atomic_symlink_lock_and_state_writes
run_test test_scheduler_weekday_rejects_zero_padded_and_multi_digit_values
run_test test_scheduler_loop_sleep_aligns_to_next_minute
run_test test_package_lifecycle_preserves_state_and_propagates_failure
run_test test_install_seed_failure_rolls_back_replaced_files
run_test test_install_upgrade_stops_old_custom_service_skips_seed_and_runs_once
run_test test_install_candidate_failure_keeps_existing_custom_and_taskplan
run_test test_install_rpcd_precheck_failure_keeps_existing_custom_live
run_test test_install_migrates_webhook_with_stdin_batch_and_deletes_old_option
run_test test_install_rollback_restores_webhook_migration_configs
run_test test_install_rollback_removes_created_smsforward_config
run_test test_install_webhook_migration_batch_failure_cleans_secret_temp
run_test test_install_rollback_restores_prior_custom_service_state
run_test test_install_restart_failure_removes_new_files_and_restores_legacy
run_test test_install_success_leaves_disabled_vendor_untouched
run_test test_install_success_disables_legacy_taskplan_sms_job
run_test test_taskplan_parser_isolates_customscript_per_section
run_test test_install_restarts_taskplan_and_preserves_existing_legacy_state
run_test test_install_taskplan_restart_failure_rolls_back_cutover
run_test test_install_late_failure_restores_mt5700m_cutover_state
run_test test_install_success_restarts_rpcd_after_plugin_files
run_test test_install_without_target_actions_does_not_restart_rpcd
run_test test_install_rpcd_restart_failure_rolls_back_and_restarts_rpcd_best_effort
run_test test_install_rollback_restarts_taskplan_after_restore
run_test test_uninstall_removes_phase2_files_restores_taskplan_and_managed_prior_files
run_test test_uninstall_without_taskplan_backup_preserves_current_taskplan
run_test test_luci_webui_least_privilege_files
run_test test_luci_parses_real_modem_info_and_allows_chinese_schedule_name
run_test test_rpcd_openwrt_plugin_shape_and_safe_status
run_test test_browser_identity_secret_containment
run_test test_production_uses_only_mt5700m_plugin_transport
run_test test_release_gate_documents_current_mt5700m_live_contract

printf '%s\n' "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
