# H5000M SMS to Feishu forwarder

Standalone OpenWrt package files for ordered SMS forwarding through the MT5700M native helpers to a Feishu bot. Feishu cards include live CPE/5G status—including serving-cell PCI/ARFCN, the active MT5700M WAN IPv4, and estimated remaining traffic—and the package also provides managed scheduled SMS and a LuCI WebUI. Signal, cell, and temperature AT queries run only when a new SMS is actually being forwarded.

## Files

- `files/usr/bin/sms-feishu-forwarder`: ordered BusyBox `ash` forwarding daemon with live modem-status cards.
- `files/usr/bin/sms-feishu-scheduler`: persistent, one-attempt-per-slot scheduled SMS daemon.
- `files/usr/lib/sms-feishu-forwarder/quota.sh`: MT5700M monthly traffic counters, fixed-point quota math, calibration state, and safe status cache helpers.
- `files/etc/init.d/sms-feishu-forwarder`: two-instance procd service with respawn.
- `files/etc/config/sms-feishu-forwarder`: UCI forwarding and schedule defaults.
- `files/www/luci-static/resources/view/sms-feishu-forwarder.js`: LuCI management page.
- `files/usr/share/rpcd/ucode/sms-feishu-forwarder.uc`: restricted status and maintenance RPC.
- `install.sh`: atomic target installer and legacy-task migrator.
- `uninstall.sh`: rollback helper.
- `tests/run.sh`: local mock-based test suite.

## Install

Copy this repository to the router and run:

```sh
sh install.sh
```

The installer:

- installs files atomically and backs up changed paths under `/etc/sms-feishu-forwarder/backups`;
- creates `/var/lib/sms-feishu-forwarder`;
- seeds the current MT5700M inbox on first install and once on each router boot, so SMS accumulated while the router was powered off are not replayed; a service restart in the same boot keeps forwarding only newly arrived SMS, while persistent seen state remains intact across upgrades;
- validates candidate files and scheduler prerequisites before stopping an existing custom forwarder;
- migrates the old taskplan `/root/send_10086_sms.sh` job into managed UCI schedules, starts the scheduler inactive, verifies service health, disables only the legacy taskplan SMS job, then activates the scheduler;
- installs/reloads the restricted rpcd backend and LuCI page;
- enables and starts both ordered forwarding and scheduled-SMS procd instances;
- stops/disables the legacy `smsforward` service when it was enabled or already running;
- stops/disables the vendor `sms_forwarder` init service only when it was enabled;
- automatically rolls back managed files, taskplan when it was actually modified, and prior service state if validation or startup fails.

The Feishu webhook is write-only from LuCI. Runtime reads `SMSFF_WEBHOOK` first, then the legacy local secret:

```sh
uci -q get smsforward.settings.feishu_webhook
```

If an older install stored `sms-feishu-forwarder.settings.feishu_webhook`, the installer migrates it into `smsforward.settings.feishu_webhook` through a mode-0600 stdin UCI batch and deletes the old browser-readable option.

## Configuration

```sh
uci set sms-feishu-forwarder.settings.enabled='1'
uci set sms-feishu-forwarder.settings.modem_section='2_1'
uci set sms-feishu-forwarder.settings.poll_interval='10'
uci set sms-feishu-forwarder.settings.settle_delay='0'
uci set sms-feishu-forwarder.settings.attach_status='1'
uci set sms-feishu-forwarder.settings.state_path='/var/lib/sms-feishu-forwarder/seen.keys'
uci commit sms-feishu-forwarder
/etc/init.d/sms-feishu-forwarder restart
```

The default managed schedules are:

- `traffic_hourly`: send `CXLL` to `10086` at minute `00` every hour, preserving the existing taskplan behavior;
- `balance_daily`: send `CXYE` to `10086` daily at `09:05`.

Both are editable and can be run immediately from LuCI. On MT5700M, scheduled sends use the native asynchronous `sms-send-start`/`sms-send-status` helpers; no direct serial or legacy modem transport is configured.

### MT5700M traffic quota calibration

Quota calibration is disabled by default on fresh installs and upgrades. Set the UCI option to `7` or `14` to claim one native `10086`/`CXLL` request per interval:

```sh
uci set sms-feishu-forwarder.settings.quota_calibration='7'   # or 14
uci commit sms-feishu-forwarder
/etc/init.d/sms-feishu-forwarder restart
```

The scheduler claims and persists the interval before sending through the MT5700M asynchronous job helper. A failed or ambiguous attempt is not retried until the next interval, and generic/manual `10086`/`CXLL` schedules are suppressed while quota owns the interval. Replies are accepted only from normalized `10086`/`+8610086` after the latest successful quota send and only when the complete merged SMS matches `本月国内通用流量共100GB,剩余12.34GB`; the raw body is never persisted or logged.

Local usage is read from `/etc/mt5700m/traffic-history` rows in the form `month eth2 YYYY-MM RX TX`. The displayed estimate uses decimal GB and fixed-point centi-GB arithmetic: carrier remaining minus the positive RX+TX delta from the calibration baseline. A same-month counter decrease is `未知`; a month rollover is `stale` until the next calibration. The allowlisted quota status is atomically cached at `/var/lib/sms-feishu-forwarder/quota-status.json` and shown in LuCI with interval, local usage, carrier monthly total, calibrated/estimated remaining, last calibration, and next due.

## LuCI WebUI

Open **Modem → 短信飞书助手** (menu path `admin/modem/sms-feishu`). The page provides live status, forwarding settings, write-only Webhook update, schedule management, immediate send, filtered logs, restart, test card, and dedupe-baseline maintenance.

The Webhook field intentionally loads blank: leaving it blank preserves the current device-local value and never returns it to the browser. LuCI status uses the package RPC status object only; it does not call modem status RPCs directly, and IMEI/IMSI/ICCID are not included in the browser status payload.

## Logs

```sh
logread -e sms-feishu-forwarder
```

Logs include message keys, ids, and masked senders. They do not include webhook tokens or SMS bodies.

## Testing

Run locally:

```sh
sh tests/run.sh
```

The tests use fixture JSON and mocked `ubus`, `curl`, `uci`, and `logger`; they do not contact the router or any network.

## Rollback

```sh
sh uninstall.sh
```

The uninstaller removes the new service and binary, restores the latest backed-up config where present, and attempts to restore recorded `smsforward` and `sms_forwarder` service state. Forwarder state and backup directories are intentionally left intact.
