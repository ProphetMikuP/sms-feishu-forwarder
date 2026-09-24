#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="${VERSION:-1.0.0}"
RELEASE="${RELEASE:-24}"
PKG="luci-app-sms-feishu-forwarder"
OUT="${OUT_DIR:-$ROOT/release}"
WORK="${TMPDIR:-/tmp}/${PKG}-build.$$"
EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

mkdir -p "$WORK/control" "$WORK/data" "$OUT"

install_file()
{
	mode="$1"
	src="$2"
	dst="$3"
	mkdir -p "$WORK/data/$(dirname "$dst")"
	cp "$src" "$WORK/data/$dst"
	chmod "$mode" "$WORK/data/$dst"
}

install_file 755 "$ROOT/files/usr/bin/sms-feishu-forwarder" usr/bin/sms-feishu-forwarder
install_file 755 "$ROOT/files/usr/bin/sms-feishu-scheduler" usr/bin/sms-feishu-scheduler
install_file 644 "$ROOT/files/usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk" usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk
install_file 644 "$ROOT/files/usr/lib/sms-feishu-forwarder/quota.sh" usr/lib/sms-feishu-forwarder/quota.sh
install_file 755 "$ROOT/files/usr/lib/sms-feishu-forwarder/mt5700m-cutover" usr/lib/sms-feishu-forwarder/mt5700m-cutover
install_file 755 "$ROOT/files/etc/init.d/sms-feishu-forwarder" etc/init.d/sms-feishu-forwarder
install_file 755 "$ROOT/files/usr/share/rpcd/ucode/sms-feishu-forwarder.uc" usr/share/rpcd/ucode/sms-feishu-forwarder.uc
install_file 644 "$ROOT/files/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json" usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json
install_file 644 "$ROOT/files/usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json" usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json
install_file 644 "$ROOT/files/www/luci-static/resources/view/sms-feishu-forwarder.js" www/luci-static/resources/view/sms-feishu-forwarder.js
install_file 600 "$ROOT/packaging/ipk/default-config" usr/share/sms-feishu-forwarder/default-config

installed_size="$(du -ks "$WORK/data" | cut -f1)"
cat > "$WORK/control/control" <<EOF
Package: $PKG
Version: $VERSION-$RELEASE
Depends: busybox, curl, jq, luci-base, rpcd-mod-ucode, luci-app-mt5700m
Architecture: all
Maintainer: Link Camp
Section: luci
Priority: optional
Installed-Size: $installed_size
Description: SMS to Feishu forwarding, modem status cards and scheduled SMS.
 Uses only the luci-app-mt5700m read/action interfaces, filtered CPE/5G status,
 generic scheduled SMS jobs and a least-privilege LuCI management page.
EOF

for script in postinst prerm postrm; do
	cp "$ROOT/packaging/ipk/$script" "$WORK/control/$script"
	chmod 755 "$WORK/control/$script"
done

find "$WORK/data" "$WORK/control" -type d -exec chmod 755 {} +
find "$WORK/data" "$WORK/control" -exec touch -h -d "@$EPOCH" {} +
printf '2.0\n' > "$WORK/debian-binary"
touch -d "@$EPOCH" "$WORK/debian-binary"

(
	cd "$WORK/control"
	tar --sort=name --format=gnu --numeric-owner --owner=0 --group=0 --mtime="@$EPOCH" -czf "$WORK/control.tar.gz" .
)
(
	cd "$WORK/data"
	tar --sort=name --format=gnu --numeric-owner --owner=0 --group=0 --mtime="@$EPOCH" -czf "$WORK/data.tar.gz" .
)

artifact="$OUT/${PKG}_${VERSION}-${RELEASE}_all.ipk"
rm -f "$artifact"
(
	cd "$WORK"
	tar --format=gnu --numeric-owner --owner=0 --group=0 --mtime="@$EPOCH" -czf "$artifact" debian-binary control.tar.gz data.tar.gz
)
chmod 644 "$artifact"

printf '%s\n' "$artifact"
