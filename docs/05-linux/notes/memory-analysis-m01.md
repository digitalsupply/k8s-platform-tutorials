# 节点 m01 内存占用分析报告

- **主机**：m01 (10.0.0.61) / Rocky Linux 9.6 / 内核 5.14.0-570.58.1
- **角色**：Kubernetes v1.29.8 control-plane（containerd 1.7.22）
- **规格**：4 vCPU / 5.5 GiB 内存（MemTotal 5665 MiB）/ 无 Swap / 根盘 47G（已用 39%）
- **采样时间**：2026-09-30 20:03（uptime 3 天 6 小时，load 1.33 / 0.69 / 0.63）

---

## 1. 总体结论

| 指标 | 数值 | 评价 |
|---|---|---|
| MemTotal | 5665 MiB | — |
| 已用（used） | ~4600 MiB（81%） | 偏高 |
| MemFree | 445 MiB（8%） | 偏低 |
| **MemAvailable** | **~900 MiB（16%）** | **风险区** |
| buff/cache | 678 MiB（12%） | 偏低 |
| Swap | 0 | **无任何缓冲** |
| Committed_AS / CommitLimit | 7155 MiB / 2833 MiB | **超限 2.5 倍** |
| overcommit_memory | 1（always overcommit） | 无承诺校验 |
| AnonHugePages | 2598 MiB（占匿名内存 66%） | THP=always 激进 |
| dmesg OOM 记录 | 无 | 尚未触发杀进程 |

**核心判断**：这是一台**严重超配的 5.5G 控制面节点**。单 kube-apiserver 就吃掉 1.4G（25%），加上 etcd、Calico 全家桶、Zabbix 全家桶、MariaDB、Nginx/PHP-FPM 等**本该跑在 Worker 上的业务负载**，MemAvailable 长期在 900 MiB 徘徊。节点当前 `MemoryPressure=False` 纯属侥幸——kubelet 的 `evictionHard.memory.available=100Mi` 阈值极低，一旦触发就是直接驱逐 + 节点 NotReady。

---

## 2. 内存构成拆解

```
MemTotal          5665 MiB (100%)
├── AnonPages      3753 MiB  (66%)  ← 用户态进程堆/栈，占比过高
│   └── AnonHuge   2598 MiB  (46%)  ← THP 匿名大页，2M 粒度
├── PageCache       678 MiB  (12%)  ← 偏低（无 SWAP 机器本该更高）
├── Slab            312 MiB  (5.5%)
│   ├── SReclaimable 215 MiB        ← dentry/inode，可回收
│   └── SUnreclaim    97 MiB        ← 内核不可回收
├── PageTables+Stk   40 MiB
├── MemFree         445 MiB  (8%)   ← 空闲缓冲池
└── (Shmem/Buf ~40 MiB 计入 Cached)
```

**要点**：`buff/cache` 仅 678 MiB 而 `MemFree` 只有 445 MiB，缓存池太薄，**没有 page cache 用来吸收突发分配**。页表 40 MiB 正常。

---

## 3. 进程 TOP 排行（按 RSS）

| # | PID | 进程 | 用户 | RSS | 占比 | 线程 | CPU% | 说明 |
|---|---|---|---|---|---|---|---|---|
| 1 | 40660 | **kube-apiserver** | root | **1439 MiB** | **25.4%** | 12 | 14.4 | 静态 Pod，无内存 limit |
| 2 | 2790947 | hermes (python) | root | 542 MiB | 9.6% | 31 | 1.7 | AI Agent gateway，会话常驻 |
| 3 | 112500 | opencode (serve) | root | 396 MiB | 7.0% | 17 | 1.7 | IDE/Agent 后端服务，已跑 3 天 |
| 4 | 1931795 | opencode (cli) | root | 270 MiB | 4.8% | 16 | 1.5 | tmux 会话内，跑了 1 天 7 小时 |
| 5 | 982 | mariadbd | mysql | 240 MiB | 4.2% | 38 | 0.7 | buffer_pool 仅 128M，性能受限 |
| 6 | 2814199 | etcd | root | 181 MiB | 3.2% | 12 | 10.7 | DB size 84 MB，healthy |
| 7 | 848 | java (zabbix-jgw) | zabbix | 147 MiB | 2.6% | 33 | 0.0 | 无 -Xmx，JVM 默认堆 |
| 8 | 1064 | kubelet | root | 80 MiB | 1.4% | 14 | 2.9 | — |
| 9 | 3075035 | alloy | root | 77 MiB | 1.4% | 9 | 0.8 | 日志采集，limit 512M |
| 10 | 80228 | containerd | root | 61 MiB | 1.0% | 14 | 0.9 | — |
| 11 | 4295-4302 | calico-node ×6 | root | 247 MiB | 4.4% | 8-14 | ~1.2 | 6 个 pod 合计 |
| 12 | 1055+ | zabbix_server ×50 | zabbix | 351 MiB | 6.2% | 1/proc | 0.0 | **50 个进程**，多 worker 模型 |
| 13 | 819-959 | php-fpm ×14 | root | 113 MiB | 2.0% | 1 | — | ondemand 池偏大 |
| 14 | 1094-1098 | nginx ×5 | root | 25 MiB | 0.4% | — | — | worker_processes auto(4) + master |

**合计**：306 个进程 RSS 累加 ~4933 MiB（含共享库重复计数，偏高）。Top15 占 3660 MiB = **65%**。

### 内存热点三个明确来源

1. **kube-apiserver 1439 MiB** — 单进程吃掉 1/4 内存。`RssAnon=1443828 kB`，几乎全是堆。`VmHWM=1680836 kB`（峰值 1.6G），`Swap=0`，**无 GOGC / GOMEMLIMIT 设置**，Go GC 默认让堆涨到 2 倍才回收。**已重启 192 次**。
2. **AI Agent 进程 1208 MiB**（hermes 542 + opencode 396 + opencode 270）— 占全机 **21%**，是登录会话带起来的，与 K8s 无关。
3. **运维监控栈 660 MiB**（zabbix_server 351 + java-gw 147 + agent2 20 + prometheus/alloy/cadvisor/node_exporter ~140）— 装了 4 套监控，重复采集。

---

## 4. 线程分析

```
总进程数：305        总线程数：776       平均 2.5 线程/进程
threads-max = 44971  （远未触及）
```

| 进程 | 线程数 | 评估 |
|---|---|---|
| mariadbd | 38 | 正常（max_connections=151，连接池未放大） |
| java (zabbix-jgw) | 33 | 默认 START_POLLERS=5，但 33 线程偏高，建议显式限 `-Xmx` + 线程池 |
| hermes (python) | 31 | 可接受 |
| opencode ×2 | 17 + 16 | Node 运行时，可接受 |
| containerd-shim | 15 × N | 每个容器一个 shim，11 容器 = 165 线程（固定开销） |
| calico-node ×6 | 8–14 | Go 运行时 GOMAXPROCS=4 派生 |
| kube-apiserver | **12** | 偏低但正常（Go 1.2G 堆仅 12 线程，**说明 GC 并行度不足，是延迟风险**） |

**关键观察**：
- **kube-apiserver 只有 12 个线程却持有 1.4 GiB 堆** —— 说明 Go GC 没能及时回收。日志中大量 `Trace ... (total time: 3501ms)`，单请求 3.5s，这是 GC STW + 内存压力的直接症状。
- containerd-shim 带来 ~165 个常驻空转线程，属于 cgroup v2 + containerd 的固定成本，**无法消除**。

---

## 5. Pod / 容器内存

### 5.1 m01 上的 Pod（12 个容器）

| Pod | cgroup 实测 | crictl MEM | QoS | 内存 limit |
|---|---|---|---|---|
| **kube-apiserver-m01** | **1718 MiB** | 1.636 GB | Burstable | **无** ❌ |
| calico-node-snf2k | 245 MiB | 214.5 MB | Burstable | 无 |
| etcd-m01 | 210 MiB | 153.9 MB | Burstable | 无（仅 req 100M）❌ |
| alloy-tsj9x | 93 MiB | 87 MB | Burstable | 512M |
| kube-scheduler-m01 | 54 MiB | 51.3 MB | Burstable | 无 |
| kube-controller-manager | 41 MiB | 31.9 MB | Burstable | 无 |
| node-exporter-rqgmw | — | 24.2 MB | BestEffort | 无 ❌ |
| kube-proxy-b7kl6 | — | 42 MB | BestEffort | 无 ❌ |
| speaker-vtcl8 (metallb) | — | 32 MB | BestEffort | 无 ❌ |
| kube-vip-ds-z4cwm | — | 18.4 MB | BestEffort | 无 ❌ |
| config-reloader | — | 13.7 MB | BestEffort | 无 |
| **mcrun** | — | — | BestEffort | **Pod 卡死 4h13m** ❌ |

**Pod 级合计约 2.4 GiB，占节点内存 43%。**

### 5.2 资源声明与实际严重脱节

```
节点 allocatable        = 5565 MiB
本节点容器 memory request 合计 =  278 MiB  →  request/allocatable = 5.0%
本节点容器 memory limit   合计 =  512 MiB  →  实际使用约 2.4 GiB（4.7 倍）
```

**这是最危险的地方**：调度器认为 m01 只用了 278 MiB，完全空闲，任何 Pod 都能继续调度上来；而实际已用 81%。**`systemReserved` / `kubeReserved` 均未设置**，kubelet 不为操作系统和自身预留任何内存（`enforceNodeAllocatable=['pods']` 意味着连系统进程都不保护）。

### 5.3 集群级 limits 覆盖率

```
有 memory limit 的容器：  33
无 memory limit 的容器： 136   ← 80% 的容器无上限
```

### 5.4 异常 Pod

**`logging/mcrun` 卡在 ContainerCreating 4 小时 13 分**：
```
Warning  FailedMount  3m32s (x131 over 4h13m)  kubelet
MountVolume.SetUp failed for volume "script": configmap "mc-cm" not found
```
ConfigMap 缺失导致无限重试（131 次），持续产生事件流和 apiserver 压力。

---

## 6. 关键风险点

### 🔴 P0 — 内存超卖且无 Swap
- `MemAvailable ≈ 900 MiB`，`SwapTotal = 0`，`failSwapOn=True`
- `Committed_AS 7155 MiB >> CommitLimit 2833 MiB`（2.5 倍），因 `overcommit_memory=1` 无校验
- 任何一次 apiserver GC 峰值（已观测 VmHWM 1.6G）都可能触发内核 OOM Killer，**随机杀进程**（最可能是 apiserver 或 mariadbd）

### 🔴 P0 — apiserver 已重启 192 次
```
kube-apiserver-m01     192 次重启
kube-apiserver-master01  72 次
kube-apiserver-master02  71 次
```
上一次退出：`exitCode=255, reason=Error, finishedAt=2026-09-27T06:45:08Z`

**崩溃日志直接指向 etcd**：
```
F0927 06:45:08 PostStartHook "rbac/bootstrap-roles" failed:
      unable to initialize roles: timed out waiting for the condition
E0927 06:45:08 reflector.go:147 Failed to watch *v1.ConfigMap:
      etcdserver: request timed out
```
节点在 2026-09-27 13:54 重启过（`last reboot`），时间线吻合 —— **etcd 响应超时导致 apiserver PostStartHook 失败并退出，节点重启后才恢复**。这本质上是**内存压力下的雪崩**，而非独立故障。

### 🟠 P1 — THP 策略过于激进
```
/sys/kernel/mm/transparent_hugepage/enabled = [always]
AnonHugePages = 2598 MiB（占匿名内存 66%）
thp_fault_alloc = 794581  vs  thp_fault_fallback = 38177（失败率 4.6%）
compact_stall = 1098   compact_fail = 998  （压缩失败率 90.9% ❗）
```
`compact_fail/success = 998/100` —— **碎片化严重，90% 的内存规整请求失败**。`always` 模式下 Go 运行时（apiserver/etcd/calico）会强行申请 2 MiB 大页，导致**页内浪费 + 规整停顿**。这类停顿正是 apiserver 出现 3.5s 慢请求的原因之一。

### 🟠 P1 — 4 套监控重复采集
zabbix_server(351M) + zabbix-agent2 + zabbix-java-gateway(147M) + prometheus + alloy + cAdvisor + node-exporter + alertmanager = **8 个监控组件，~660 MiB，20% 的 zabbix_server 进程数（50 个）**。控制面节点上跑完整 Zabbix Server 属于严重的职责错位。

### 🟡 P2 — MariaDB 配置严重保守
```sql
innodb_buffer_pool_size = 128 MB   ← 5.5G 机器上仅占 2.3%
key_buffer_size        = 128 MB
max_connections        = 151       （与默认一致，未调优）
performance_schema     = OFF
table_open_cache       = 2000      ← 预留 2000 个表句柄，但 buffer pool 极小
```
buffer pool 过小会导致**频繁脏页刷盘**（`bo=86→367` IO 波动可见）；`table_open_cache=2000` 相对 128M buffer pool 明显不成比例。

### 🟡 P2 — PHP-FPM / Nginx 池偏大
```
php-fpm 14 个进程 × ~10 MiB = 113 MiB   （5.5G 节点上偏多）
nginx  worker_processes auto (=4) + 4 worker = 25 MiB
worker_connections 1024
```

### 🟡 P2 — 堆积的重启计数
`calico-node 42 次`、`kube-vip 42 次`、`speaker 56 次`、`calico-kube-controllers 57 次`、`ceph-csi-rbd-provisioner 151 次` —— 说明存在**周期性的节点级扰动**（与 9-27 那次节点重启同源）。

---

## 7. 可优化项（按 ROI 排序）

### 第一梯队：立即执行，风险极低

**1. 迁移 AI Agent 进程出控制面（回收 ~1.2 GiB = 21%）**
hermes(542M) + opencode(396M) + opencode(270M) 全在控制面节点上跑。
```bash
# 在 tmux 会话中
tmux ls                        # 找到 session-46
tmux kill-session -t <目标会话>  # 释放 270 MiB
# opencode serve (PID 112500) 若非必需则停掉
kill 112500                    # 释放 396 MiB
```
> 保留当前会话（session-3），仅清理陈旧会话。

**2. 下调 THP 为 madvise（回收碎片 + 消除规整停顿）**
```bash
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag
# 持久化
cat >> /etc/default/grub <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="... transparent_hugepage=madvise transparent_hugepage_defrag=madvise"
EOF
update-grub   # Rocky: grub2-mkconfig -o /boot/grub2/grub.cfg && grub2-install /dev/sda
```
预期效果：解除 `compact_fail=998` 的规整停顿，apiserver 慢请求（3.5s）显著改善。

**3. 清理卡死 Pod（减少事件风暴）**
```bash
kubectl delete pod mcrun -n logging --force --grace-period=0
# 追根：补上缺失的 ConfigMap
kubectl create configmap mc-cm -n logging --from-file=<脚本路径>
```

**4. 缩减 zabbix_server 进程数（回收 ~200 MiB）**
```bash
# /etc/zabbix/zabbix_server.conf
StartPollers=5
StartPollersUnreachable=1
StartPingers=1
StartDiscoverers=1
CacheSize=16M              # 默认 32M，按监控项数下调
ValueCacheSize=4M
HistoryCacheSize=8M
HistoryIndexCacheSize=2M
```
> 需评估监控项规模；控制面节点上更推荐只保留 agent 端，Server 迁到 worker。

### 第二梯队：需评估后执行

**5. 为 kube-apiserver 加内存软限（最重要的稳定性改造）**

当前 `resources: {requests: {cpu: 250m}}` —— **完全没有内存约束**。三个 master 全部如此。
```yaml
# GOMEMLIMIT 让 Go 在接近上限时提高 GC 频率，而非被 OOM Kill
env:
  - name: GOMEMLIMIT
    value: "1800MiB"    # 设为 limit 的 ~90%
  - name: GOGC
    value: "50"         # 从默认 100 降到 50，堆峰值可降约 40%
resources:
  requests: {cpu: 250m, memory: 1200Mi}
  limits:   {cpu: "2",  memory: 2000Mi}
```
> **注意**：`GOMEMLIMIT` 需 Go 1.19+（v1.29 满足）。设置过低会导致 GC thrash 持续吃 CPU，需在压测环境验证。
> 验证效果：`kubectl top pod` + apiserver `/metrics` 的 `go_memstats_heap_inuse_bytes`。

**6. 为 etcd 设置合理 request + 监控**
```yaml
resources:
  requests: {cpu: 200m, memory: 500Mi}   # 当前仅 100Mi，严重低估
  limits:   {memory: 1500Mi}
```
当前 DB size 84 MB，etcd 实际用 181 MiB，500Mi request 有 2.7x 冗余，安全。

**7. 配置 kubelet 资源预留（防止系统进程被 OOM）**
```yaml
# /var/lib/kubelet/config.yaml
systemReserved:
  memory: "400Mi"
  cpu: "200m"
kubeReserved:
  memory: "500Mi"
  cpu: "200m"
evictionHard:
  memory.available: "300Mi"   # 当前 100Mi 过于激进
enforceNodeAllocatable: ["pods","system-reserved"]  # 当前仅 ["pods"]
```
> `enforceNodeAllocatable` 加 `system-reserved` 后，调度器会真正避开系统内存，避免 evict 风暴。

**8. 加 Swap 或 zram（5.5G 机器的安全垫）**
```bash
# 方案 A：2G swapfile（应急缓冲）
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile swap defaults 0 0' >> /etc/fstab
# 注意：failSwapOn=True 需同步改为 False
```
> **权衡**：控制面节点加 swap 会引入延迟抖动。**推荐方案 B**：
```bash
# 方案 B：zram（内存压缩，优先于磁盘 swap）
dnf install zram-generator
# /etc/systemd/zram-generator.conf
zram-size = min(ram, 1536)
```
> 长期最佳解还是**升配到 8 GiB 或把非控制面负载迁走**。

### 第三梯队：架构级优化

**9. 控制面节点职责剥离（根治方案）**
当前 m01 同时承担 K8s 控制面 + AI Agent + Zabbix Server + MariaDB + Nginx/PHP + 审计。四类负载混跑是所有问题的根源。

| 负载 | 占用 | 建议 |
|---|---|---|
| K8s 控制面（apiserver/etcd/calico/scheduler/cm） | ~2.0 GiB | 保留 |
| AI Agent（hermes/opencode） | 1.2 GiB | **迁至 worker / 独立开发机** |
| Zabbix Server + JGW | 0.5 GiB | **Server 迁至 worker，仅留 agent2** |
| MariaDB | 0.24 GiB | **迁至 worker StatefulSet** |
| Nginx + PHP-FPM | 0.14 GiB | **迁至 worker** |
| 冗余监控（cAdvisor + node-exporter + alloy） | 0.14 GiB | 合并为一套 |

执行后 m01 可回收 **~2.2 GiB**，MemAvailable 从 900 MiB 提升至 ~3.1 GiB（55%），彻底脱离风险区。

**10. 集群级补齐 resource limits**
```bash
# 用 LimitRange 给默认兜底（对所有 namespace 生效）
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: default
spec:
  limits:
  - type: Container
    default:
      memory: 512Mi
      cpu: "1"
    defaultRequest:
      memory: 128Mi
      cpu: 100m
EOF
```
> 136 个容器无内存 limit，OOM 时无法预测影响面。

**11. 排查 9-27 节点重启与 192 次重启的根因**
```bash
# 1. 确认重启原因
journalctl --list-boots
journalctl -b -1 -p err --no-pager | tail -50
# 2. apiserver 退出码 255 意味着进程被 signal 或 panic
kubectl logs -n kube-system kube-apiserver-m01 --previous | grep -E 'panic|fatal|signal'
# 3. 三个 master 都重启 70+ 次，说明是集群级/节点级共性问题
```
> 高度怀疑：内存压力 → etcd 超时 → apiserver PostStartHook 失败 → 退出 → 节点重启。修复第 5、8 项后应可消除。

---

## 8. 预期收益汇总

| 措施 | 回收内存 | 占比 | 风险 | 难度 |
|---|---|---|---|---|
| 1. 清理陈旧 AI Agent 会话 | 1200 MiB | 21% | 低 | ★ |
| 2. THP 改 madvise | ~200 MiB(碎片) | 4% | 低 | ★ |
| 3. 删除卡死 Pod | ~0 | — | 无 | ★ |
| 4. 缩减 zabbix worker | 200 MiB | 3.5% | 中 | ★★ |
| 5. apiserver GOMEMLIMIT/GOGC | ~400 MiB | 7% | 中 | ★★ |
| 6. etcd/kubelet 预留 | 0(防风险) | — | 中 | ★★ |
| 7. zram 1.5G | +1536 MiB 缓冲 | — | 中 | ★★ |
| 9. 剥离非控制面负载 | 2200 MiB | 39% | 高 | ★★★★ |
| **1+2+4+5 合计** | **~2000 MiB** | **35%** | 低-中 | — |
| **全量执行后** | **~3736 MiB** | **66%** | — | — |

> MemAvailable 预计从 900 MiB → **4.6 GiB（82%）**，彻底解决无 Swap 下的 OOM 风险与 apiserver 重启问题。

---

## 9. 监控告警建议

当前缺少内存类告警（Zabbix 配置中未发现 MemoryCacheSize 等调优项，也未见内存阈值告警）。

```promql
# 关键指标（node-exporter 已在本机 9100 端口）
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.15   # 预警
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.05   # 严重
node_vmstat_pgmajfault{job="node"}                                    # 缺页激增
rate(container_memory_working_set_bytes{name=~"kube-apiserver"}[5m])  # apiserver 增长趋势
# 事件流
increase(kube_pod_container_status_restarts_total{node="m01"}[1h]) > 3
```

告警阈值建议：
- MemAvailable < 15% → Warning
- MemAvailable < 5% → Critical（立即介入）
- 单容器 RSS > limit 的 80% → Warning
- 节点重启 / apiserver 重启 > 3 次/小时 → Critical

---

## 附录：采集命令速查

```bash
free -h                          # 总体
cat /proc/meminfo                # 细项
ps -eo pid,ppid,user,rss,nlwp,pcpu,comm --sort=-rss | head -30   # 进程 TOP
ps -eLo pid,tid,pcpu,comm --sort=-pcpu | head -20                # 线程 TOP
crictl stats                     # 容器内存
crictl ps -o table               # 容器列表
kubectl top pods -A --sort-by=memory                              # Pod TOP
kubectl get pods -A --field-selector spec.nodeName=m01 -o wide    # 本节点 Pod
kubectl get --raw /api/v1/nodes/m01/proxy/configz                 # kubelet 配置
cat /sys/kernel/mm/transparent_hugepage/enabled                   # THP 状态
awk '/^AnonHugePages|^Slab|^Commit/{print}' /proc/meminfo
find /sys/fs/cgroup -name memory.current -exec sh -c 'echo "$(($(cat {})))  {}"' \; 2>/dev/null
```
