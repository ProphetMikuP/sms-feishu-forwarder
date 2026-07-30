#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DAEMON="$ROOT/files/usr/bin/sms-feishu-forwarder"
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

make_mocks()
{
	local dir="$1"
	mkdir -p "$dir"
	cat > "$dir/uci" <<'EOS'
#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1" = "get" ] || exit 1
case "$2" in
	sms-feishu-forwarder.settings.enabled) printf '%s\n' "${SMSFF_ENABLED:-1}" ;;
	sms-feishu-forwarder.settings.modem_section) printf '%s\n' "${SMSFF_MODEM_SECTION:-2_1}" ;;
	sms-feishu-forwarder.settings.poll_interval) printf '%s\n' "${SMSFF_POLL_INTERVAL:-10}" ;;
	sms-feishu-forwarder.settings.settle_delay) printf '%s\n' "${SMSFF_SETTLE_DELAY:-0}" ;;
	sms-feishu-forwarder.settings.state_path) printf '%s\n' "$SMSFF_STATE_PATH" ;;
	sms-feishu-forwarder.settings.feishu_webhook) exit 1 ;;
	smsforward.settings.feishu_webhook) printf '%s\n' 'https://open.feishu.cn/open-apis/bot/v2/hook/00000000-0000-0000-0000-000000000000' ;;
	*) exit 1 ;;
esac
EOS
	cat > "$dir/ubus" <<'EOS'
#!/bin/sh
if [ "$1" = "call" ] && [ "$2" = "qmodem_sms" ] && [ "$3" = "list_sms" ]; then
	cat "$TEST_FIXTURE"
	exit 0
fi
if [ "$1" = "call" ] && [ "$2" = "qmodem_sms" ] && [ "$3" = "mark_forwarded" ]; then
	printf '%s\n' "$4" >> "$TEST_MARKS"
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
exit 0
EOS
	chmod +x "$dir/uci" "$dir/ubus" "$dir/curl" "$dir/logger"
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
		if [ "$name" = "sms-feishu-forwarder" ] && [ "${INSTALL_FAIL_RESTART:-0}" = "1" ]; then
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
	export PATH="$MOCK_BIN:$ORIG_PATH"
	export SMSFF_STATE_PATH="$CASE_DIR/seen.keys"
	export SMSFF_LOCK_DIR="$CASE_DIR/lock"
	export SMSFF_SEND_ATTEMPTS=1
	export SMSFF_BACKOFF_BASE=0
	export SMSFF_SETTLE_DELAY=0
	export TEST_BODIES="$CASE_DIR/bodies"
	export TEST_MARKS="$CASE_DIR/marks"
	export TEST_CURL_RESPONSE="$CASE_DIR/curl-response"
	unset CURL_BODY CURL_HTTP_CODE || true
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
	export SERVICE_LOG SERVICE_STATE_DIR
	unset INSTALL_FAIL_SEED INSTALL_FAIL_ONCE INSTALL_FAIL_RESTART || true
	cat > "$MOCK_BIN/install-forwarder" <<'EOS'
#!/bin/sh
printf '%s\n' "$1" >> "$INSTALL_FORWARDER_LOG"
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
	export INSTALL_FORWARDER_LOG="$CASE_DIR/install-forwarder.log"
	: > "$INSTALL_FORWARDER_LOG"
	INSTALL_INIT_ROOT="$CASE_DIR/new-init"
	write_init_mock "$INSTALL_INIT_ROOT" sms-feishu-forwarder 0 0
	export INSTALL_INIT_CMD="$INSTALL_INIT_ROOT/etc/init.d/sms-feishu-forwarder"
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

ORIG_PATH="$PATH"

test_chronological_order
test_incomplete_blocks_later
test_failed_oldest_blocks_later
test_seed_prevents_replay
test_multipart_complete
test_dedupe_restart
test_json_content_survives
test_install_seed_failure_rolls_back_replaced_files
test_install_restart_failure_removes_new_files_and_restores_legacy
test_install_success_leaves_disabled_vendor_untouched

printf '%s\n' "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
