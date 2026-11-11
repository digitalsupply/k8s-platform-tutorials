# 日志体系：本环境实测

对应教程：[`../../11-logging-pipeline.md`](../../11-logging-pipeline.md)。

## 证据

| 文件 | 内容 |
|---|---|
| `evidence/logrotate-lab.txt` | 真机对比 `copytruncate` 与 `create` 的 inode/文件增长 |
| `evidence/logrotate-configs.txt` | m01/Ubuntu 主配置与 nginx/mariadb/ceph/rsyslog 指令 |
| `evidence/journald.txt` | `/var/log/journal` 缺失、无 Storage/SystemMaxUse、disk-usage |
| `evidence/container-logs.txt` | kubelet 默认 10Mi×5、轮转文件、Docker syslog/json-file |
| `evidence/alloy-loki.txt` | Alloy 阶段、DaemonSet、Loki labels/streams、保留 |
| `evidence/cost.txt` | 0.6GB/天、2.1M 行/天、5d、成本驱动 |

## 关键数字

```text
Alloy DaemonSet 6 Pod
Loki 617MB/day / 2,112,322 lines/day / 292B per line
retention 120h（5d），~2.87GiB raw
streams 75；namespace 20；pod 97；filename 102
Alloy: stage.cri=1，stage.json=0，sampling=0，stage.replace=0
journald: /var/log/journal 不存在；m01 92.6M / worker 20.4M
kubelet: 默认 10Mi×5；worker 17 个轮转文件，最大约 10.5MB
Docker: Harbor nginx/core/registry 用 syslog；无 daemon.json
```

## logrotate 实验结论

```text
copytruncate: inode 不变，原文件 truncate；复制与清空窗口可能丢日志
create:       旧 inode rename，新文件空；写进程仍写旧文件，必须 postrotate HUP
```

## 安全说明

- 样本日志只保留非敏感行（nginx access/redis/后端 JSON 摘要）；
- 未修改 logrotate/journald/kubelet/Alloy/Loki 配置；
- 实验使用 `/tmp`，已清理。
