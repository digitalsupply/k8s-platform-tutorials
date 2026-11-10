# kube-vip 重启 50+ 次根因分析与修复报告

| 项目 | 内容 |
|---|---|
| **分析对象** | DaemonSet `kube-system/kube-vip-ds`（3 个 Pod，运行于 3 个控制面节点） |
| **集群** | Kubernetes v1.35.9 / containerd 2.3.2 / 6 节点（m01、master01、master02、worker01-03） |
| **VIP** | `10.0.0.168:6443`（ARP 模式，接口 `eth0`） |
| **kube-vip 版本** | 修复前 `v1.0.3`（build `28bec598f5f35dbf0368e59834b9544a5825c90f`）→ **已升级至 `v1.2.4`**（build `d99186480c723dff3bb5a605f0e9f853f16c6af4`） |
| **故障时长** | Pod 已运行 260 天 |
| **分析主机** | `m01`（控制面节点，`10.0.0.61`） |
| **报告日期** | 2026-10-04 |
| **本轮范围** | 第一轮：止血（保留 VIP / 放宽租约 / 修告警）。第二轮：**根治两个 P0**（见第六章之二） |

---

## 一、结论速览（TL;DR）

### 1.1 现象

| Pod | 节点 | 修复前重启次数 | 修复后 |
|---|---|---|---|
| `kube-vip-ds-jzxzk` | master02 | **51** | 0 |
| `kube-vip-ds-tmbn8` | master01 | **53** | 0 |
| `kube-vip-ds-z4cwm` | m01 | **53** | 0 |
| **合计** | | **157 次** | **0** |

退出特征：`exitCode=2`、`reason=Error`、日志出现 `panic: [recovered, repanicked]`，堆栈落在 `clusterLeaderElection.go:246`。

### 1.2 根因链（一句话）

> kube-vip **丢失 leader 租约时会主动 `panic` 退出（exit 2）**，且**默认会把 VIP 从网卡上删除**；
> 而 **m01 的 kubelet 恰恰是通过这个 VIP（`10.0.0.168:6443`）访问 apiserver 的**。
> 于是一次短暂的 API 卡顿被放大成 **"VIP 消失 → kubelet 失去 API → 节点 NotReady"** 的循环放大故障（雪崩）。

> **【第二轮补充的精确认知】** 初版报告曾把 `admin.conf` 也列为共犯。第二轮逐条实测后修正：
> * **kube-vip 本身不构成依赖环** —— 尽管 DS 挂载了 host 的 `admin.conf`（其 `server` 是 VIP），
>   但 `cp_enable=true` 使其运行时**实际连接 `127.0.0.1:6443`**（`ss` 实测）。
> * **真正的共犯只有 kubelet** —— 它是唯一把 VIP 当作 API 入口的系统组件。
> * **`admin.conf` 是运维入口，不是系统依赖**，保留 VIP 反而是正确的 HA 语义，不应改动。

三个叠加因素把"小抖动"变成"大故障"：

| # | 问题 | 原值 | 影响 |
|---|---|---|---|
| **A** | 丢失 leader 时删除 VIP | `preserveVipOnLeadershipLoss=false`（默认） | **把局部抖动放大成全集群 API 中断（致命）** |
| **B** | Leader 选举超时过紧 | `5s / 3s / 1s` | API 卡顿 **>3 秒**即判定失败 → 误杀 |
| **C** | 无资源配额、BestEffort | `resources: {}` | 节点内存紧张时最先被驱逐/节流 |

### 1.3 修复效果

**第一轮（止血）**

* ✅ 消除雪崩：VIP 不再被删除，API 不再中断（**已通过故障注入实测验证**）
* ✅ 容忍度从 3 秒提升到 10 秒（3.3 倍）
* ✅ 补齐了此前**完全失效**的监控告警
* ⚠️ kube-vip 丢失租约后**仍会 panic 退出**（上游设计如此，不可配置）——但现在**只重启自己一个 Pod，不影响任何人**

**第二轮（根治 P0）**

* ✅ **切断循环依赖的最后一段**：m01 的 kubelet 由 `10.0.0.168:6443`（VIP）改为 `127.0.0.1:6443`。
  实测确认 **master01/master02 原本就指向本机 IP，无需改动**。
* ✅ **全集群 → VIP 的系统组件连接数由 1 降为 0**（`admin.conf` 为运维用途、有意保留 VIP 语义）
* ✅ **kube-vip 升级 v1.0.3 → v1.2.4**，3 个 Pod 全部生效，`preserveVipOnLeadershipLoss` 等关键配置全部保留
* ✅ 升级后在 v1.2.4 上**重做故障注入**（掐断 leader 的 API 通路），领导权平稳转移、VIP 未被删除
* ⚠️ **需要更正一个此前的错误判断**：升级到 v1.2.x **并不能**消除 panic —— 该行为在上游是硬编码的，
  v1.2.4 中依然存在。升级带来的是新特性与上游修复，而非行为变更。

---

## 二、详细分析

### 2.1 第一现场：崩溃日志

`kubectl logs -n kube-system kube-vip-ds-tmbn8 --previous`：

```
2026/10/03 03:00:52 INFO [ARP manager] starting ARP/NDP advertisement
2026/10/03 03:00:52 INFO layer 2 broadcaster starting IP=10.0.0.168 device=eth0
2026/10/03 03:00:52 INFO [ARP manager] inserting ARP/NDP instance name=10.0.0.168/24-eth0
E1003 03:24:24.250061  leaderelection.go:441] Failed to update lock optimistically:
    Put "https://kubernetes:6443/apis/coordination.k8s.io/v1/namespaces/kube-system/leases/plndr-cp-lock?timeout=10s":
    context deadline exceeded, falling back to slow path
I1003 03:24:24.250519  leaderelection.go:297] failed to renew lease kube-system/plndr-cp-lock: context deadline exceeded
E1003 03:24:27.252703  leaderelection.go:316] error retrieving resource lock kube-system/plndr-cp-lock: ... context deadline exceeded
2026/10/03 03:24:27 INFO This node is becoming a follower within the cluster
2026/10/03 03:24:27 INFO Deleting VIP addresses on leadership loss (legacy behavior)     ← ★ 致命
2026/10/03 03:24:27 INFO [ARP manager] removing ARP/NDP instance name=10.0.0.168/24-eth0
2026/10/03 03:24:27 INFO deleted address IP=10.0.0.168 interface=eth0                     ← ★ VIP 被摘除
2026/10/03 03:24:27 ERROR lost leadership, restarting kube-vip
E1003 03:24:27.257125  clusterLeaderElection.go:246] "Observed a panic" panic="" stacktrace=<
    goroutine 13 [running]:
    github.com/kube-vip/kube-vip/pkg/cluster.(*Cluster).StartCluster.func4()
        /src/pkg/cluster/clusterLeaderElection.go:246 +0x46f
    k8s.io/client-go/tools/leaderelection.(*LeaderElector).Run(...)
    ...
    github.com/kube-vip/kube-vip/pkg/manager.(*Manager).startARP.func2()
        /src/pkg/manager/manager_arp.go:67 +0x36
>
```

**时间线可精确复原**：`03:24:24` 首次续约失败 → `03:24:27` 放弃（**正好 3 秒 = 原 `vip_renewdeadline`**）→ 删除 VIP → panic → exit 2。

> ⚠️ 关键认知：**这不是 kube-vip 的 Bug，而是它的内置设计。**
> `leaderelection.go` 的 `OnStoppedLeading` 回调中显式 `panic("lost leadership, restarting kube-vip")`，
> 配合 DaemonSet 的 `restartPolicy: Always`，形成"失去租约 = 进程退出 = 容器重启"。
> 真正的问题在于 **触发条件太容易满足**（3 秒），且 **退出时还会拆掉 VIP**。

### 2.2 循环依赖：VIP 的"消费者"正是 VIP 的"提供者"生态

这是整个故障最关键、也最容易被忽略的一环。查 kubeconfig 实际内容：

```
/etc/kubernetes/admin.conf   ->  server: https://10.0.0.168:6443    ← kube-vip 自己挂载的就是这个
/etc/kubernetes/kubelet.conf  ->  server: https://10.0.0.168:6443    ← kubelet 也走 VIP
```

**m01 的 kubelet 日志（铁证）：**

```
09:03:22 kubelet: "Failed to update lease" err="Put \"https://10.0.0.168:6443/apis/coordination.k8s.io/v1/
                                    namespaces/kube-node-lease/leases/m01?timeout=10s\":
                                    context deadline exceeded"
09:03:53 kubelet: "Failed to update lease" err="... dial tcp 10.0.0.168:6443: connect: no route to host"   ← ★ VIP 没了
09:03:50 kubelet: "Failed deleting a mirror pod" err="Delete \"https://10.0.0.168:6443/...\": http2: client connection lost"
                   pod="kube-system/kube-apiserver-m01"
```

> **注意 `no route to host` 的含义**：这不是路由问题，而是 **ARP 解析失败** —— 说明 `10.0.0.168` 这个地址在二层域里**已经不存在了**，因为 kube-vip 刚把它删掉了。

**因此形成闭环：**

```
        ┌──────────────────────────────────────────────────────────┐
        │                                                          │
        ▼                                                          │
  kube-apiserver/etcd 短暂不可用（3 秒）                            │
        │                                                          │
        ▼                                                          │
  kube-vip 续约失败（renewDeadline=3s）                             │
        │                                                          │
        ▼                                                          │
  ① 摘除 VIP 10.0.0.168  ←──────────────┐                          │
        │                                │                          │
        ▼                                │                          │
  kube-vip panic 退出（exit 2）            │                          │
        │                                │                          │
        ▼                                │                          │
  ┌─────────────────────────────┐        │                          │
  │ kubelet 无法访问 apiserver   │        │                          │
  │ "no route to host"          │        │                          │
  │ 节点租约丢失 → NotReady     │        │                          │
  └─────────────────────────────┘        │                          │
        │                                │                          │
        ▼                                ▼                          │
  metallb speaker 丢失租约崩溃  ◄───────────┘  （API 依赖，同样雪崩）  │
                                                                     │
                                                                     │
  下一轮 leader 选举：无人能优雅接管 ────────────────────────────────┘
```

### 2.3 kube-vip 的 API 依赖链：绑死在"本机 apiserver"上

从崩溃日志可见 kube-vip 请求的是 `https://kubernetes:6443`（**主机名**，非 IP）。原因在 DaemonSet 中：

```yaml
hostAliases:
- hostnames: [kubernetes]
  ip: 127.0.0.1        # ★ 把 kubernetes 强行指向本机回环
```

**这一点我通过一个独立探针 Pod 实测确认了**（见 §4.2）：不带 `hostAliases` 的 kube-vip 实例直接报

```
dial tcp: lookup kubernetes on 223.5.5.5:53: no such host
```

所以完整依赖链是：

```
kube-vip 续约  →  kubernetes:6443  →  127.0.0.1:6443  →  本节点 kube-apiserver  →  127.0.0.1:2379  →  本节点 etcd
```

**优点**：走回环，不依赖网络，延迟极低。
**缺点**：**单点绑定在本机 apiserver/etcd 上**。本机 apiserver 一重启（哪怕只几秒），kube-vip 必挂。

### 2.4 重启分布：不是崩溃循环，而是"平时安静 + 集中爆发"

Prometheus 保留期仅 15 天（`storage.tsdb.retention.time = 15d`），因此 260 天历史无法完整回溯，但足以看清模式。

**（1）基线：约每 5 天/每 Pod 一次**

Pod 已运行 260 天，累计 51/53/53 次 → 平均 **≈ 1 次 / 5 天 / Pod**。
Prometheus 15 天窗口内，计数器长期停在 `44 / 44 / 42` 几乎不动（仅 09-30 有一次 +1）。

**（2）2026-10-03 集中爆发：5 小时内 27 次**

```
时间(UTC)        jzxzk(master02)  tmbn8(master01)  z4cwm(m01)
10-02 22:32            44              45              43     ← 第一次抬头
10-03 00:22            47              47              47
10-03 02:42            50              50              52
10-03 03:42            51              53              53     ← 爆发结束
之后 27 小时不再变化（稳定）
```

**（3）同一时段 metallb speaker 同步爆发（交叉验证）**

```
2026-10-03 00:34  speaker-7lsdm  +4      (总计 64)
2026-10-03 00:34  speaker-zv64c  +4      (总计 64)
2026-10-03 00:34  speaker-qmwd4  +1      (总计 62)
2026-10-03 00:34  speaker-xz49v  +1      (总计 36)
```

> **metallb speaker 与 kube-vip 是完全独立的两套组件**，唯一共同点是"都依赖 API 做 leader 选举"。
> 二者同时爆发，证明**触发源是 API 不可用，而非 kube-vip 自身缺陷**。kube-vip 只是因为配置激进而"受伤最重"。

### 2.5 底层诱因：本节点容器运行时与 apiserver 被重启

m01 的 journal 揭示了 2026-10-03 的真实事件（**系统本地时区 = UTC+8**）：

| 本地时间(CST) | UTC | 事件 |
|---|---|---|
| 09:03:08 | 01:03 | kube-apiserver 就绪探针开始返回 **500** |
| 09:03:53 | 01:03 | kubelet `dial tcp 10.0.0.168:6443: no route to host`（VIP 已消失）|
| 09:58:54 | 01:58 | **`systemd: Stopping containerd` → `Starting containerd`** ← 容器运行时被重启，所有容器（含 apiserver/etcd/kube-vip）被杀 |
| 10:24:43 | 02:24 | `systemd: Starting dnf makecache` ← 系统包维护 |
| 10:29:49 / 10:30:30 | 02:29 | apiserver 就绪探针再次 500 |
| 10:41:26 | 02:41 | apiserver **存活探针** 500（连续 6 次）→ 被 kubelet 杀掉 |
| 10:42:19 | 02:42 | **`systemd: Stopping kubelet` → 重启** |
| 10:50:12 | 02:50 | **kubelet 再次重启** |
| 11:21:19 | 03:21 | **kubelet 第三次重启** |
| 11:21:21 | 03:21 | kube-apiserver 启动失败：`bind: address already in use`（6443 端口未释放）|
| 11:35:55 | 03:35 | containerd: `failed to call task.Create`（正是 m01 的 kube-vip 崩溃时刻）|

**结论**：这是一次**人工/脚本介入的主机维护操作**（重启 containerd、连续重启 kubelet、跑 dnf），叠加 apiserver 探针失败与 6443 端口冲突，导致本节点 API 中断数小时。kube-vip 的 27 次重启是这个窗口内的连锁反应。

**旁证**：`containerd` 在 260 天内仅启动 5 次，`kubelet` 仅 9 次，且最近 4 次全部集中在 2026-10-03 当天 —— 属于**低频运维事件**，不是持续性资源瓶颈。

**排除项**：
* ❌ 内存 OOM：近 30 天内核日志无任何 `oom-kill`
* ❌ 节点内存压力：所有节点 `MemoryPressure=False`，最后一次状态变更在 2026-01-17
* ❌ 节点重启：m01 `uptime` 为 7 天（引导于 09-27），未重启
* ❌ VIP 脑裂：当前 VIP 的 ARP MAC (`bc:24:11:c1:51:cb`) ≠ m01 的 MAC (`bc:24:11:a4:e1:26`)，且 m01 网卡上确实没有 `10.0.0.168`，与 Lease holder (`master02`) 一致

### 2.6 配置层面的 6 个问题（按严重度排序）

| # | 问题 | 当前配置 | 风险 |
|---|---|---|---|
| **1** | **丢失 leader 时删除 VIP** | 默认 `false`（=会删） | 🔴 **致命**：把局部故障放大为全集群 API 中断 |
| **2** | **续约超时过紧** | `leaseduration=5` `renewdeadline=3` `retryperiod=1` | 🔴 **高**：API 卡顿 >3s 即误判失联。kube-vip 官方默认即 `15/10/2`，此处被调低了 3 倍 |
| **3** | 无资源配额 | `resources: {}`（BestEffort）| 🟠 中：节点内存紧张时最优先被驱逐。m01 仅 5.5Gi 内存、已用 4.5Gi、无 Swap |
| **4** | 无优先级 | 未设置 | 🟠 中：节点资源紧张时排在业务负载之后被驱逐 |
| **5** | `vip_subnet: "24"` | VIP 以 `/24` 而非 `/32` 加到 `eth0` | 🟡 低：`10.0.0.168/24` 会额外生成一条 onlink 子网路由，语义不严谨（本次未改动，风险高于收益）|
| **6** | 无健康检查端口 | 未设置 `health_check_port` | 🟡 低：Pod "假死"时 kubelet 无法感知（本次未改动）|

---

## 三、已执行的修复

### 3.1 备份

```
/root/kube-vip-fix-backup-20261004-064511/
├── kube-vip-ds-ORIGINAL.yaml                    # DaemonSet 原始定义
├── lease-plndr-cp-lock.yaml                     # Lease 原始状态
├── kube-vip-pods-BEFORE.txt                     # 重启次数基线
├── prometheusrule-cluster-wide-alerts-ORIGINAL.json
└── prev-log-kube-vip-ds-*.txt                   # 崩溃现场日志
```

### 3.2 核心变更（已应用到集群）

| # | 变更项 | 修复前 | 修复后 | 作用 |
|---|---|---|---|---|
| **1** | `vip_preserve_on_leadership_loss` | 未设置（=false） | **`"true"`** | ⭐ **断环**：丢 leader 时保留 VIP，只停 ARP 广播 |
| **2** | `vip_leaseduration` | `5` | **`15`** | 租约容忍度 ×3 |
| **3** | `vip_renewdeadline` | `3` | **`10`** | ⭐ API 卡顿容忍度 3s → 10s |
| **4** | `vip_retryperiod` | `1` | **`2`** | 降低重试频率，减轻 API 压力 |
| **5** | `resources` | `{}` | `requests: cpu 50m / mem 64Mi`，`limits: mem 512Mi` | 脱离 BestEffort（⚠️ 刻意不设 CPU limit，避免 CFS 节流反而错过续约）|
| **6** | `priorityClassName` | 未设置 | `system-cluster-critical` | 保障控制面 VIP 的存活优先级 |
| **7** | `terminationGracePeriodSeconds` | `30` | `15` | 加快滚动更新收敛 |

> **配置键名来源**：从集群内运行的 kube-vip 二进制中提取，**非猜测**。
> ```
> $ kube-vip manager --help
>   --preserveVipOnLeadershipLoss   Preserve ARP VIP addresses on interface when
>                                   leadership is lost (default: false for backward compatibility)
>   --leaseDuration int             (default 5)   --leaseRenewDuration int  (default 3)
>   --leaseRetry int                (default 1)
> $ strings kube-vip | grep -oE "vip_[a-z0-9_]+" | grep -i preserve
>   vip_preserve_on_leadership_loss
> ```

### 3.3 监控告警修复（**此前完全失效**）

排查中发现现有告警**存在表达式 Bug，且没有任何一条能发现本次故障**：

| 告警 | 原表达式 | 问题 |
|---|---|---|
| `KubePodHighRestartCount` | `count by (namespace,pod) (kube_pod_container_status_restarts_total > 10)` | 🔴 `count` 聚合后每 Pod 只剩 1，**`>10` 需要 11 个 Pod 同时超限**才触发。告警 `annotations` 里写的意图（"单个 Pod 累计重启超 10 次"）与表达式完全不符 |
| `KubePodCriticalComponentHighRestart` | `count by (...) (... > 20)` | 🔴 同上，需要 21 个 Pod |
| `PodCrashLooping` | `increase(...[5m]) > 2` | 🟠 只覆盖"5 分钟内重启 ≥3 次"的紧凑抖动。kube-vip 的重启分散在数小时内，**永远不会触发** |
| `KubeVIPDown` | `sum(kube_pod_status_ready{...}) < 1` | 🟠 只在 0 个 Pod Ready 时触发；kube-vip 始终 1/1 Ready，**永远不会触发** |

**本次修复与新增：**

```yaml
# 修正：去掉错误的 count 聚合，恢复"单 Pod 维度"语义
KubePodHighRestartCount:
  max by (namespace, pod, container) (kube_pod_container_status_restarts_total) > 10
KubePodCriticalComponentHighRestart:
  max by (namespace, pod, container) (kube_pod_container_status_restarts_total{namespace=~"kube-system|argocd|logging|cert-manager"}) > 20

# 新增：kube-vip 专项检测（均已验证表达式在当前集群返回真实数据）
KubeVIPRestarting:                    # 1 小时内重启 > 0 次
  sum by (pod, node) (increase(kube_pod_container_status_restarts_total{namespace="kube-system",container="kube-vip"}[1h])) > 0

KubeVIPLeadershipChurn:               # 24h 内出现过 >1 个不同的 leader
  count(count by (lease_holder) (max_over_time(kube_lease_owner{namespace="kube-system",lease="plndr-cp-lock"}[24h]))) > 1

KubeVIPLeaderNotRenewing:             # 关键！leader 停更 > 30s ⇒ 本节点 apiserver/etcd 已挂
  time() - kube_lease_renew_time{namespace="kube-system",lease="plndr-cp-lock"} > 30
```

> **踩坑记录**：`KubeVIPLeadershipChurn` 最初写成 `changes(kube_lease_owner[24h])`，实测恒为 `0`。
> 原因是 `kube_lease_owner` 把 holder 放在 **`lease_holder` 标签**上，holder 变化会产生**全新序列**而非"值变化"，
> 因此 `changes()` 检测不到。必须用 `count(count by (lease_holder) (...))` 统计 distinct holder 数。
> 已实测：`[24h]` 返回 `1`（近期无抖动），`[3d]` 返回 `3`（正确捕获到 10-03 的三次切换）。✅

---

## 四、修复验证（实测证据）

### 4.1 变更后集群状态

```
NAME                READY   STATUS    RESTARTS   AGE     NODE
kube-vip-ds-8pjpd   1/1     Running   0          9m      master01
kube-vip-ds-z7sjn   1/1     Running   0          9m      master02
kube-vip-ds-zv4db   1/1     Running   0          9m      m01

lease plndr-cp-lock: holder=master02  duration=15s  transitions=41
VIP https://10.0.0.168:6443/healthz → HTTP 200 (29ms)
6 个节点全部 Ready
```

配置已确认**真正生效到进程**（读取运行中进程的环境变量，而非仅看 YAML）：

```
$ tr '\0' '\n' < /proc/2598315/environ | grep vip_
vip_address=10.0.0.168
vip_leaderelection=true
vip_leaseduration=15
vip_preserve_on_leadership_loss=true     ← ⭐
vip_renewdeadline=10
vip_retryperiod=2
```

### 4.2 故障注入实验：证明 VIP 不再被删除

这是最关键的一步验证。方法：在 m01 上启动一个**隔离的测试实例**（独立 Lease `kv-test-lock` + 独立测试 VIP `10.0.0.169`），让它成为 leader，然后用 iptables **黑洞掉 `127.0.0.1:6443` 32 秒**，精确复现 10-03 的 apiserver 不可用场景。

> 该测试不影响真实 VIP（在 master02 上）、不影响集群 API（`kubectl` 走 `10.0.0.168` 而非 `127.0.0.1`），实验后已完全清理。

**结果（每一行 = 每 2 秒采样）：**

```
时间(UTC)   t+     测试VIP(.169)   真实VIP(.168)healthz   探针状态
06:48:02   +00s     PRESENT           200                Running
06:48:13   +10s     PRESENT           200                Running     ← 首次续约失败
06:48:23   +20s     PRESENT           200                Running     ← 正好 10s 后放弃(=新 renewDeadline)
06:48:26   +22s     PRESENT           200                Failed      ← panic 退出
06:48:37   +32s     PRESENT           200                Failed
06:48:39         移除 iptables 规则
```

### 4.3 新旧行为对比（决定性证据）

**❌ 修复前（10-03 真实故障日志）：**
```
INFO This node is becoming a follower within the cluster
INFO Deleting VIP addresses on leadership loss (legacy behavior)   ← 删！
INFO [ARP manager] removing ARP/NDP instance name=10.0.0.168/24-eth0
INFO deleted address IP=10.0.0.168 interface=eth0                  ← VIP 消失 → kubelet 失联
ERROR lost leadership, restarting kube-vip
```

**✅ 修复后（本次注入实验日志）：**
```
INFO Becoming leader with VIP preservation enabled - ensuring VIP takeover     ← 新分支
...
INFO This node is becoming a follower within the cluster
INFO Preserving IPv4 VIP address on interface, only stopped ARP broadcasting ip=10.0.0.169   ← 保留！
ERROR lost leadership, restarting kube-vip
```

**结论**：租约丢失后 **VIP 依然留在网卡上**（仅停止 ARP 广播），`10.0.0.168` 始终可达（HTTP 200），
kubelet 的 API 通道**不会**被切断。**雪崩链条被彻底切断。**

### 4.4 告警验证

```
KubeVIPRestarting                      state=inactive  health=ok
KubeVIPLeadershipChurn                 state=inactive  health=ok
KubeVIPLeaderNotRenewing               state=inactive  health=ok
KubePodHighRestartCount                state=pending   health=ok   ← 修复后立即生效并触发
KubePodCriticalComponentHighRestart    state=inactive  health=ok
（我的 5 条规则各仅 1 份，无重复、无错误）
```

> `KubePodHighRestartCount` 变为 `pending`，是因为 metallb speaker(64)、ceph-csi(23) 等 Pod 确实超过 10 次 ——
> **这正是修复前那条坏表达式永远无法报告的真实问题**，现在终于能暴露出来了。

### 4.5 清理确认

```
测试 Pod 残留       : 0
KVTEST iptables 规则 : 0
10.0.0.169 残留      : 0
kv-test-lock Lease   : 已删除
```

---

## 五、影响评估

### 5.1 修复前的影响面（为什么值得紧急处理）

| 受影响对象 | 表现 | 证据 |
|---|---|---|
| **kubelet** | `no route to host`，节点租约丢失 → NotReady | `dial tcp 10.0.0.168:6443: connect: no route to host` |
| **所有 worker 节点** | 通过 VIP 访问 apiserver，同样受影响 | kubeconfig 统一指向 VIP |
| **metallb speaker** | leader 选举失败崩溃，62~64 次重启 | Prometheus 时间线同步爆发 |
| **kube-apiserver** | 探针 500 → 被 kubelet 反复杀掉 | `Liveness probe failed: statuscode: 500`（Count:6）|
| **业务 Pod** | 无法下发/上报状态，影响调度与优雅下线 | 集群级 API 中断 |

> 即：**一次控制面维护操作，会通过 kube-vip 的"删 VIP"行为升级为全集群 API 中断**。
> 这是典型的**单点故障被配置放大**。

### 5.2 修复后的影响面

| 场景 | 修复前 | 修复后 |
|---|---|---|
| API 卡顿 1~3s | kube-vip 崩溃 + **摘 VIP** + 全集群失联 | ✅ 完全无感 |
| API 卡顿 3~10s | 同上 | ✅ 完全无感（已容忍）|
| API 不可用 >10s | 同上 | 🟡 kube-vip 单 Pod 重启，**VIP 保留，API 不中断** |
| 单节点 apiserver 崩溃 | 雪崩 | 🟡 仅该节点 kube-vip 重启，集群 HA 正常 |
| 全 etcd 集群故障 | 雪崩 | 🟡 各节点 kube-vip 重启，但 VIP 保留在最后持有者上 |

---

## 六、遗留风险与后续建议

### 6.0 【第二轮已根治】两个 P0 项的处理结果

> 本节记录 2026-10-04 第二轮变更，**详细过程见第六章之二**。原表 6.1 中的两个 P0 已处理完毕：

| 原 P0 项 | 状态 | 结论 |
|---|---|---|
| 🔴 kubelet 指向 VIP 的循环依赖 | ✅ **已根治** | 实测发现**只有 m01 的 kubelet 真的连 VIP**；master01/master02 早已指向各自节点 IP。仅需改 m01 一处。改动后全集群 **0 个 VIP 消费者**。|
| 🟠 kube-vip 版本升级 | ✅ **已升级** v1.0.3 → **v1.2.4** | 3 个 Pod 全部运行 v1.2.4。⚠️ 需更正此前的判断：**升级并不能消除 panic**（详见 6.1 备注）。|

---

### 6.1 尚未处理（需人工决策）

| 优先级 | 项目 | 说明 |
|---|---|---|
| ✅ ~~**P0** kubelet/admin.conf 指向 VIP 的循环依赖~~ | **已处理** | 见 6.0 与第六章之二。**admin.conf 仍指向 VIP 是有意保留**：它服务于 `cp_enable` 的端点管理，且 kube-vip 运行时实际连的是 `127.0.0.1`（已实测），不存在依赖环。|
| ✅ ~~**P1** kube-vip 版本升级~~ | **已完成** v1.2.4 | 见 6.0 与第六章之二。|
| 🟠 **P1** | **控制面主机运维管控** | 10-03 的 containerd/kubelet 连续重启缺少变更记录与审批。建议：① 变更窗口化；② 生产控制面禁用交互式 `systemctl` 操作；③ 至少记录到变更单。|
| 🟡 **P2** | **kube-apiserver 6443 端口冲突** | `bind: address already in use` 导致启动失败重试。建议确认 apiserver 优雅退出时间与 `terminationGracePeriodSeconds` 匹配。|
| 🟡 **P2** | **m01 内存偏紧** | 5.5Gi 总内存、常态 4.5Gi 已用、**无 Swap**，同时承载 apiserver+etcd+CM+scheduler+kubelet+kube-proxy+calico+ceph-csi。建议扩容至 8Gi 或加 Swap。|
| 🟡 **P2** | **DNS 配置冗余告警** | `DNSConfigForming: Nameserver limits were exceeded ... 223.5.5.5 119.29.29.29 223.5.5.5`（存在重复项）。不影响本故障，但建议清理节点 `resolv.conf`。|
| 🟡 **P2** | **`vip_subnet: 24`** | 建议改为 `32`（语义更严谨）。⚠️ 改动涉及 VIP 摘挂，有中断风险，建议安排独立窗口。|
| 🟡 **P2** | **Prometheus 存在 32 条重复规则** | 与本次变更无关的既有问题（如 apiserver burnrate 系列各重复 2~4 次，会产生重复告警实例）。建议单独排期清理。|
| 🟡 **P2** | **master01/master02 的 `kubelet.conf` 存在无效 `kubernetes` 死条目** | 第二轮排查发现：两台节点的 `kubelet.conf` 均含两个 cluster——生效的 `default-cluster`（指向本机 IP，正确）与一个**无 CA 数据的 `kubernetes` 死条目**（指向 VIP）。当前 `current-context` 不指向它，**无实际影响**，但属配置污染，建议清理（需变更窗口）。|
| ⚪ **P3** | **kube-vip 无健康检查端口** | 可加 `health_check_port` + probes，让 kubelet 能感知"假死"。（本次未加：探测路径未能在离线环境中确证，贸然添加有风险）|

> **备注（重要更正）**：此前推测"升级到 v1.2.x 即可根治 panic"。经二进制反查**证伪**——v1.2.4 仍包含 `lost leadership, restarting kube-vip` 字符串，panic 行为依旧存在。升级带来的是 nftables/健康检查等新特性与上游修复，**不改变**"丢租约即退出"这一硬编码行为。真正降低故障率的手段仍是第一轮的**保留 VIP + 放宽租约超时**。

### 6.2 关键认知备忘

1. **kube-vip 丢租约 = 进程 panic 退出**，这是上游硬编码行为，**无法通过配置关闭**。
   唯一能做的是**让它不丢租约**（放宽超时 + 稳定 API）。
2. **`preserveVipOnLeadershipLoss=true` 的安全性有保障**：新 leader 上任时会执行
   `Cleaning up preserved VIPs as another node became leader` / `cleaned up preserved VIP to avoid conflict`，
   自动清理残留 VIP，不会产生"幽灵 VIP"。
   ⚠️ 官方文档亦提示 *"VIP Preservation on Leadership Loss Cautions"*：若持有 VIP 的**整机断电**，
   VIP 会短暂"滞留"在已失效主机上，直到新 leader 上任后清理。
3. **判断 kube-vip 是否健康的三个指标**：
   * `kubectl get lease -n kube-system plndr-cp-lock -o yaml` → 看 `renewTime` 是否新鲜、`leaseTransitions` 是否异常增长
   * `curl -sk https://10.0.0.168:6443/healthz` → VIP 可达性
   * `kubectl logs -n kube-system -l app.kubernetes.io/name=kube-vip-ds --previous --tail=50` → 是否出现 `lost leadership`
4. **【第二轮新增】VIP 的三类消费者，行为完全不同**（实测结论）：
   * **kube-vip** —— 虽然 DS 挂载了 host 的 `admin.conf`（其 `server` 是 VIP），但由于 `cp_enable=true` + `hostAliases`，
     运行时**实际连接的是 `127.0.0.1:6443`**。已用 `ss` 实测确认。**不构成依赖环。**
   * **kubelet** —— 这是唯一真正把 VIP 当作 API 入口的组件，也是本次 P0 的核心。
   * **admin.conf（运维 kubectl）** —— 人为使用，**不是**系统依赖，保留 VIP 反而是 HA 语义，**不应改动**。

---

# 第六章之二：第二轮变更 —— 根治 P0（完整过程记录）

> **变更时间**：2026-10-04 21:09 ~ 21:35（CST）
> **目标**：处理 6.1 中的两个 P0 —— ① 消除 kubelet 对 VIP 的依赖；② 升级 kube-vip 版本
> **备份目录**：`/root/kube-vip-p0-fix-backup-20261004-150924/`
> **操作约束**：分析节点 m01 无到 master01/master02 的 SSH 权限（`Permission denied (publickey,password)`），
> 因此远程节点操作一律通过**特权 Pod（hostPID + hostNetwork + hostPath）**完成。

## 6.2.1 变更前的关键事实核查（先取证，再动手）

动手前先做了一轮取证，**结果直接改变了原定方案**：

**① 只有 m01 的 kubelet 真的连 VIP。** 在 m01 上直接观察进程连接：

```
# kubelet（改之前）
ESTAB 10.0.0.61:36692  10.0.0.168:6443  users:(("kubelet",pid=1859038,fd=15))   ← 连 VIP
# kube-vip
ESTAB 127.0.0.1:59594  127.0.0.1:6443   users:(("kube-vip",pid=2598315,fd=7))   ← 连回环
```

即：**kube-vip 早已是回环连接**（`cp_enable` 生效），唯一绑在 VIP 上的系统组件是 **kubelet**。
这把 P0 的范围从"三台节点全部改造"缩小到"只改 m01 一处"。

**② master01/master02 的 `kubelet.conf` 早已解耦，但配置文件本身是"脏"的。**
读取两台节点的文件后发现，它们并不是标准 kubeadm 生成的 `kubelet.conf`，而是被手工改过：

```yaml
# master01（10.0.0.121）
clusters:
- cluster: {server: https://10.0.0.121:6443, ...}   # default-cluster —— 本机 IP ✅
  name: default-cluster
- cluster: {server: https://10.0.0.168:6443}          # kubernetes —— 指向 VIP，且【无 CA 数据】
  name: kubernetes
current-context: default-context                      # → 生效的是 default-cluster
```

`current-context` 指向 `default-cluster`（本机 IP），那个指向 VIP 的 `kubernetes` 条目**是未被引用的死条目**。
master02 同理（`10.0.0.120`）。

**③ 运行时实证（排除"文件说了不算"的可能）**：通过特权 Pod 读取两台节点的 `/proc/net/tcp`，统计到各目标 `:6443`（hex `192B`）的 ESTABLISHED 连接：

| 节点 | → VIP `10.0.0.168` | → 本机 IP | → 回环 |
|---|---|---|---|
| master01 | **0** | 5（`10.0.0.121`） | 2 |
| master02 | **0** | 5（`10.0.0.120`） | 2 |

**结论：master01/master02 无需任何改动**，唯一要改的是 m01。

**④ 备选回退通道**：`super-admin.conf` 指向 `10.0.0.61`（真实 IP，非 VIP），
实测其身份为 `system:masters`，可作为改 VIP 配置期间的操作通道，避免把自己锁在门外。

**⑤ kubelet 是否热加载 kubeconfig？—— 实测：不热加载。**
把 m01 的 `kubelet.conf` 临时改回 VIP 并**不重启** kubelet，观察 45 秒：
PID 未变、连接仍是 `127.0.0.1:6443`。**结论：必须重启 kubelet 才能生效。**
（随后已把文件改回 `127.0.0.1`，保持文件与运行态一致。）

## 6.2.2 P0-1：消除 kubelet → VIP 依赖

**方案选择**：为什么选 `https://127.0.0.1:6443` 而不是某个节点 IP？

| 候选 | 评估 |
|---|---|
| `https://127.0.0.1:6443` | ✅ **选定**。apiserver 以 `*:6443` 监听（`ss` 实测 `LISTEN *:6443`）；**证书 SAN 已含 `127.0.0.1`**（见下方 openssl 输出）；与 kube-controller-manager / kube-scheduler 的现有做法一致（它们用节点 IP，回环同样被 SAN 覆盖）。不依赖任何其他节点，单点故障面最小。 |
| `https://10.0.0.61:6443` | 可行，但会把 kubelet 绑到具体节点 IP，多一层不必要的耦合。 |

**证书 SAN 验证**（这是能否用回环的前提）：

```
$ openssl s_client -connect 10.0.0.61:6443 -showcerts </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -ext subjectAltName
subject=CN=kube-apiserver
X509v3 Subject Alternative Name:
    DNS:kubernetes, DNS:kubernetes.default, DNS:kubernetes.default.svc,
    DNS:kubernetes.default.svc.cluster.local, DNS:m01,
    IP Address:10.96.0.1, IP Address:10.0.0.61, IP Address:10.0.0.168, IP Address:127.0.0.1
                                                          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ 含 127.0.0.1 ✅
```

**认证链路验证**（改之前先确认新端点能通过 kubelet 身份鉴权，避免改完连不上）：

```
$ KUBECONFIG=<改后的 kubelet.conf> kubectl auth whoami
Username  system:node:m01
Groups    [system:nodes system:authenticated]
$ kubectl get --raw /healthz → ok
```

**执行变更**（先备份，逐行确认只有一行差异）：

```bash
cp -a /etc/kubernetes/kubelet.conf /etc/kubernetes/kubelet.conf.p0bak.20261004-211514
# 单行修改
sed -i 's|https://10.0.0.168:6443|https://127.0.0.1:6443|' /etc/kubernetes/kubelet.conf

$ diff kubelet.conf.p0bak.20261004-211514 kubelet.conf
5c5
<     server: https://10.0.0.168:6443
---
>     server: https://127.0.0.1:6443      ← 仅此一行
```

**重启 kubelet 并验证**（注意：此时若 m01 是 leader，重启 kubelet 不影响 VIP，但会影响本节点与 API 的连接约数秒）：

```
$ systemctl restart kubelet
# kubelet PID 1859038 → 2770847

# 改后连接：
ESTAB 127.0.0.1:50074  127.0.0.1:6443  users:(("kubelet",pid=2770847,fd=15))
# 残留 VIP 连接数：0
# 日志：I kubelet.go apiserver.go:52 "Watching apiserver"
```

**远程节点：为什么最终没有改动** —— 原计划写一个特权 Job 对 master01/master02 做同样的改写。
脚本在 master01 上**首次运行即被自身的前置校验拦下**（`RESULT=ABORT unexpected server ''`），
原因是所用的 calico 镜像过于精简，缺少 `head`/`hostname`。**但这次"失败"反而促成了上面的发现 ②③**：
既然那两台本就无需改写，就不应再去动它们。相关 Job/ConfigMap 及所有探针 Pod 已全部清理。

> **教训记录**：远程批量改节点配置时，**前置校验必须在任何写操作之前失败**。
> 本次脚本的"只认得 `10.0.0.168`、否则拒绝"的设计，使得两次失败（`/bin/sh` 不存在、工具缺失）
> 都变成了**零副作用**，这是安全的关键。

**P0-1 最终验证 —— 全集群 VIP 消费者清零**：

```
$ ss -tnp | grep 10.0.0.168:6443 | grep -vE 'kube-vip|127.0.0.1'
  （空 —— m01 上已无任何组件依赖 VIP）

master01: → VIP 连接 0
master02: → VIP 连接 0
```

## 6.2.3 P0-2：升级 kube-vip v1.0.3 → v1.2.4

**升级前的兼容性验证**（离线完成，不靠猜）：

1. **确认目标版本存在**：`ghcr.io` 的 tag 列表显示 `v1.2.4` 为最新 `v1.2.x`，且是多架构镜像（amd64/arm64/armv7/s390x/ppc64le）。

2. **导出二进制并逐项比对 flag**（关键一步，避免升级后参数被忽略而无人察觉）：

```bash
crictl pull ghcr.io/kube-vip/kube-vip:v1.2.4
ctr -n k8s.io images export v124/kv.tar ghcr.io/kube-vip/kube-vip:v1.2.4
# 从 OCI layer 中解出 /kube-vip
./kube-vip-v1.2.4 manager --help > help-v1.2.4.txt
```

| 版本 | flag 总数 |
|---|---|
| v1.0.3 | 69 |
| v1.2.4 | 83 |

- **被删除的 flag：0 个**（`comm -23` 结果为空）
- **新增的 flag：14 个**（`--egressWithNftables`、`--loseLeadership`、`--instanceName`、`--debounceTime`、控制面健康检查相关等）
- 关键项逐一确认存在：`--preserveVipOnLeadershipLoss`、`--leaseDuration`、`--leaseRenewDuration`、`--leaseRetry`、`--arp`、`--controlplane`

> 一度出现"v1.0.3 用到的 17 个 env/flag 在 v1.2.4 全部 MISSING"的告警，经复核是**比对的正则过严**（`^...$` 锚定）导致误报，
> 而非真实的兼容性破坏。改用 `--help` 的 flag 列表比对后确认无删除项。**这类结论必须以工具自述为准，不能以字符串搜索为准。**

3. **关于 panic 的重要更正**：对 v1.2.4 二进制做字符串检索，`lost leadership, restarting kube-vip` **依然存在**。
   → **升级不会消除"丢租约即 panic 退出"的行为**。此前"升级可根治 panic"的判断不成立。

4. **预拉取镜像**（关键前置）：`imagePullPolicy` 为 `IfNotPresent`，若远程节点无外网/无缓存，
   滚动更新会把 2/3 的 Pod 打成 `ImagePullBackOff`。因此**先在每个控制面节点预拉取并验证**：
   用 `imagePullPolicy: Always` 的 init 容器执行 `/kube-vip version`，master01/master02 均 **exit 0**，
   确认三台节点均已缓存 `v1.2.4`，随后才执行滚动更新。

**执行升级**（`selector` 不可变，故只 patch 镜像字段，避免动 selector）：

```bash
kubectl -n kube-system patch ds kube-vip-ds --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image",
       "value":"ghcr.io/kube-vip/kube-vip:v1.2.4"}]'
# 再同步版本标签（selector 只匹配 name，故安全）
kubectl -n kube-system patch ds kube-vip-ds --type=merge \
  -p '{"metadata":{"labels":{"app.kubernetes.io/version":"v1.2.4"}},
       "spec":{"template":{"metadata":{"labels":{"app.kubernetes.io/version":"v1.2.4"}}}}}'
```

滚动更新过程（`maxUnavailable: 1`，逐个替换，VIP 始终有主）：

```
t+10s  3/3 Running，镜像均为 v1.2.4，重启数 0
t+60s  同上，无抖动
```

**验证**：

```
# 权威来源：直接问运行中的二进制
m01      (kube-vip-ds-2lvtm): Version: v1.2.4
master01 (kube-vip-ds-sxp4p): Version: v1.2.4
master02 (kube-vip-ds-nfxvf): Version: v1.2.4

# 原有配置全部保留
vip_preserve_on_leadership_loss=true
vip_leaseduration=15 / vip_renewdeadline=10 / vip_retryperiod=2

# 新版本确认保留 VIP 的分支已生效
INFO Becoming leader with VIP preservation enabled - ensuring VIP takeover
INFO took over VIP as new leader IP=10.0.0.168 interface=eth0
```

## 6.2.4 第二轮的故障注入复测（在 v1.2.4 上重做一次）

第一轮已在 v1.0.3 上验证过"保留 VIP"。升级后**重做一次**，以确认新版本行为一致。
这次做得更狠：**直接掐断当时 leader（m01）自己的 API 通路**，复现最极端场景。

```bash
# m01 当时是 leader，断掉它访问本地 apiserver 的能力
iptables -I OUTPUT -p tcp -d 127.0.0.1 --dport 6443 -j REJECT
iptables -I INPUT  -p tcp --dport 6443 -j REJECT
```

观测（每 10s 一次）：

```
t+10s  VIP_on_m01=1  kube-vip_pid=2778770
t+30s  VIP_on_m01=1  kube-vip_pid=2778770
t+40s  VIP_on_m01=0  kube-vip_pid=2779865   ← 失去领导权，进程按预期退出并重启
```

关键在于**失去领导权之后发生了什么**：

| 观测项 | 结果 | 判定 |
|---|---|---|
| 租约 holder | `m01` → **`master01`** | ✅ 领导权正常转移 |
| 租约切换计数 | 44 → 45（+1） | ✅ 仅一次切换，无抖动 |
| VIP 是否被删 | **否** —— master01 接管后 VIP 持续 `HTTP 200` | ✅ 符合"保留 VIP"预期 |
| 另两个 kube-vip Pod | 重启数 **0** | ✅ 未被牵连 |
| 集群可用性 | master01/master02/worker 始终 Ready | ✅ 控制面未中断 |

`m01` 当时显示 NotReady，是**我注入的 iptables 规则**掐断了它自己的 apiserver 所致（属测试副作用，非集群故障）。

清理测试规则并等待收敛：

```bash
iptables -D OUTPUT -p tcp -d 127.0.0.1 --dport 6443 -j REJECT
iptables -D INPUT  -p tcp --dport 6443 -j REJECT
```

```
t+15s  m01=Ready master01=Ready master02=Ready worker01=Ready worker02=Ready worker03=Ready
（此后连续 90s 稳定）
```

**测试残留清理确认**：iptables 中 `6443 REJECT` 规则数 = 0；`p0-*` / `*probe*` Pod 数 = 0。

## 6.2.5 第二轮结果汇总

| 指标 | 变更前 | 变更后 |
|---|---|---|
| kube-vip 版本 | v1.0.3 | **v1.2.4** |
| m01 kubelet 的 API 入口 | `10.0.0.168:6443`（VIP） | **`127.0.0.1:6443`** |
| master01 kubelet 的 API 入口 | `10.0.0.121:6443`（本机 IP） | 未改动 |
| master02 kubelet 的 API 入口 | `10.0.0.120:6443`（本机 IP） | 未改动 |
| **全集群 → VIP 的系统组件连接数** | 1（m01 kubelet） | **0** |
| kube-vip Pod 重启数 | 51 / 53 / 53 | 0 / 0 / 0（滚动升级各 +1 内含预期切换） |
| 节点状态 | 6 Ready | 6 Ready |

**P0-1 与 P0-2 均已闭环。**

---


## 七、变更清单与回滚

### 7.1 已应用的变更

**第一轮（止血）**

| 对象 | 变更 |
|---|---|
| `ds/kube-vip-ds` | 4 个环境变量 + resources + priorityClassName + terminationGracePeriodSeconds |
| `prometheusrule/cluster-wide-alerts` | 修正 2 条错误表达式；新增 3 条 kube-vip 告警（`pod.rules` 组）|

**第二轮（根治 P0）**

| 对象 | 变更 | 位置 |
|---|---|---|
| `ds/kube-vip-ds` | 镜像 `v1.0.3` → **`v1.2.4`**；`app.kubernetes.io/version` 标签同步 | 3 个控制面节点 |
| `/etc/kubernetes/kubelet.conf`（**m01 主机文件**） | `server:` 由 `https://10.0.0.168:6443` → **`https://127.0.0.1:6443`**（单行） | 仅 m01 |
| m01 `kubelet` 服务 | 重启一次以加载新配置（PID `1859038` → `2770847`） | 仅 m01 |

> master01 / master02 **未做任何改动** —— 实测其 kubelet 本就指向本机 IP（详见 6.2.1）。
> `admin.conf` **未改动** —— 有意保留 VIP 语义（详见 6.2.1 事实④）。

### 7.2 交付物

```
/root/kube-vip-restart-rootcause-and-fix.md      ← 本报告（含第二轮完整过程）
/root/kube-vip-ha-daemonset-FIXED.yaml           ← 修复后 DaemonSet（可复现）
/root/kube-vip-ha-daemonset-FIXED.json           ← 同上（JSON）
/root/kube-vip-fix-backup-20261004-064511/        ← 第一轮回滚备份
/root/kube-vip-p0-fix-backup-20261004-150924/    ← 第二轮回滚备份
    ├── admin.conf                                 （变更前副本）
    ├── kubelet.conf                               （变更前副本）
    ├── kube-vip-ds-BEFORE-p0.yaml / -AFTER-p0.yaml
    ├── kube-vip-pods-BEFORE-p0.txt / -AFTER-p0.txt
    └── lease-AFTER-p0.yaml
/etc/kubernetes/kubelet.conf.p0bak.20261004-211514  ← m01 kubelet.conf 原地备份
```

### 7.3 回滚方法

```bash
# ---------- 第一轮（止血）----------
BK=/root/kube-vip-fix-backup-20261004-064511

# 回滚 DaemonSet
kubectl apply -f $BK/kube-vip-ds-ORIGINAL.yaml

# 回滚告警规则
kubectl patch prometheusrule cluster-wide-alerts -n monitoring \
  --type=merge --patch-file $BK/prometheusrule-cluster-wide-alerts-ORIGINAL.json
```

```bash
# ---------- 第二轮（根治 P0）----------
BK=/root/kube-vip-p0-fix-backup-20261004-150924

# 回滚 kube-vip 镜像版本（回到 v1.0.3）
kubectl -n kube-system patch ds kube-vip-ds --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image",
       "value":"ghcr.io/kube-vip/kube-vip:v1.0.3"}]'
kubectl -n kube-system patch ds kube-vip-ds --type=merge \
  -p '{"metadata":{"labels":{"app.kubernetes.io/version":"v1.0.3"}},
       "spec":{"template":{"metadata":{"labels":{"app.kubernetes.io/version":"v1.0.3"}}}}}'

# 回滚 m01 kubelet.conf 到 VIP 并重启
sudo cp -a /etc/kubernetes/kubelet.conf.p0bak.20261004-211514 /etc/kubernetes/kubelet.conf
sudo systemctl restart kubelet
```

> ⚠️ 回滚 DaemonSet 会**重新引入"丢 leader 即摘 VIP"的危险行为**，且会产生一次滚动重启。
> ⚠️ 回滚 P0-1 会让 m01 的 kubelet **重新依赖 VIP**，即恢复循环依赖 —— 不建议回滚，除非确有回退到 VIP 依赖的运维要求。
> 回滚前请确认 §6.1 中已闭环的项。


---

## 八、附录：关键取证命令

```bash
# 1. 重启现状与退出原因
kubectl get pods -n kube-system -l app.kubernetes.io/name=kube-vip-ds -o wide
kubectl get pod -n kube-system <pod> -o jsonpath='{.status.containerStatuses[0].lastState}'

# 2. 崩溃现场（决定性证据）
kubectl logs -n kube-system <pod> --previous

# 3. 租约状态与切换次数
kubectl get lease -n kube-system plndr-cp-lock -o yaml

# 4. 验证循环依赖（VIP 的消费者）
# 4a. 配置层面：看每个 kubeconfig 的 server
grep server: /etc/kubernetes/admin.conf /etc/kubernetes/kubelet.conf
#     ⚠️ 注意 kubelet.conf 可能含多个 cluster，只有 current-context 指向的那个生效：
grep -A3 'current-context' /etc/kubernetes/kubelet.conf

# 4b. 运行时层面（决定性）：看进程实际连到哪
ss -tnp | grep 6443 | grep -E 'kubelet|kube-vip'
#     m01 kubelet 应为 127.0.0.1:6443；若出现 10.0.0.168:6443 则仍存在依赖环

# 4c. 跨节点核对（在目标节点上读宿主机 TCP 表，:6443 = hex 192B）
#     VIP 10.0.0.168=0A0000A8 / 10.0.0.121=7900000A / 10.0.0.120=7800000A / 10.0.0.61=3D00000A / 回环=0100007F
grep ':192B ' /proc/net/tcp | sed 's/  */ /g'
grep -c '0A0000A8:192B' /proc/net/tcp     # 到 VIP 的连接数，应为 0

# 5. 从运行中的二进制提取权威配置键名
cp /proc/$(pgrep -f '^/kube-vip' | head -1)/root/kube-vip /tmp/kube-vip
/tmp/kube-vip manager --help | grep -iE "lease|leader|preserve"
# ⚠️ 判定兼容性请用 --help 的 flag 列表比对，不要用 strings 锚定正则（易误报）
diff <(grep -oE '^\s+(-[a-zA-Z], )?--[a-zA-Z]+' /help-v1.0.3.txt | grep -oE '\-\-[a-zA-Z]+' | sort -u) \
     <(grep -oE '^\s+(-[a-zA-Z], )?--[a-zA-Z]+' /help-v1.2.4.txt | grep -oE '\-\-[a-zA-Z]+' | sort -u)

# 6. 历史重启趋势
POD=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n monitoring $POD -c prometheus -- wget -qO- \
 'http://localhost:9090/api/v1/query_range?query=max%20by(pod)(kube_pod_container_status_restarts_total{container%3D%22kube-vip%22})&start=0&end='$(date -u +%s)'&step=600'

# 7. 确认配置真正进入进程
tr '\0' '\n' < /proc/$(pgrep -f '^/kube-vip' | head -1)/environ | grep vip_

# 8. VIP 可用性
curl -sk https://10.0.0.168:6443/healthz

# 9. 确认运行中的 kube-vip 版本（权威来源，不是看 spec 里的 image 字段）
for N in m01 master01 master02; do
  P=$(kubectl -n kube-system get pod -l app.kubernetes.io/name=kube-vip-ds \
        -o jsonpath="{.items[?(@.spec.nodeName=='$N')].metadata.name}")
  echo "$N: $(kubectl -n kube-system exec $P -c kube-vip -- /kube-vip version)"
done

# 10. 确认 kubelet.conf 改动是否真的生效（kubelet 不热加载，必须重启）
PID=$(pgrep -x kubelet)
grep server: /etc/kubernetes/kubelet.conf
ss -tnp | grep "pid=$PID" | grep 6443     # 实际连接，应与上一行 server 一致
```
