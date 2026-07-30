# H5000M SMS → Feishu ordered forwarder

Target: ImmortalWrt 24.10, BusyBox ash, ucode, ubus, jq 1.8.1, curl 8.12.1. No Python or sqlite3. Modem section is `2_1`, Quectel RG520F-EB/RG520-EB. qmodem 3.0.2 exposes `ubus call qmodem_sms list_sms '{"config_section":"2_1"}'`.

Observed list schema: `.conversations[].messages[]` with fields `id`, `timestamp` (epoch seconds), `type` (`received`), `sender`, `content`, `total`, `multipart`, `part_ids`, and sometimes `forwarded`. API order is badly non-chronological: 179 adjacent timestamp inversions among 195 received messages. The vendor `/usr/bin/sms_forwarder_next` iterates API order without sorting. A separate legacy `/usr/bin/smsforward` is currently running and has the Feishu webhook key in UCI `smsforward.settings.feishu_webhook`.

Build a production-quality standalone package in this repo:

- `files/usr/bin/sms-feishu-forwarder`: POSIX/BusyBox ash daemon or loop. Poll qmodem every configurable interval (default 10s).
- `files/etc/init.d/sms-feishu-forwarder`: OpenWrt procd service, respawn, enabled by installer.
- `install.sh`: installs atomically over SSH/local target, backs up any files/config changed, creates state directory, seeds all currently received messages as already seen so historical messages are NEVER replayed, then disables/stops legacy `smsforward` only after successful install. Do not modify or leak the existing webhook secret. Reuse it at runtime via `uci -q get smsforward.settings.feishu_webhook` or copy securely into a mode-0600 config only if necessary. Leave `sms_forwarder_next` alone unless it is actually configured/enabled; avoid duplicate forwarders.
- `uninstall.sh`: restore the legacy service state and backups where practical.
- `tests/run.sh` with fixtures and mocks runnable on Debian and BusyBox-compatible shell.
- README with installation, testing, logs, rollback.

Correctness:
1. Flatten received messages and sort strictly by numeric `timestamp`, then deterministic numeric/string `id` tie-breaker before sending.
2. Strict queue semantics: if the oldest unseen candidate is multipart-incomplete or its send fails, do not send later messages; retry next poll. A message is complete when total<=1 or `part_ids` length >= total.
3. Do not trust `forwarded` as the sole dedupe source. Maintain persistent own state on overlay, using key including timestamp, id, and part IDs/reference so ID reuse does not suppress new SMS. Atomic writes; bounded compaction without losing recent keys.
4. Seed current inbox at first install to prevent the roughly 100 existing unforwarded messages from flooding Feishu.
5. Sequential sends only. After Feishu success, persist seen state first, then optionally call `qmodem_sms mark_forwarded` for id/part_ids. If crash occurs between network success and state write, duplicate-at-least-once is acceptable but state write must be immediate.
6. Feishu card fields: H5000M 短信, 接收时间, 来源号码, 短信内容. Build JSON with jq (not hand escaping). Do not truncate content unless Feishu hard limit requires it; preserve newlines.
7. Validate both curl success/HTTP 2xx and Feishu JSON response `code == 0` (accept documented equivalent success shape if needed). Retry with bounded exponential backoff; never log webhook/token or SMS body. Logs may include message key/id and masked sender only.
8. Secure temp files via umask 077 and cleanup traps; single-instance lock; handle SIGTERM.
9. Configurable UCI `/etc/config/sms-feishu-forwarder`: enabled, modem section, poll interval, settle delay, state path. Webhook should default to reading legacy UCI key internally.
10. Include tests proving: unsorted API input sends chronological order; incomplete oldest blocks later; failed oldest blocks later; seeded historical messages are not sent; multipart completeness; dedupe across restart; Feishu application-error response is failure; JSON/newlines/quotes survive.

Do not use actual SMS contents, phone numbers, webhook keys, or network calls in tests. Do not install to the router; only build and test locally.