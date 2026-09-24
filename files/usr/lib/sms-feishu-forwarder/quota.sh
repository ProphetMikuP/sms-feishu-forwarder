# Shared MT5700M quota helpers. Source from the forwarder and scheduler.

quota_history_path()
{
	printf '%s' "${SMSFF_TRAFFIC_HISTORY_PATH:-/etc/mt5700m/traffic-history}"
}

quota_current_month()
{
	printf '%s' "${SMSFF_NOW_MONTH:-$(date '+%Y-%m' 2>/dev/null || printf unknown)}"
}

quota_read_current_counters()
{
	local path month
	path="$(quota_history_path)"
	month="$(quota_current_month)"
	[ -r "$path" ] || return 1
	awk -v wanted_month="$month" '
		$1 == "month" && $2 == "eth2" && $3 == wanted_month &&
			NF == 5 && $4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ {
			rx = $4
			tx = $5
			have = 1
		}
		END {
			if (have)
				printf "%s|%s|%s\n", wanted_month, rx, tx
			else
				exit 1
		}
	' "$path"
}

quota_bytes_to_centi_gb()
{
	local bytes="$1"
	case "$bytes" in
		""|*[!0-9]*) return 1 ;;
	esac
	awk -v bytes="$bytes" '
		BEGIN {
			sub(/^0+/, "", bytes)
			if (bytes == "") bytes = "0"
			divisor = 10000000
			quotient = ""
			remainder = 0
			for (i = 1; i <= length(bytes); i++) {
				remainder = remainder * 10 + (substr(bytes, i, 1) + 0)
				digit = int(remainder / divisor)
				quotient = quotient digit
				remainder -= digit * divisor
			}
			sub(/^0+/, "", quotient)
			if (quotient == "") quotient = "0"
			print quotient
		}
	'
}

quota_format_centi()
{
	local value="$1" whole fraction
	case "$value" in
		""|*[!0-9]*) return 1 ;;
	esac
	while [ "${#value}" -gt 1 ]; do
		case "$value" in
			0*) value="${value#0}" ;;
			*) break ;;
		esac
	done
	if [ "${#value}" -le 2 ]; then
		whole=0
		fraction="$value"
	else
		whole="${value%??}"
		fraction="${value#"$whole"}"
	fi
	while [ "${#fraction}" -lt 2 ]; do fraction="0${fraction}"; done
	printf '%s.%sGB' "$whole" "$fraction"
}

quota_state_path()
{
	printf '%s' "${QUOTA_STATE_PATH:-${SMSFF_QUOTA_STATE_PATH:-/var/lib/sms-feishu-forwarder/quota-state.json}}"
}

quota_status_path()
{
	printf '%s' "${QUOTA_STATUS_PATH:-${SMSFF_QUOTA_STATUS_PATH:-/var/lib/sms-feishu-forwarder/quota-status.json}}"
}

quota_state_json()
{
	local path
	path="$(quota_state_path)"
	if [ -r "$path" ]; then
		jq -c . "$path" 2>/dev/null || printf '{}'
	else
		printf '{}'
	fi
}

quota_state_value()
{
	local key="$1"
	quota_state_json | jq -r --arg key "$key" '.[$key] // empty' 2>/dev/null || true
}

quota_atomic_write_text()
{
	local path="$1"
	local value="$2"
	local dir base tmp
	dir="${path%/*}"
	base="${path##*/}"
	mkdir -p "$dir" || return 1
	tmp="$(mktemp "$dir/.$base.XXXXXX")" || return 1
	if ! printf '%s\n' "$value" > "$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	chmod 600 "$tmp" || {
		rm -f "$tmp"
		return 1
	}
	mv -f "$tmp" "$path"
}

quota_write_state_json()
{
	local value="$1"
	printf '%s' "$value" | jq -c . >/dev/null 2>&1 || return 1
	quota_atomic_write_text "$(quota_state_path)" "$value"
}

quota_interval_days()
{
	case "${1:-off}" in
		7|14) printf '%s' "$1" ;;
		off) printf '0' ;;
		*) return 1 ;;
	esac
}

quota_sender_is_10086()
{
	case "$1" in
		10086|+8610086) return 0 ;;
		*) return 1 ;;
	esac
}

quota_is_fixed_query()
{
	quota_sender_is_10086 "$1" && [ "$2" = "CXLL" ]
}

quota_parse_decimal_centi()
{
	# MT5700M v3.0.3's accepted CXLL contract reports a fixed 100GB total;
	# cap the parsed remaining value at that contract total before arithmetic.
	local value="$1"
	local integer fraction centi diff
	case "$value" in
		""|*[!0-9.]*) return 1 ;;
	esac
	case "$value" in
		.*|*.|*.*.*) return 1 ;;
	esac
	integer="${value%%.*}"
	if [ "$value" = "$integer" ]; then
		fraction=00
	else
		fraction="${value#*.}"
		[ "${#fraction}" -le 2 ] || return 1
		[ "${#fraction}" -eq 1 ] && fraction="${fraction}0"
	fi
	[ -n "$integer" ] || return 1
	[ "${#integer}" -le 3 ] || return 1
	while [ "${#integer}" -gt 1 ]; do
		case "$integer" in
			0*) integer="${integer#0}" ;;
			*) break ;;
		esac
	done
	centi="${integer}${fraction}"
	while [ "${#centi}" -gt 1 ]; do
		case "$centi" in
			0*) centi="${centi#0}" ;;
			*) break ;;
		esac
	done
	diff="$(quota_sub_decimal 10000 "$centi" 2>/dev/null)" || return 1
	case "$diff" in
		-*) return 1 ;;
	esac
	printf '%s' "$centi"
}

quota_parse_reply_remaining()
{
	local sender="$1"
	local content="$2"
	local body_bytes value
	quota_sender_is_10086 "$sender" || return 1
	body_bytes="$(printf '%s' "$content" | wc -c | tr -d '[:space:]')"
	case "$body_bytes" in
		""|*[!0-9]*) return 1 ;;
	esac
	[ "$body_bytes" -le 2048 ] || return 1
	value="$(printf '%s' "$content" | awk '
		BEGIN { found = 0; invalid = 0 }
		NR > 1 { invalid = 1; next }
		{
			if ($0 ~ /^本月国内通用流量共100GB,剩余[0-9]+([.][0-9][0-9]?)?GB$/) {
				v = $0
				sub(/^本月国内通用流量共100GB,剩余/, "", v)
				sub(/GB$/, "", v)
				value = v
				found++
			} else if ($0 ~ /^【温馨提醒】尊敬的客户,您好!【流量查询】您好!截至[0-9]+月[0-9]+日[0-9]+时[0-9]+分,您本月国内通用流量共100GB,剩余[0-9]+([.][0-9][0-9]?)?GB。所有流量资源使用详情,点击 http:\/\/dx[.]10086[.]cn\/[A-Za-z0-9._\/-]+ 查询。 点击 https:\/\/dx[.]10086[.]cn\/[A-Za-z0-9._\/-]+ 签到享好礼!流量话费等你来领,签满[0-9]+次还可抽[0-9]+元话费!【中国移动】$/) {
				v = $0
				sub(/^.*剩余/, "", v)
				sub(/GB。.*$/, "", v)
				value = v
				found++
			} else {
				invalid = 1
			}
		}
		END {
			if (NR != 1 || invalid || found != 1) exit 1
			print value
		}
	' 2>/dev/null)" || return 1
	quota_parse_decimal_centi "$value"
}

quota_add_decimal()
{
	local left="$1"
	local right="$2"
	case "$left:$right" in *[!0-9:]*|*:) return 1 ;; esac
	awk -v left="$left" -v right="$right" '
		BEGIN {
			sub(/^0+/, "", left); if (left == "") left = "0"
			sub(/^0+/, "", right); if (right == "") right = "0"
			i = length(left); j = length(right); carry = 0; out = ""
			while (i > 0 || j > 0 || carry) {
				a = i > 0 ? substr(left, i, 1) + 0 : 0
				b = j > 0 ? substr(right, j, 1) + 0 : 0
				sum = a + b + carry
				out = (sum % 10) out
				carry = int(sum / 10)
				i--; j--
			}
			print out
		}
	'
}

quota_sub_decimal()
{
	local left="$1"
	local right="$2"
	case "$left:$right" in *[!0-9:]*|*:) return 1 ;; esac
	awk -v left="$left" -v right="$right" '
		BEGIN {
			sub(/^0+/, "", left); if (left == "") left = "0"
			sub(/^0+/, "", right); if (right == "") right = "0"
			negative = 0
			less = 0
			if (length(left) < length(right)) {
				less = 1
			} else if (length(left) == length(right)) {
				for (k = 1; k <= length(left); k++) {
					a = substr(left, k, 1) + 0
					b = substr(right, k, 1) + 0
					if (a < b) { less = 1; break }
					if (a > b) break
				}
			}
			if (less) {
				tmp = left; left = right; right = tmp; negative = 1
			}
			i = length(left); j = length(right); borrow = 0; out = ""
			while (i > 0) {
				a = substr(left, i, 1) + 0 - borrow
				b = j > 0 ? substr(right, j, 1) + 0 : 0
				diff = a - b
				if (diff < 0) { diff += 10; borrow = 1 } else borrow = 0
				out = diff out
				i--; j--
			}
			sub(/^0+/, "", out)
			if (out == "") out = "0"
			print (negative && out != "0" ? "-" : "") out
		}
	'
}

quota_decimal_less()
{
	local difference
	difference="$(quota_sub_decimal "$1" "$2" 2>/dev/null)" || return 1
	case "$difference" in
		-*) return 0 ;;
		*) return 1 ;;
	esac
}

quota_epoch_now()
{
	local value="${SMSFF_NOW_EPOCH:-$(date +%s 2>/dev/null || printf '')}"
	case "$value" in ""|*[!0-9]*) return 1 ;; esac
	while [ "${#value}" -gt 1 ]; do
		case "$value" in
			0*) value="${value#0}" ;;
			*) break ;;
		esac
	done
	printf '%s' "$value"
}

quota_message_stamp_now()
{
	local epoch offset shifted
	if [ -n "${SMSFF_NOW_MESSAGE_TS:-}" ]; then
		printf '%s' "$SMSFF_NOW_MESSAGE_TS"
		return
	fi
	epoch="$(quota_epoch_now)" || return 1
	offset="${SMSFF_MODEM_TIME_OFFSET:-28800}"
	case "$offset" in ""|*[!0-9]*) return 1 ;; esac
	shifted=$((epoch + offset))
	date -u -d "@$shifted" '+%Y%m%d%H%M%S' 2>/dev/null || \
	date -u -r "$shifted" '+%Y%m%d%H%M%S' 2>/dev/null
}

quota_stamp_display()
{
	local stamp="$1"
	case "$stamp" in
		??????????????)
			printf '%s\n' "$stamp" | awk '{ printf "%s-%s-%s %s:%s:%s", substr($0,1,4), substr($0,5,2), substr($0,7,2), substr($0,9,2), substr($0,11,2), substr($0,13,2) }'
			;;
		*) printf '%s' "$stamp" ;;
	esac
}

quota_epoch_display()
{
	local epoch="$1" offset shifted
	case "$epoch" in ""|*[!0-9]*) printf '未知'; return ;; esac
	offset="${SMSFF_MODEM_TIME_OFFSET:-28800}"
	case "$offset" in ""|*[!0-9]*) printf '未知'; return ;; esac
	shifted=$((epoch + offset))
	date -u -d "@$shifted" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
	date -u -r "$shifted" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '未知'
}

quota_refresh_status()
{
	local interval="${1:-off}"
	local state month current row rx tx base_rx base_tx carrier_total carrier delta usage total_bytes total_usage estimate
	local last_calibration next_due status local_text carrier_total_text carrier_text estimate_text last_text next_text
	case "$interval" in 7|14) ;; *) interval=off ;; esac
	state="$(quota_state_json)"
	last_calibration="$(printf '%s' "$state" | jq -r '.last_calibration_stamp // empty' 2>/dev/null || true)"
	next_due="$(printf '%s' "$state" | jq -r '.next_due_epoch // empty' 2>/dev/null || true)"
	carrier="$(printf '%s' "$state" | jq -r '.carrier_centi // empty' 2>/dev/null || true)"
	carrier_total="$(printf '%s' "$state" | jq -r '.carrier_total_centi // empty' 2>/dev/null || true)"
	month="$(printf '%s' "$state" | jq -r '.month // empty' 2>/dev/null || true)"
	base_rx="$(printf '%s' "$state" | jq -r '.base_rx // empty' 2>/dev/null || true)"
	base_tx="$(printf '%s' "$state" | jq -r '.base_tx // empty' 2>/dev/null || true)"
	status="$(printf '%s' "$state" | jq -r '.result // empty' 2>/dev/null || true)"
	local_text='未知'
	carrier_total_text='未知'
	carrier_text='未知'
	estimate_text='未知'
	last_text='未知'
	next_text='未知'
	current="$(quota_current_month)"
	row="$(quota_read_current_counters 2>/dev/null || true)"
	if [ -n "$row" ]; then
		IFS='|' read -r _ rx tx <<EOF
$row
EOF
		total_bytes="$(quota_add_decimal "$rx" "$tx" 2>/dev/null || printf '')"
		total_usage="$(quota_bytes_to_centi_gb "$total_bytes" 2>/dev/null || printf '')"
		[ -n "$total_usage" ] && local_text="$(quota_format_centi "$total_usage")"
	fi
	if [ "$interval" = off ]; then
		status=off
	else
		[ -n "$carrier_total" ] && carrier_total_text="$(quota_format_centi "$carrier_total" 2>/dev/null || printf '未知')"
		[ -n "$carrier" ] && carrier_text="$(quota_format_centi "$carrier" 2>/dev/null || printf '未知')"
		[ -n "$last_calibration" ] && last_text="$(quota_stamp_display "$last_calibration")"
		[ -n "$next_due" ] && next_text="$(quota_epoch_display "$next_due")"
		if [ -n "$month" ] && [ "$month" != "$current" ]; then
			status=stale
		elif [ -n "$month" ] && [ -n "$base_rx" ] && [ -n "$base_tx" ] && [ -n "$row" ]; then
			if quota_decimal_less "$rx" "$base_rx" || quota_decimal_less "$tx" "$base_tx"; then
				status=unknown
				local_text='未知'
			else
				delta="$(quota_add_decimal "$(quota_sub_decimal "$rx" "$base_rx")" "$(quota_sub_decimal "$tx" "$base_tx")")"
				usage="$(quota_bytes_to_centi_gb "$delta" 2>/dev/null || printf '')"
				if [ -n "$carrier" ] && [ -n "$usage" ]; then
					estimate="$(quota_sub_decimal "$carrier" "$usage" 2>/dev/null || printf '')"
					case "$estimate" in
						-*) estimate=0 ;;
					esac
					[ -n "$estimate" ] && estimate_text="$(quota_format_centi "$estimate")"
				fi
			fi
		fi
		[ -n "$last_calibration" ] || status=unknown
		[ -n "$status" ] || status=unknown
	fi
	quota_atomic_write_text "$(quota_status_path)" "$(jq -cn \
		--arg interval "$interval" \
		--arg local_usage "$local_text" \
		--arg carrier_total "$carrier_total_text" \
		--arg calibrated_remaining "$carrier_text" \
		--arg estimated_remaining "$estimate_text" \
		--arg last_calibration "$last_text" \
		--arg next_due "$next_text" \
		--arg status "$status" \
		'{interval:$interval,local_usage:$local_usage,carrier_total:$carrier_total,calibrated_remaining:$calibrated_remaining,estimated_remaining:$estimated_remaining,last_calibration:$last_calibration,next_due:$next_due,status:$status}')"
}
