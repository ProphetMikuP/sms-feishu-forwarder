#!/bin/sh
set -eu

IPK="${1:?usage: test-ipk.sh PACKAGE.ipk}"
TMP="${TMPDIR:-/tmp}/smsff-ipk-test.$$"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

mkdir -p "$TMP/outer" "$TMP/control" "$TMP/data" "$TMP/root"
tar -xzf "$IPK" -C "$TMP/outer"
[ "$(cat "$TMP/outer/debian-binary")" = "2.0" ]
tar -xzf "$TMP/outer/control.tar.gz" -C "$TMP/control"
tar -xzf "$TMP/outer/data.tar.gz" -C "$TMP/data"

control="$TMP/control/control"
grep -qx 'Package: luci-app-sms-feishu-forwarder' "$control"
grep -qx 'Architecture: all' "$control"
grep -q '^Depends: .*luci-base.*rpcd-mod-ucode.*luci-app-mt5700m' "$control"
if grep -Eq 'qmodem|ubus-at-daemon|sms-tool_q' "$control"; then
	printf '%s\n' 'legacy modem dependency remains in control metadata' >&2
	exit 1
fi

[ ! -e "$TMP/data/etc/config/sms-feishu-forwarder" ]
[ -f "$TMP/data/usr/share/sms-feishu-forwarder/default-config" ]
[ -f "$TMP/data/usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk" ]
[ -f "$TMP/data/usr/lib/sms-feishu-forwarder/quota.sh" ]
[ -x "$TMP/data/usr/lib/sms-feishu-forwarder/mt5700m-cutover" ]
[ "$(sed -n "s/^[[:space:]]*option enabled '\([^']*\)'.*/\1/p" "$TMP/data/usr/share/sms-feishu-forwarder/default-config" | tr '\n' ' ')" = '0 0 0 ' ]

for script in "$TMP/control/postinst" "$TMP/control/prerm" "$TMP/control/postrm" \
	"$TMP/data/usr/bin/sms-feishu-forwarder" "$TMP/data/usr/bin/sms-feishu-scheduler" \
	"$TMP/data/usr/lib/sms-feishu-forwarder/mt5700m-cutover" \
	"$TMP/data/etc/init.d/sms-feishu-forwarder"; do
	busybox ash -n "$script"
done
jq empty "$TMP/data/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json" \
	"$TMP/data/usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json"
node --check "$TMP/data/www/luci-static/resources/view/sms-feishu-forwarder.js"

if grep -R -E 'https://open\.feishu\.cn/open-apis/bot/v2/hook/[A-Za-z0-9._-]{20,}' "$TMP/control" "$TMP/data"; then
	echo 'real-looking webhook found in package' >&2
	exit 1
fi
if grep -R -E '(^|[^0-9])[0-9]{14,}([^0-9]|$)' "$TMP/control" "$TMP/data"; then
	echo 'long device identity-like number found in package' >&2
	exit 1
fi

cp -a "$TMP/data/." "$TMP/root/"
IPKG_INSTROOT="$TMP/root" sh "$TMP/control/postinst"
[ -f "$TMP/root/etc/config/sms-feishu-forwarder" ]
[ "$(stat -c '%a' "$TMP/root/etc/config/sms-feishu-forwarder")" = "600" ]
[ "$(sed -n "s/^[[:space:]]*option enabled '\([^']*\)'.*/\1/p" "$TMP/root/etc/config/sms-feishu-forwarder" | tr '\n' ' ')" = '0 0 0 ' ]
[ -f "$TMP/root/etc/config/smsforward" ]
[ "$(stat -c '%a' "$TMP/root/etc/config/smsforward")" = "600" ]
grep -qx "config settings 'settings'" "$TMP/root/etc/config/smsforward"

printf "%s\n" "config settings 'settings'" "\toption feishu_webhook 'PRESERVE_PLACEHOLDER'" > "$TMP/root/etc/config/smsforward"
secret_before="$(sha256sum "$TMP/root/etc/config/smsforward" | cut -d' ' -f1)"
IPKG_INSTROOT="$TMP/root" sh "$TMP/control/postinst"
[ "$secret_before" = "$(sha256sum "$TMP/root/etc/config/smsforward" | cut -d' ' -f1)" ]

printf '%s\n' 'ipk_test=ok'
