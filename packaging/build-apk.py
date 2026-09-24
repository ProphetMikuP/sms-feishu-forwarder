#!/usr/bin/env python3
"""Build an unsigned APK-v2 compatibility package for apk-tools 3."""
import gzip
import hashlib
import io
import os
import tarfile
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parent.parent
VERSION = os.environ.get("VERSION", "1.0.0")
RELEASE = os.environ.get("RELEASE", "24")
ARCH = os.environ.get("ARCH", "aarch64_cortex-a53")
EPOCH = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
OUT = Path(os.environ.get("OUT_DIR", ROOT / "release"))
PKG = "luci-app-sms-feishu-forwarder"

PAYLOAD = {
    "usr/bin/sms-feishu-forwarder": (ROOT / "files/usr/bin/sms-feishu-forwarder", 0o755),
    "usr/bin/sms-feishu-scheduler": (ROOT / "files/usr/bin/sms-feishu-scheduler", 0o755),
    "usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk": (ROOT / "files/usr/lib/sms-feishu-forwarder/mt5700m-pdu.awk", 0o644),
    "usr/lib/sms-feishu-forwarder/quota.sh": (ROOT / "files/usr/lib/sms-feishu-forwarder/quota.sh", 0o644),
    "usr/lib/sms-feishu-forwarder/mt5700m-cutover": (ROOT / "files/usr/lib/sms-feishu-forwarder/mt5700m-cutover", 0o755),
    "etc/init.d/sms-feishu-forwarder": (ROOT / "files/etc/init.d/sms-feishu-forwarder", 0o755),
    "usr/share/rpcd/ucode/sms-feishu-forwarder.uc": (ROOT / "files/usr/share/rpcd/ucode/sms-feishu-forwarder.uc", 0o755),
    "usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json": (ROOT / "files/usr/share/rpcd/acl.d/luci-app-sms-feishu-forwarder.json", 0o644),
    "usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json": (ROOT / "files/usr/share/luci/menu.d/luci-app-sms-feishu-forwarder.json", 0o644),
    "www/luci-static/resources/view/sms-feishu-forwarder.js": (ROOT / "files/www/luci-static/resources/view/sms-feishu-forwarder.js", 0o644),
    "usr/share/sms-feishu-forwarder/default-config": (ROOT / "packaging/ipk/default-config", 0o600),
}
CONTROL = {
    ".post-install": (ROOT / "packaging/ipk/postinst", 0o755),
    ".post-upgrade": (ROOT / "packaging/ipk/postinst", 0o755),
    ".pre-deinstall": (ROOT / "packaging/ipk/prerm", 0o755),
    ".post-deinstall": (ROOT / "packaging/ipk/postrm", 0o755),
}


def info(name: str, mode: int, size: int, pax=None) -> tarfile.TarInfo:
    item = tarfile.TarInfo(name)
    item.mode = mode
    item.uid = item.gid = 0
    item.uname = item.gname = "root"
    item.mtime = EPOCH
    item.size = size
    item.pax_headers = pax or {}
    return item


def tar_stream(entries, strip_terminator=False):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for name, body, mode, pax in entries:
            if body is None:
                item = info(name, mode, 0, pax)
                item.type = tarfile.DIRTYPE
                archive.addfile(item)
            else:
                archive.addfile(info(name, mode, len(body), pax), io.BytesIO(body))
    raw = buffer.getvalue()
    if strip_terminator:
        while len(raw) >= 512 and raw[-512:] == b"\0" * 512:
            raw = raw[:-512]
    return gzip.compress(raw, compresslevel=9, mtime=EPOCH)


directories = set()
for target in PAYLOAD:
    parent = Path(target).parent
    while str(parent) != ".":
        directories.add(str(parent))
        parent = parent.parent
data_entries: list[tuple[str, Optional[bytes], int, dict[str, str]]] = [
    (name, None, 0o755, {}) for name in sorted(directories, key=lambda value: (value.count("/"), value))
]
installed_size = 0
for target, (source, mode) in sorted(PAYLOAD.items()):
    body = source.read_bytes()
    installed_size += len(body)
    checksum = hashlib.sha1(body).hexdigest()
    data_entries.append((target, body, mode, {"APK-TOOLS.checksum.SHA1": checksum}))
data_gzip = tar_stream(data_entries)

pkginfo = f"""pkgname = {PKG}
pkgver = {VERSION}-{RELEASE}
pkgdesc = SMS to Feishu forwarding for luci-app-mt5700m, safe status cards, and scheduled SMS.
arch = {ARCH}
size = {installed_size}
datahash = {hashlib.sha256(data_gzip).hexdigest()}
maintainer = Link Camp
depend = busybox
depend = curl
depend = jq
depend = luci-base
depend = rpcd-mod-ucode
depend = luci-app-mt5700m

""".encode()
control_entries = [(".PKGINFO", pkginfo, 0o644, {})]
for target, (source, mode) in CONTROL.items():
    control_entries.append((target, source.read_bytes(), mode, {}))
control_gzip = tar_stream(control_entries, strip_terminator=True)

OUT.mkdir(parents=True, exist_ok=True)
artifact = OUT / f"{PKG}-{VERSION}-r{RELEASE}.apk"
artifact.write_bytes(control_gzip + data_gzip)
artifact.chmod(0o644)
print(artifact)
