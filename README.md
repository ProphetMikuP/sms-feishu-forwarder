# H5000M SMS to Feishu forwarder

Standalone OpenWrt package files for ordered SMS forwarding from qmodem to a Feishu bot.

## Files

- `files/usr/bin/sms-feishu-forwarder`: BusyBox `ash` daemon.
- `files/etc/init.d/sms-feishu-forwarder`: procd service with respawn.
- `files/etc/config/sms-feishu-forwarder`: UCI defaults.
- `install.sh`: local target installer.
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
- seeds the current qmodem inbox into the forwarder's own state, so historical SMS are not replayed;
- enables and starts `sms-feishu-forwarder`;
- stops/disables the legacy `smsforward` service when it was enabled or already running;
- stops/disables the vendor `sms_forwarder` init service only when it was enabled;
- automatically rolls back the installed binary, init script, and config, and restores recorded legacy service state, if seeding, first run, service enable/restart, or service verification fails.

The Feishu webhook is not copied or printed by default. Runtime reads:

```sh
uci -q get smsforward.settings.feishu_webhook
```

## Configuration

```sh
uci set sms-feishu-forwarder.settings.enabled='1'
uci set sms-feishu-forwarder.settings.modem_section='2_1'
uci set sms-feishu-forwarder.settings.poll_interval='10'
uci set sms-feishu-forwarder.settings.settle_delay='0'
uci set sms-feishu-forwarder.settings.state_path='/var/lib/sms-feishu-forwarder/seen.keys'
uci commit sms-feishu-forwarder
/etc/init.d/sms-feishu-forwarder restart
```

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
