# 14 · 日志体系 / 可观测性面试题

> 详细证据：[04 日志体系](../04-monitoring-gitops/11-logging-pipeline.md)。

## 1. logrotate `copytruncate` vs `create`

**一句话**：`copytruncate` 不中断应用但复制/清空窗口可能丢日志；`create` 更可靠但必须让应用重开文件。

**本环境**：真机实验 `copytruncate` inode 不变、`create` 旧 inode 被 rename，写进程继续写 `.1`。

## 2. `create` 模式为什么要 `postrotate HUP`

**一句话**：rename 后应用仍持有旧 fd，不发 HUP/USR1 就继续写旧文件，新文件永远空。

**本环境**：nginx `kill -USR1`、mariadb `kill -1`、rsyslog `systemctl -s HUP kill`。

## 3. logrotate `su` 解决什么

**一句话**：日志目录属主不是 root 时，用 `su user group` 让 create/rename 权限正确。

**本环境**：Ubuntu 主配置 `su root adm`；Ceph `su root ceph`。

## 4. journald 默认会丢日志吗

**一句话**：`Storage=auto` 且 `/var/log/journal` 不存在时写 `/run`，重启即丢。

**本环境**：m01/worker 都没有 `/var/log/journal`，92.6M/20.4M 都在易失目录。

## 5. journald 容量怎么控

**一句话**：`SystemMaxUse` + `SystemKeepFree` + `MaxFileSec`，再配合外发。

**本环境**：未显式设置，存在写爆 `/var` 风险。

## 6. Docker json-file 为什么会写满磁盘

**一句话**：默认 json-file 不限制大小，必须配 `max-size`/`max-file`。

**本环境**：Harbor 容器显式用 syslog；但没有 daemon.json 全局限制，其他容器仍有风险。

## 7. K8s 节点日志限制

**一句话**：kubelet `containerLogMaxSize`/`MaxFiles` + 运行时驱动；默认 10Mi×5。

**本环境**：未显式设置，worker 17 个轮转文件、最大约 10.5MB。

## 8. DaemonSet vs Sidecar

**一句话**：DaemonSet 每节点一个、省资源；sidecar 按 Pod 隔离、适合多租户/特殊格式但贵。

**本环境**：Alloy DaemonSet 6 Pod；没有应用日志 sidecar。

## 9. 结构化 JSON

**一句话**：优先 JSON，减少正则；字段可检索/告警；不要把高基数字段做 label。

**本环境**：backend JSON 带 trace_id/span_id；frontend/redis 纯文本；Alloy 没解析 JSON。

## 10. 采样

**一句话**：按级别/服务/租户/错误类型采样；ERROR 100%，DEBUG 0–1%。

**本环境**：Alloy `sampling=0`，没有采样。

## 11. 脱敏

**一句话**：手机号/身份证/Token/密码在应用或采集侧脱敏，不能指望落盘后再删。

**本环境**：Alloy 无 `stage.replace`/`stage.regex`，采集侧没有脱敏。

## 12. Loki 标签怎么选

**一句话**：只放低基数维度（namespace/app/level），`trace_id/user_id/原始 URL` 不放 label。

**本环境**：labels 有 `filename`/`pod` 等高基数；`filename` 102、`pod` 97、streams 75。

## 13. Loki 日志量/成本

**一句话**：成本看字节、stream、retention、查询，不是只看行数。

**本环境**：617MB/天、2.1M 行/天、5d ≈ 2.87GiB；指标 17.9GiB/15d。

## 14. “日志是 metrics 的 1000 倍”对吗

**一句话**：不一定；取决于流量、debug、健康检查、采样。

**本环境**：日志 0.6GB/天，指标 17.9GB/15d，指标反而更大。

## 15. 冷热分层

**一句话**：热数据短保留/快查，冷数据对象存储/压缩/按需查。

**本环境**：Loki S3 5d，无分层；Tempo 也 5d。

## 16. 日志采集架构怎么选

**一句话**：节点级统一用 DaemonSet；多租户/特殊解析/合规隔离用 sidecar。

**本环境**：Alloy DaemonSet + config-reloader，无 sidecar。

## 17. 日志和 trace 怎么关联

**一句话**：日志里打 trace_id/span_id，采集侧提取为 structured metadata，查询时跳 Tempo。

**本环境**：backend JSON 有 trace_id，但没有提取为 label/metadata。

## 18. 日志保留怎么定

**一句话**：按合规/排障/成本分级：错误 30–90d，普通 7–30d，debug 1–7d。

**本环境**：统一 5d，可能不满足等保 6 个月要求。

## 19. 日志安全

**一句话**：采集/传输/存储加密，RBAC/租户隔离，敏感字段脱敏，审计查询。

**本环境**：Loki 单租户 `fake`，无脱敏，RBAC 需补。

## 20. 30 秒总回答

```text
logrotate：create 更可靠但要 postrotate HUP；copytruncate 有丢日志窗口；
           目录属主不对用 su。
journald：默认可能写 /run，重启丢；Storage=persistent + SystemMaxUse。
容器：json-file 必须 max-size/max-file；K8s 还要 kubelet 10Mi×5。
采集：DaemonSet 省资源；sidecar 隔离好但贵；优先 JSON、采样、脱敏。
成本：看字节/stream/retention/查询；冷热分层、索引策略、按需检索。
```

## 一句话总表

| 题 | 一句话 |
|---|---|
| copytruncate | 不中断，复制/清空窗口丢日志 |
| create | 可靠，但要 HUP 重开 |
| su | 目录属主不对时用 |
| postrotate | 发 HUP/USR1 |
| journald | 默认可能易失 |
| SystemMaxUse | 控容量 |
| json-file | 必须 max-size/max-file |
| kubelet | 10Mi×5 默认 |
| DaemonSet | 节点级省资源 |
| Sidecar | Pod 级隔离但贵 |
| JSON | 结构化、少正则 |
| 采样 | 按级别/服务/租户 |
| 脱敏 | 手机号/Token/密码 |
| Loki label | 低基数 |
| 成本 | 字节/stream/retention/查询 |
| 冷热 | 热短冷长 |
| trace_id | structured metadata，不做 label |
