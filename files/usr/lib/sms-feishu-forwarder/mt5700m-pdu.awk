# Decode an SMS-DELIVER PDU without target-specific external helpers.
# Inputs: -v pdu=HEX -v out=TEMP_DIRECTORY

function hex_value(c, p) {
	p = index("0123456789ABCDEF", toupper(c))
	return p - 1
}

function byte_at(i, pos, hi, lo) {
	pos = (i * 2) + 1
	hi = hex_value(substr(hex, pos, 1))
	lo = hex_value(substr(hex, pos + 1, 1))
	if (hi < 0 || lo < 0)
		return -1
	return (hi * 16) + lo
}

function swapped_bcd(value) {
	return ((value % 16) * 10) + int(value / 16)
}

function put_file(name, value, path) {
	path = out "/" name
	printf "%s", value > path
	close(path)
}

function utf8(codepoint) {
	if (codepoint < 128)
		return sprintf("%c", codepoint)
	if (codepoint < 2048)
		return sprintf("%c%c", 192 + int(codepoint / 64), 128 + (codepoint % 64))
	if (codepoint < 65536)
		return sprintf("%c%c%c", 224 + int(codepoint / 4096), 128 + (int(codepoint / 64) % 64), 128 + (codepoint % 64))
	return sprintf("%c%c%c%c", 240 + int(codepoint / 262144), 128 + (int(codepoint / 4096) % 64), 128 + (int(codepoint / 64) % 64), 128 + (codepoint % 64))
}

function gsm_basic(value) {
	if (value == 0) return "@"
	if (value == 2) return "$"
	if (value == 3) return "£"
	if (value == 4) return "¥"
	if (value == 5) return "è"
	if (value == 6) return "é"
	if (value == 7) return "ù"
	if (value == 8) return "ì"
	if (value == 9) return "ò"
	if (value == 10) return "\n"
	if (value == 11) return "Ø"
	if (value == 12) return "ø"
	if (value == 13) return "\r"
	if (value == 14) return "Å"
	if (value == 15) return "å"
	if (value == 16) return "Δ"
	if (value == 17) return "_"
	if (value == 18) return "Φ"
	if (value == 19) return "Γ"
	if (value == 20) return "Λ"
	if (value == 21) return "Ω"
	if (value == 22) return "Π"
	if (value == 23) return "Ψ"
	if (value == 24) return "Σ"
	if (value == 25) return "Θ"
	if (value == 26) return "Ξ"
	if (value == 27) return "\033"
	if (value == 28) return "Æ"
	if (value == 29) return "æ"
	if (value == 30) return "ß"
	if (value == 31) return "É"
	if (value >= 32 && value <= 47) return substr(" !\"#¤%&'()*+,-./", value - 31, 1)
	if (value >= 48 && value <= 57) return sprintf("%c", value - 48 + 48)
	if (value == 58) return ":"
	if (value == 59) return ";"
	if (value == 60) return "<"
	if (value == 61) return "="
	if (value == 62) return ">"
	if (value == 63) return "?"
	if (value >= 65 && value <= 90) return sprintf("%c", value)
	if (value == 91) return "Ä"
	if (value == 92) return "Ö"
	if (value == 93) return "Ñ"
	if (value == 94) return "Ü"
	if (value == 95) return "§"
	if (value == 96) return "¿"
	if (value >= 97 && value <= 122) return sprintf("%c", value)
	if (value == 123) return "ä"
	if (value == 124) return "ö"
	if (value == 125) return "ñ"
	if (value == 126) return "ü"
	if (value == 127) return "à"
	return "�"
}

function gsm_extended(value) {
	if (value == 10) return "\f"
	if (value == 20) return "^"
	if (value == 40) return "{"
	if (value == 41) return "}"
	if (value == 47) return "\\"
	if (value == 60) return "["
	if (value == 61) return "~"
	if (value == 62) return "]"
	if (value == 64) return "|"
	if (value == 101) return "€"
	return "�"
}

function power_of_two(exponent, result, i) {
	result = 1
	for (i = 0; i < exponent; i++)
		result *= 2
	return result
}

function user_septet(data_start, bit_position, byte_index, shift, pair) {
	byte_index = int(bit_position / 8)
	shift = bit_position % 8
	pair = byte_at(data_start + byte_index) + (256 * byte_at(data_start + byte_index + 1))
	return int(pair / power_of_two(shift)) % 128
}

function decode_ucs2(data_start, octets, i, first, second, codepoint, result) {
	result = ""
	for (i = 0; i + 1 < octets; i += 2) {
		first = byte_at(data_start + i)
		second = byte_at(data_start + i + 1)
		codepoint = (first * 256) + second
		if (codepoint >= 55296 && codepoint <= 56319 && i + 3 < octets) {
			first = byte_at(data_start + i + 2)
			second = byte_at(data_start + i + 3)
			if (first * 256 + second >= 56320 && first * 256 + second <= 57343) {
				codepoint = 65536 + ((codepoint - 55296) * 1024) + (first * 256 + second - 56320)
				i += 2
			}
		}
		result = result utf8(codepoint)
	}
	return result
}

function decode_gsm7(data_start, first_bit, septets, i, value, escaped, result) {
	result = ""
	escaped = 0
	for (i = 0; i < septets; i++) {
		value = user_septet(data_start, first_bit + (i * 7))
		if (escaped) {
			result = result gsm_extended(value)
			escaped = 0
		} else if (value == 27) {
			escaped = 1
		} else {
			result = result gsm_basic(value)
		}
	}
	return result
}

function parse_concat(header_start, header_octets, i, iei, ie_len, ref, total, seq, candidate) {
	ref = ""
	total = 1
	seq = 1
	i = header_start + 1
	while (i < header_start + header_octets) {
		iei = byte_at(i)
		ie_len = byte_at(i + 1)
		if (iei < 0 || ie_len < 0 || i + 2 + ie_len > header_start + header_octets)
			break
		if (iei == 0 && ie_len >= 3) {
			ref = sprintf("8:%d", byte_at(i + 2))
			total = byte_at(i + 3)
			seq = byte_at(i + 4)
			break
		}
		if (iei == 8 && ie_len >= 4) {
			ref = sprintf("16:%d", (byte_at(i + 2) * 256) + byte_at(i + 3))
			total = byte_at(i + 4)
			seq = byte_at(i + 5)
			break
		}
		i += 2 + ie_len
	}
	concat_ref = ref
	concat_total = total
	concat_seq = seq
}

BEGIN {
	hex = toupper(pdu)
	gsub(/[[:space:]]/, "", hex)
	if (out == "" || hex == "" || hex !~ /^[0-9A-F]+$/ || length(hex) % 2 != 0)
		exit 1
	bytes = length(hex) / 2
	if (bytes < 2)
		exit 1

	smsc_octets = byte_at(0)
	if (smsc_octets < 0 || 1 + smsc_octets >= bytes)
		exit 1
	offset = 1 + smsc_octets
	first_octet = byte_at(offset)
	if (first_octet < 0)
		exit 1
	offset++
	udhi = int(first_octet / 64) % 2

	sender_length = byte_at(offset)
	offset++
	sender_toa = byte_at(offset)
	offset++
	if (sender_length < 0 || sender_toa < 0)
		exit 1
	sender = ""
	for (i = 0; i < int((sender_length + 1) / 2); i++) {
		b = byte_at(offset + i)
		if (b < 0)
			exit 1
		low = b % 16
		high = int(b / 16)
		if (i * 2 < sender_length && low <= 9)
			sender = sender sprintf("%d", low)
		if (i * 2 + 1 < sender_length && high <= 9)
			sender = sender sprintf("%d", high)
	}
	if (int(sender_toa / 16) == 9)
		sender = "+" sender
	offset += int((sender_length + 1) / 2)
	if (offset + 2 + 7 >= bytes)
		exit 1

	pid = byte_at(offset)
	dcs = byte_at(offset + 1)
	offset += 2
	year = swapped_bcd(byte_at(offset))
	month = swapped_bcd(byte_at(offset + 1))
	day = swapped_bcd(byte_at(offset + 2))
	hour = swapped_bcd(byte_at(offset + 3))
	minute = swapped_bcd(byte_at(offset + 4))
	second = swapped_bcd(byte_at(offset + 5))
	if (year < 0 || month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59)
		exit 1
	year += 2000
	timestamp = sprintf("%04d%02d%02d%02d%02d%02d", year, month, day, hour, minute, second)
	display_time = sprintf("%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
	offset += 7
	udl = byte_at(offset)
	offset++
	if (udl < 0)
		exit 1

	header_octets = 0
	if (udhi) {
		header_octets = byte_at(offset) + 1
		if (header_octets < 1 || offset + header_octets > bytes)
			exit 1
		parse_concat(offset, header_octets, i, iei, ie_len, ref, total, seq, candidate)
	} else {
		concat_ref = ""
		concat_total = 1
		concat_seq = 1
	}

	if (int(dcs / 4) % 4 == 2) {
		payload_octets = udl - header_octets
		if (payload_octets < 0 || offset + header_octets + payload_octets > bytes)
			exit 1
		content = decode_ucs2(offset + header_octets, payload_octets)
	} else {
		header_septets = int((header_octets * 8 + 6) / 7)
		payload_septets = udl - header_septets
		if (payload_septets < 0)
			exit 1
		if (offset + int((udl * 7 + 7) / 8) > bytes)
			exit 1
		content = decode_gsm7(offset, header_octets * 8, payload_septets)
	}

	put_file("sender", sender)
	put_file("timestamp", timestamp)
	put_file("display_time", display_time)
	put_file("concat_ref", concat_ref)
	put_file("concat_total", concat_total)
	put_file("concat_seq", concat_seq)
	put_file("content", content)
}
