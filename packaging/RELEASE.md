# 短信飞书助手 1.0.0-r22 发布说明

## 构建产物

- `release/luci-app-sms-feishu-forwarder-1.0.0-r22.apk`：MT5700M-CN、apk-tools 3、`aarch64_cortex-a53`
- `release/luci-app-sms-feishu-forwarder_1.0.0-22_all.ipk`：OpenWrt/opkg 兼容包

## r22 变更

- 从已验证的运营商回复中保存并展示“本月通用总量”。
- 按实机短信文本修正运营商尾段“签满”字段，完成已收回复的校准回填。

## r19 变更

- 兼容当前10086实际长短信模板，按完整锚定格式安全解析。
- 将调度时间归一化为模组短信使用的 UTC+8 时间，避免回复时序误判。
- 增加只校准、不重复转发飞书的历史回复 reconciliation 模式。

## r18 变更

- 即使短信校准关闭，也持续显示 MT5700M 本月本地总流量；启用校准后，本地用量仍显示月累计，剩余量仅扣除校准后的增量。

## r17 变更

- 运行时固定依赖 `luci-app-mt5700m`，删除 QModem、串口、旧 AT broker 和旧短信工具的后端与回退路径。
- 收信只调用 `/usr/sbin/mt5700m-read sms-list`，继续在本地完成 PDU 解码、长短信合并和成功后去重。
- 发信只调用 `/usr/sbin/mt5700m-at sms-send-start`，再通过 `/usr/sbin/mt5700m-read sms-send-status` 等待原生任务的明确结果；失败或超时不自动重发。
- 删除 LuCI/UCI 中的后端、串口和 helper 路径配置，避免再次形成多个串口所有者。
- 软件包依赖改为 `luci-app-mt5700m`；首次安装仍默认关闭服务及全部定时短信。
- 新增 MT5700M `/etc/mt5700m/traffic-history` 月流量读取和十进制固定点本地用量估算。
- 新增 `quota_calibration=off|7|14`，默认 `off`；7/14 天任务固定通过原生异步 helper 发送 `10086/CXLL`，发送前持久化 claim，失败或歧义在当前区间不重试，并抑制冲突的普通 `10086/CXLL` 任务。
- 仅接受最新成功 quota 发送后的完整合并 `10086`/`+8610086` 回复，应用校准后再标记 seen；回复原文不落盘、不进日志。
- 原子写入白名单 quota 状态缓存并在 LuCI 展示周期、本地月用量、校准/估算剩余、上次校准和下次到期；multipart 完整性要求精确唯一序号集合。

## Live-contract release gate

本版本保持 MT5700M-only 架构；发布依赖当前目标设备上的 MT5700M v3.0.3 live contract，而不是旧研究快照：

- `/usr/sbin/mt5700m-read sms-list`
- `/usr/sbin/mt5700m-at sms-send-start`
- `/usr/sbin/mt5700m-read sms-send-status`
- `/usr/sbin/mt5700m-manager status-json`

`packaging/release-gate.sh` 检查源码引用和上述文档契约；设置 `MT5700M_LIVE_ROOT` 与 `MT5700M_LIVE_VERSION=3.0.3` 时，还检查注入的目标根目录是否提供两个必需 helper。仓库内 `research/` 仅作历史背景，不是当前目标或发布 gate 的权威来源；缺失 `mt5700m-read` 的旧结论不能否定已验证的当前 live target。

## 本地验证

```sh
sh tests/run.sh
python3 packaging/build-apk.py
sh packaging/build-ipk.sh
python3 packaging/test-apk.py release/luci-app-sms-feishu-forwarder-1.0.0-r22.apk
sh packaging/test-ipk.sh release/luci-app-sms-feishu-forwarder_1.0.0-22_all.ipk
git diff --check
```

部署后还必须在目标机验证 APK 数据库、三个 MT5700M helper、procd 双实例、rpcd 状态、现有收件箱 seed，以及一次经用户授权的真实短信/飞书闭环。