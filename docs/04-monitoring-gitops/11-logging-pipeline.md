# 11 · 日志体系：轮转、journald、容器日志、采集与成本

> 日志不是“把 stdout 收走”这么简单：轮转、持久化、容器驱动、采集架构、
> 结构化、采样、脱敏、成本，每一层都能出事故。
>
> 本环境实测：Alloy DaemonSet 6 节点、Loki 5 天、0.6GB/天、2.1M 行/天；
> journald **未持久化**；kubelet 默认 10Mi×5；Harbor 容器用 syslog；
> Alloy **没有 JSON 解析/采样/脱敏**。
>
> 证据：[`assets/logging-pipeline/`](assets/logging-pipeline/README.md)。
> 一句话版本：[15 面试速查 14-logging](../15-interview-cheatsheet/14-logging.md)。

## 0. 本环境日志基线

| 项 | 实测 | 风险 |
|---|---|---|
| 采集 | Alloy DaemonSet **6 Pod**（每节点一个） | 节点级统一采集 |
| 后端 | Loki → S3 `loki-chunks` | 5 天保留 |
| 日量 | **617MB / 2,112,322 行**，约 292B/行 | 5d ≈ 2.87GiB |
| Streams | 75 | 标签基数可控 |
| 标签 | `app/component/container/filename/instance/job/namespace/node_name/pod/service_name/stream` | `filename` 102、`pod` 97，长期会涨 |
| Alloy 解析 | `stage.cri=1`，`stage.json=0` | JSON 未结构化 |
| 采样 | `sampling=0` | 无采样 |
| 脱敏 | `stage.replace=0`、`stage.regex=0` | 无脱敏 |
| journald | `/var/log/journal` **不存在**，无 `Storage/SystemMaxUse` | 重启丢日志 |
| journald 用量 | m01 92.6M / worker 20.4M | 都在 `/run`，易失 |
| logrotate | 主配置 weekly/rotate 4/create；Ubuntu `su root adm` | 基本可用，细节有坑 |
| kubelet | 未设 `containerLogMaxSize/MaxFiles` → 默认 **10Mi×5** | 单容器最多约 50MB |
| 容器日志 | worker 17 个轮转文件，最大约 10.5MB；m01 0 | 轮转在工作 |
| Docker | Harbor nginx/core/registry 用 **syslog**；无 daemon.json | 其他容器默认 json-file，无 max-size 风险 |
| 结构化 | backend JSON（含 trace_id/span_id）；frontend/redis 纯文本 | 混合格式 |

## 1. logrotate：copytruncate vs create

### 1.1 两种模式

```text
create（默认）:
  rename app.log -> app.log.1
  create 新 app.log
  应用仍持有旧 fd -> 继续写 app.log.1
  必须 postrotate 发 HUP/USR1 让应用重新打开

copytruncate:
  copy app.log -> app.log.1
  truncate 原 app.log
  应用 fd 不变 -> 继续写 app.log
  复制与清空之间的新日志可能丢
```

### 1.2 真机实验

本环境用两个持续写日志的进程 + `logrotate -f`：

```text
before:
  copy.log   inode=1071418 size=231
  create.log inode=1071419 size=251

after:
  copy.log   inode=1071418 size=120    # 同 inode，被截断
  copy.log.1 inode=1071422 size=231    # 旧内容
  create.log inode=1071423 size=0      # 新 inode，空
  create.log.1 inode=1071419 size=381  # 旧 inode，写进程还在写
```

结论：

- `copytruncate` 不需要应用配合，但复制/截断窗口会丢日志；
- `create` 更可靠，但**必须让应用重新打开文件**；
- 实验里 `create.log.1` 还在增长，就是因为写进程仍持有旧 fd。

证据：[`evidence/logrotate-lab.txt`](assets/logging-pipeline/evidence/logrotate-lab.txt)。

### 1.3 本环境实际配置

主配置：

```text
m01:    weekly / rotate 4 / create / dateext
Ubuntu: weekly / su root adm / rotate 4 / create
```

实际指令：

| 文件 | 指令 | 说明 |
|---|---|---|
| `nginx` | `create 0640 nginx root` + `postrotate kill -USR1` | 正确：重开日志 |
| `mariadb` | `create 600 mysql mysql` + `su mysql mysql` + `kill -1` | 正确：属主 + 重开 |
| `firewalld` | `copytruncate` + `minsize 1M` | 不重开，接受小丢日志 |
| `chrony` | `nocreate` + `postrotate chronyc cyclelogs` | 应用自己切 |
| `ceph-common` | `su root ceph` + `postrotate kill -1` | 目录属主 ceph |
| `rsyslog` | `postrotate systemctl -s HUP kill rsyslog` | 重开 |

### 1.4 su 权限

`su user group` 解决：

- 日志目录属主不是 root；
- logrotate 以 root 运行，但 `create` 出来的文件属主不对；
- 目录权限导致 rename/create 失败。

本环境 Ubuntu 主配置有 `su root adm`，Ceph 用 `su root ceph`，cloud-init 用 `su root root`。  
m01 主配置没有 `su`，但大部分日志是 root 属主，暂未出问题。

### 1.5 postrotate HUP

`create` 模式必须让应用重开文件：

```text
nginx:   kill -USR1 $(cat /run/nginx.pid)
mariadb: kill -1 $(cat /run/mariadb/mariadb.pid)
rsyslog: systemctl -s HUP kill rsyslog.service
```

不发 HUP 的后果：应用继续写 `app.log.1`，新 `app.log` 永远为空，
日志采集器看不到新日志。

## 2. journald：默认可能是“易失”的

本环境：

```text
/var/log/journal 不存在
Storage/SystemMaxUse 未显式配置
journalctl --disk-usage:
  m01    92.6M
  worker 20.4M
```

说明 journal 实际在 `/run/log/journal`（tmpfs），**重启即丢**。

生产建议：

```ini
# /etc/systemd/journald.conf
[Journal]
Storage=persistent
SystemMaxUse=2G
SystemKeepFree=1G
MaxFileSec=1day
```

```bash
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
journalctl --disk-usage
```

注意：

- `Storage=auto` 只有在 `/var/log/journal` 存在时才持久化；
- 不设 `SystemMaxUse` 可能写爆 `/var`；
- journald 持久化后仍建议外发到 Loki/远端，避免节点故障丢失；
- 容器 stdout 不一定进 journald，取决于 runtime/log driver。

## 3. 容器日志：json-file、kubelet 与 syslog

### 3.1 Docker json-file

Docker 默认 `json-file`，如果没配 `max-size/max-file`：

```json
{"log-driver":"json-file","log-opts":{"max-size":"100m","max-file":"5"}}
```

否则单个容器可以写满节点磁盘，这是高频事故。

本环境 Harbor 202：

```text
/etc/docker/daemon.json 不存在
Docker Logging Driver: json-file（默认）
nginx/core/registry: Type=syslog, tcp://localhost:1514
```

Harbor 容器显式用 syslog 发给 `harbor-log`，所以不是 json-file 无限增长；
但**任何没有显式配置的容器**仍会落到默认 json-file，存在无上限风险。

### 3.2 K8s 节点日志

本环境：

```text
kubelet containerLogMaxSize/MaxFiles 未设置 -> 默认 10Mi x 5
containerd max_container_log_line_size = 16384
worker01: /var/log/pods 176M，17 个轮转文件，最大约 10.5MB
m01:      /var/log/pods 5.7M，0 个轮转文件
```

所以：

- 单容器最多约 50MB（10Mi×5），不会无限增长；
- 但 100+ 容器 × 50MB 仍可能占几十 GB；
- 要监控 `/var/log/pods`、`/var/lib/containerd`、根分区；
- `containerLogMaxSize` 是 kubelet 配置，不是 Docker `max-size`。

### 3.3 节点上还有哪些日志

- `/var/log/syslog` / `/var/log/messages`：rsyslog；
- journald：systemd 服务；
- `/var/log/pods`：kubelet 容器日志；
- `/var/log/containers`：symlink；
- `/var/log/nginx`、`/var/log/ceph`、`/var/log/mariadb`：应用日志；
- Docker `json-file` / syslog：容器运行时。

## 4. 采集架构：DaemonSet vs Sidecar

| 方式 | 优点 | 缺点 | 适用 |
|---|---|---|---|
| DaemonSet | 每节点一个采集器，资源省、统一配置 | 难以做 Pod 级隔离/特殊解析 | 大多数集群 |
| Sidecar | 按 Pod 隔离、多租户、特殊格式 | 副本多、资源开销大、部署复杂 | 多租户、专用日志、合规隔离 |

本环境：

```text
Alloy DaemonSet: 6 Pod，每节点一个
容器: alloy + config-reloader
应用日志 sidecar: 未发现（Ceph CSI 有 log-rotator，但不是采集）
19 个 Pod 是多容器
```

所以是典型 **DaemonSet 节点级采集**，不是 sidecar。

## 5. 结构化、采样、脱敏

### 5.1 结构化 JSON

本环境实际：

```text
compassio-backend:
  {"ts":"...","level":"INFO","logger":"uvicorn.access",
   "msg":"...","trace_id":"...","span_id":"..."}
compassio-frontend:
  10.244.3.57 - - [11/Nov/2026:06:58:19 +0000] "GET / HTTP/1.1" 200 ...
deeptutor-redis:
  1:M 11 Nov 2026 ... Background saving terminated with success
```

所以是**混合格式**：后端 JSON，nginx/Redis 纯文本。

Alloy：

```text
stage.cri=1      # 剥 CRI 包装
stage.json=0     # 没有 JSON 解析
sampling=0       # 没有采样
stage.replace=0  # 没有脱敏
stage.regex=0
stage.drop=1     # 只丢弃超过 120h 的旧日志
```

JSON 日志没有解析成字段，只能靠 Loki 的 `detected_level` 或全文检索；
`trace_id` 在日志里，但没有作为 structured metadata，不能直接按 trace 跳转。

### 5.2 采样

本环境没有采样。高流量日志应按：

- 级别：ERROR 100%，WARN 50%，INFO 10%，DEBUG 0–1%；
- 服务：核心业务高保留，健康检查/静态资源丢弃；
- 租户：大客户全量，普通采样；
- 错误类型：新错误全量，重复错误聚合。

### 5.3 脱敏

本环境没有 `stage.replace`/`stage.regex`，采集侧没有脱敏。

必须在**采集侧或应用侧**处理：

- 手机号、身份证、银行卡；
- Token、Cookie、Authorization；
- 密码、连接串；
- 内部 IP/主机名（按合规要求）。

不要指望“Loki 里再删”——日志一旦落盘/索引就可能被查/备份。

## 6. Loki 标签、保留与成本

### 6.1 标签

实际 labels：

```text
app, component, container, filename, instance, job,
namespace, node_name, pod, service_name, stream
```

基数：

```text
streams=75
namespace=20
pod=97
container=60
filename=102
```

问题：

- `filename` 基本等价于 pod+container，且每个 Pod 重建就变，长期是基数来源；
- `pod` 也是高基数；查询用 `namespace/app/service_name` 更稳；
- `trace_id` 没有做 label（这是对的，否则爆炸）；应做 structured metadata。

### 6.2 保留与成本

```text
617MB/day, 2.1M lines/day, 292B/line
5d retention -> ~2.87GiB raw
Loki S3 bucket: loki-chunks
```

本环境指标 17.9GiB/15d，日志约 3GiB/5d。
所以“日志量是 metrics 的 1000 倍”不是 universally true：
取决于业务流量、debug 级别、健康检查日志和采样。

真正的成本驱动：

- 写入字节数（不是行数）；
- stream/label 基数；
- retention；
- 查询频率/范围；
- 索引/压缩效率。

### 6.3 成本控制

本环境只有 5 天 S3 保留，没有冷热分层。可进一步：

```text
热：7 天，Loki 本地/S3 快查
冷：30–90 天，对象存储 + 压缩，按需查询
```

```text
[ ] 应用默认 INFO，DEBUG 按需
[ ] 丢弃健康检查/静态资源/重复堆栈
[ ] 按级别/服务采样
[ ] 结构化 JSON，减少正则
[ ] 不把 trace_id/user_id/原始 URL 做 label
[ ] 冷热分层：热 7d，冷 30–90d
[ ] 明确保留期与合规要求
[ ] 按团队/namespace 做 ingestion 配额
```

## 7. 一页检查清单

```text
[ ] logrotate: copytruncate 还是 create？create 是否有 postrotate HUP？
[ ] logrotate: 目录属主是否需 su user group？
[ ] journald: /var/log/journal 是否存在？Storage=persistent？
[ ] journald: SystemMaxUse/KeepFree 是否设置？
[ ] Docker: json-file 是否配 max-size/max-file？
[ ] K8s: kubelet containerLogMaxSize/MaxFiles 是否明确？
[ ] /var/log/pods、/var/lib/containerd、根分区是否监控？
[ ] 采集: DaemonSet 还是 sidecar？资源/隔离是否匹配？
[ ] 结构化: JSON 字段是否解析？trace_id 是否可关联？
[ ] 采样: 级别/服务/租户策略？
[ ] 脱敏: 手机号/身份证/Token/密码是否在采集侧处理？
[ ] Loki: label 基数、retention、S3 生命周期是否对齐？
[ ] 成本: 字节/行/stream/查询/保留是否量化？
```

## 8. 面试 30 秒

```text
logrotate：create 更可靠但要 postrotate HUP 重开文件；
           copytruncate 不中断应用但复制/截断窗口会丢日志；
           目录属主不对要 su user group。

journald：默认可能写 /run，重启丢；生产 Storage=persistent +
          SystemMaxUse/KeepFree；还要外发。

容器：Docker json-file 必须 max-size/max-file；
      K8s 还要 kubelet containerLogMaxSize/MaxFiles；
      Harbor 这里用 syslog。

采集：DaemonSet 省资源、统一；sidecar 隔离好但贵。
      优先 JSON、按级别/服务采样、采集侧脱敏。

成本：看字节/stream/retention/查询，不是只看行数；
      冷热分层、索引策略、按需检索。
```
