#!/usr/bin/env python3
import gzip
import hashlib
import io
import os
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

apk = Path(sys.argv[1] if len(sys.argv) > 1 else "release/luci-app-sms-feishu-forwarder-1.0.0-r22.apk")
assert apk.is_file(), f"missing APK: {apk}"
blob = apk.read_bytes()
segments = []
remaining = blob
import zlib
while remaining:
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    raw = decoder.decompress(remaining) + decoder.flush()
    assert decoder.unused_data or len(segments) == 1, "invalid concatenated gzip APK"
    segments.append((remaining[: len(remaining) - len(decoder.unused_data)], raw))
    remaining = decoder.unused_data
assert len(segments) == 2, f"expected 2 gzip members, got {len(segments)}"
control_gz, control_raw = segments[0]
data_gz, data_raw = segments[1]
assert not control_raw.endswith(b"\0" * 1024), "control tar must omit terminator padding"

with tarfile.open(fileobj=io.BytesIO(control_raw), mode="r:") as control:
    names = set(control.getnames())
    assert {".PKGINFO", ".post-install", ".post-upgrade", ".pre-deinstall", ".post-deinstall"} <= names
    pkginfo = control.extractfile(".PKGINFO").read().decode()
assert "pkgname = luci-app-sms-feishu-forwarder" in pkginfo
assert "pkgver = 1.0.0-22" in pkginfo
assert "arch = aarch64_cortex-a53" in pkginfo
assert f"datahash = {hashlib.sha256(data_gz).hexdigest()}" in pkginfo
for dep in ("busybox", "curl", "jq", "luci-base", "rpcd-mod-ucode", "luci-app-mt5700m"):
    assert f"depend = {dep}" in pkginfo
for legacy_dep in ("qmodem", "ubus-at-daemon", "sms-tool_q"):
    assert legacy_dep not in pkginfo

with tarfile.open(fileobj=io.BytesIO(data_raw), mode="r:") as data:
    members = {m.name: m for m in data.getmembers()}
    required = {
        "usr/bin/sms-feishu-forwarder",
        "usr/bin/sms-feishu-scheduler",
        "usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk",
        "usr/lib/sms-feishu-forwarder/quota.sh",
        "usr/lib/sms-feishu-forwarder/mt5700m-cutover",
        "etc/init.d/sms-feishu-forwarder",
        "usr/share/sms-feishu-forwarder/default-config",
        "usr/share/rpcd/ucode/sms-feishu-forwarder.uc",
        "usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json",
        "usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json",
        "www/luci-static/resources/view/sms-feishu-forwarder.js",
    }
    assert required <= set(members), f"missing payload: {sorted(required - set(members))}"
    required_dirs = {str(Path(name).parent) for name in required}
    assert required_dirs <= set(members), f"missing directory entries: {sorted(required_dirs - set(members))}"
    assert all(members[name].isdir() for name in required_dirs)
    assert "etc/config/sms-feishu-forwarder" not in members
    for name, member in members.items():
        if member.isfile():
            body = data.extractfile(member).read()
            expected = member.pax_headers.get("APK-TOOLS.checksum.SHA1")
            assert expected == hashlib.sha1(body).hexdigest(), f"bad PAX checksum: {name}"
    default = data.extractfile("usr/share/sms-feishu-forwarder/default-config").read().decode()
assert "option backend" not in default
assert "sms_port" not in default
assert "ubus_timeout" not in default
assert re.findall(r"option enabled '([01])'", default) == ["0", "0", "0"]
assert not re.search(rb"https://open\.feishu\.cn/open-apis/bot/v2/hook/[A-Za-z0-9._-]{20,}", blob)
assert not re.search(rb"(^|\D)\d{14,}(\D|$)", blob)
print("apk_test=ok")
