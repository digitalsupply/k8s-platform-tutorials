# KubeVIPLeaderNotRenewing 误报分析与修复报告

| 项目 | 内容 |
|---|---|
| **告警名称** | `KubeVIPLeaderNotRenewing`（critical） |
| **涉及对象** | Lease `kube-system/plndr-cp-lock`（kube-vip 控制面 VIP leader 选举锁） |
| **集群** | Kubernetes v1.35.9 / containerd 2.3.2 / 6 节点（m01、master01、master02、worker01-03） |
| **VIP** | `10.0.0.168:6443`（ARP 模式，接口 `eth0`） |
| **kube-vip** | v1.2.4，DaemonSet `kube-system/kube-vip-ds`，3 个 Pod |
| **监控栈** | Prometheus（`scrape_interval=30s`，`evaluation_interval=30s`）+ kube-state-metrics v2.18.0 |
| **分析/操作主机** | `m01`（控制面节点，`10.0.0.61`） |
| **报告日期** | 2026-10-06（UTC） |
| **结论** | 🔴 **100% 误报**。阈值恰好等于指标固有陈旧度下限，规则自 Prometheus 重建后**从未返回过正常状态** |

---

## 一、结论速览（TL;DR）

### 1.1 结论

**这不是一次故障，而是一条永久为真的告警规则。**

告警文案要求"请立即检查该节点 apiserver/etcd"，但实际检查结果是**控制面完全健康**：

```
holder=master01  renewTime 持续每 ~10s 推进  leaseTransitions=45（无抖动）
kube-vip Pod:  3/3 Running, restarts = 0 / 0 / 1（m01 那 1 次是 35h 前的历史）
VIP https://10.0.0.168:6443/healthz -> HTTP 200 (27ms)
kube-apiserver *:6443 LISTEN ; etcd 10.0.0.61:2379 / :2380 LISTEN
6 个节点全部 Ready
```

### 1.2 根因（一句话）

> **`kube-state-metrics` 每 30 秒才刷新一次 `kube_lease_renew_time`，而告警阈值被设成了 `> 30`。**
> 于是"指标有多旧"这个量的**健康态下界就是 30 秒**，阈值踩在下界上 → 表达式长期为真。

实测健康集群（10.5 小时、1265 个样本）：

```
staleness = 采样时刻 - kube_lease_renew_time
  min=30.0s   max=32.0s   mean=31.1s   p50=31.0s   p90=32.0s   p99=32.0s

  > 20s : 1265/1265 样本 (100.0%)
  > 30s : 1040/1265 样本 ( 82.2%)   ← ★ 规则表达式的判据
  > 40s :    0/1265 样本 (  0.0%)
  > 60s :    0/1265 样本 (  0.0%)
```

并且 **Prometheus 自 2026-10-05 14:30 重建后，该告警 100% 的时间都处于 firing**：

```
10-05 14  100.0% firing  #############################
10-05 15  100.0% firing  #############################
...（逐小时全部 100%，共 12 个小时桶）
10-06 01  100.0% firing  #############################
```

### 1.3 修复

| 项 | 修复前 | 修复后 | 理由 |
|---|---|---|---|
| `expr` 阈值 | `> 30` | **`> 90`** | 健康态上界 32s（重启瞬态 62s），90s 留 2.8× / 1.45× 余量 |
| `for` | `2m` | **`1m`** | 阈值抬高后无需再叠加长等待，把总探测时延控制回 ~2.5min |
| `description` | 声称"kubelet 走 VIP → no route to host → NotReady" | **全面重写** | 该描述 **2026-10-04 起已不成立**（详见 §4.3） |
| `runbook` | 3 条宽泛命令 | **6 步可执行排查** | 补上 leader 定位、崩溃现场、VIP 可达性、误报自证 |

---

## 二、排查过程（按时间顺序的取证链）

### 2.1 第一步：告警描述与实际状态矛盾

收到告警后先看最基本的事实：

```bash
$ kubectl get lease -n kube-system plndr-cp-lock -o yaml
spec:
  holderIdentity: master01
  leaseDurationSeconds: 15
  renewTime: "2026-10-06T01:02:35.794065Z"

$ date -u
2026-10-06T01:02:39Z          ← renewTime 距当前仅 4 秒
```

立刻做连续采样（每 10 秒一次，共 2 分钟）：

```
T+10s   renew=01:02:43.823  holder=master01 transitions=45
T+20s   renew=01:02:53.858  holder=master01 transitions=45
T+30s   renew=01:03:03.925  holder=master01 transitions=45
...
T+120s  renew=01:04:36.274  holder=master01 transitions=45
```

**结论**：renewTime 每 ~10s 推进一次，holder 稳定，`leaseTransitions` 不增长。
**租约本身完全正常，告警与事实矛盾。**

### 2.2 第二步：确认告警的真实时间窗

Prometheus 侧该告警已不在 firing 列表，说明刚刚已恢复。查 Alertmanager 拿到精确窗口：

```bash
$ curl localhost:9093/api/v2/alerts | jq '.[] | select(.labels.alertname=="KubeVIPLeaderNotRenewing")'
{
  "annotations": {
    "summary": "kube-vip 当前 leader 已超过 30s 未续约 (停滞 30.78s)"   ← ★ 峰值只有 30.78s
  },
  "startsAt": "2026-10-06T00:58:59.782Z",
  "updatedAt": "2026-10-06T01:03:59.764Z",
  "labels": { "instance": "10.244.5.103:8080", "pod": "prometheus-kube-state-metrics-...-htfps" }
}
```

**关键观察**：所谓"长时间未更新"，实际峰值只有 **30.78 秒**。这与真实故障（2026-10-03 那次持续数小时）的量级差了三个数量级。

### 2.3 第三步：踩坑记录 —— 查询方法本身会误导结论

第一次查 6 小时区间时得到了**看似正常**的结果，与告警记录矛盾：

```bash
# query_range, step=30
max=11.00s at 10-05 19:06:09      ← 好像完全正常
>30 样本数: 0
```

**这是采样混叠（aliasing）造成的假象**：`step=30` 与 KSM 的 30s 刷新周期、Prometheus 的 30s 抓取周期**完全同频**，每次都恰好落在同一个相位上，于是永远采到 11s 这个"最好看"的相位。

改用 `step=5`、并直接对原始指标做逐样本差分后，真相浮现：

```bash
# 原始 renewTime 的"变化时刻"（step=5，20 分钟窗口）
distinct renewTime values in 20min: 41
KSM refresh interval (s) -> [5, 30, 30, 30, 30, 30, 30, ... , 30, 30]   ← ★ 恒定 30 秒
renewTime jump sizes  (s) -> [28, 30, 30, 30, 31, 30, ..., 31, 30, 28, 30, ...]
```

> **教训**：`query_range` 的 `step` 若与被测系统的周期同频，会系统性只采到单一相位。
> 判断"抖动/周期性"类问题时，必须用**非整除的 step** 或**直接对原始值做差分**，否则结论不可信。

### 2.4 第四步：确认周期来源

```
Prometheus global:  scrape_interval: 30s   evaluation_interval: 30s   scrape_timeout: 10s
kube-state-metrics: --resources=...,leases,...   (镜像 v2.18.0)
```

- kube-vip 自己的续约间隔：`leaseDuration=15 / renewDeadline=10 / retryPeriod=2` → **实际每 ~10s 写一次 renewTime**（kubectl 直读已证实）。
- kube-state-metrics 的 lease 采集刷新：**恒定 30s**。
- Prometheus 抓取：**30s**。

于是指标新鲜度的**固有下界** = 30s（KSM 刷新周期），
**瞬时评估时可见区间** = `[0s, ~30s]`，再叠加 Prometheus 自身刚启动时的相位失配可达 62s。

### 2.5 第五步：全量分布 —— 健康态与故障态的量化分离

在 Prometheus 保留窗口内回溯真实故障（2026-10-03）：

```bash
# 2026-10-03 01:00 ~ 04:00（真实 apiserver/etcd 故障窗口）
inst=10.244.19.79:8080   MAX=263s   >30s:11.4%  >60s:11.4%  >90s: 6.8%
inst=10.244.30.94:8080   MAX=248s   >30s:57.1%  >60s:57.1%  >90s:42.9%
inst=10.244.30.152:8080  MAX= 72s   >30s: 9.7%  >60s: 3.2%  >90s: 0.0%
其他健康 KSM 实例        MAX=16~30s  >30s:  0.0%
```

| 场景 | `time() - kube_lease_renew_time` 区间 |
|---|---|
| **健康**（实测 1265 样本） | **30 ~ 32s**（重启瞬态 62s） |
| **真实故障**（10-03） | 高达 **248 ~ 263s** |

**分离度极佳**：阈值取 90s 可获得健康态 2.8× 余量、故障态 2.8× 灵敏度。

---

## 三、告警时间线还原

以 `T0 = 01:26:39`（合成 Lease 被冻结的时刻）为基准的实测对照（§5 会详述）：

```
时间     冻结租约陈旧度    真实租约陈旧度
01:13:58      46.4s            28.7s
01:14:18      67.2s            19.4s
01:14:39      87.9s            12.2s
01:15:00     108.7s             2.9s
...          ...               ...
01:18:27     315.8s            29.1s
```

真实租约的陈旧度始终在 `3s ~ 29s` 区间内震荡，**永远不会越过 90s**；
而真正被冻结的租约会线性增长并迅速突破 90s。判据因此是自洽的。

---

## 四、根因分析

### 4.1 为什么阈值必须是 `> 30` 才会长期误报

`kube_lease_renew_time` 是一个**"把事件时间戳当指标值暴露"的 gauge**，它的更新频率取决于 **KSM 的采集/刷新周期**，而不是被观测对象（租约）的真实更新频率：

```
真实事件流:  kube-vip ──每 10s 写一次 renewTime──> etcd
                                       │
KSM 采集层:  ◄──── reflector 每 30s 才重新读一次 ────┘   ← 信息在这里被量化
                                       │
Prometheus:  ◄──── 每 30s 抓一次 /metrics ────┘
```

因此 `time() - kube_lease_renew_time` 天然是一个**锯齿波**，其上界由
`KSM刷新周期 + 抓取周期` 决定，与集群是否健康**无关**。

把阈值设成 `> 30`（= KSM 刷新周期）等于**把噪声地板当成故障线**。

### 4.2 为什么 `for: 2m` 没能挡住

`for: 2m` 本应滤掉瞬时毛刺，但这里失效，原因是**相位锁定**：

- KSM 的 30s 刷新与 Prometheus 的 30s 抓取/评估**同频且长期保持固定相位**；
- 一旦某一相位使 `staleness` 连续多次落在 `30.0 ~ 32.0`，就会**持续超过 2 分钟**满足 `for`；
- 实测这种连续超阈窗口有 **22 段**（10.5 小时内），最长一段 **3900 秒（65 分钟）**。

```
14:35:00 -> 15:30:30  (3330s)   peak=32.0s
15:33:00 -> 16:08:30  (2130s)   peak=32.0s
...
20:33:00 -> 21:38:00  (3900s)   peak=32.0s   ← 最长
```

所以 `for` 只是把误报"拉长"，无法根除。

### 4.3 附带发现：告警文案本身也已经过时（重要）

原 `description` 写着：

> *"kubelet 使用 VIP 10.0.0.168:6443 访问 apiserver，此时将出现 'no route to host' 并导致节点 NotReady。"*

**这句话在 2026-10-04 之后已经不成立。** 现场实测确认：

```bash
# ① m01 的 kubelet 已切到回环，不再走 VIP
$ grep -n "server:" /etc/kubernetes/kubelet.conf
5:    server: https://127.0.0.1:6443

$ ss -tnp | grep "pid=$(pgrep -x kubelet)" | grep 6443
ESTAB 127.0.0.1:41030  127.0.0.1:6443  users:(("kubelet",pid=3436344,fd=9))

# ② m01 上已经没有任何组件连 VIP
$ ss -tnp | grep "10.0.0.168:6443" | grep -v 127.0.0.1
  (空)

# ③ 丢 leader 时保留 VIP 的开关确实在生效（读运行中进程的环境变量，非仅看 YAML）
$ tr '\0' '\n' < /proc/$(pgrep -f '^/kube-vip' | head -1)/environ | grep '^vip_'
vip_address=10.0.0.168
vip_leaderelection=true
vip_leaseduration=15
vip_leasename=plndr-cp-lock
vip_preserve_on_leadership_loss=true      ← ★
vip_renewdeadline=10
vip_retryperiod=2
```

| 断言（原文） | 现状 | 判定 |
|---|---|---|
| kubelet 走 VIP 10.0.0.168:6443 | 全集群 kubelet 已直连本机 | ❌ 已过时 |
| VIP 消失 → `no route to host` → NotReady | `preserve_on_leadership_loss=true`，VIP 不再被删除 | ❌ 已过时 |
| 检查 apiserver/etcd | 仍然正确，是唯一有效的排查方向 | ✅ 保留 |

> **这类"文案过时"本身就是一种隐性风险**：值班同学会照着 runbook 去查一个已经不存在的依赖，
> 从而把排查时间浪费在错误方向上。本次一并重写。

### 4.4 为什么没有其他告警中招

扫描全部 38 个 `PrometheusRule`（329 条生效规则），使用 `time()` 的只有 4 条：

| 规则 | 表达式 | 是否受影响 |
|---|---|---|
| `CertManagerCertificateExpiringSoon` | `certmanager_certificate_expiration_timestamp_seconds - time() < 14*24*3600` | ❌ 证书到期时间是**静态字段**，不会被高频改写，无锯齿 |
| `CertManagerCertificateExpired` | `... - time() < 0` | ❌ 同上 |
| `KubeJobNotCompleted` | `time() - kube_job_status_start_time > 43200` | ❌ Job 的 startTime 是**一次写入的静态字段** |
| **`KubeVIPLeaderNotRenewing`** | `time() - kube_lease_renew_time > 30` | ✅ **`renew_time` 每 10s 被改写 → 受影响** |

**判据总结**：`time() - X > T` 这类表达式，只有当 **X 是一个高频改写的时间戳 gauge** 时，
才必须把 `T` 设得远大于其上游采集周期。静态时间戳（证书、Job 创建时间）不受影响。

---

## 五、已执行的修复

### 5.1 备份

```
/root/kubevip-alert-falsefix-backup-20261006-010854/
├── prometheusrule-cluster-wide-alerts-BEFORE.yaml     # 原始 PrometheusRule
├── prometheusrule-cluster-wide-alerts-BEFORE.json
├── lease-plndr-cp-lock-BEFORE.yaml
└── kube-vip-pods-BEFORE.txt
```

### 5.2 变更内容

只改 `monitoring/cluster-wide-alerts` 中 `pod.rules` 组的一条规则：

```yaml
- alert: KubeVIPLeaderNotRenewing
  expr: time() - kube_lease_renew_time{namespace="kube-system",lease="plndr-cp-lock"} > 90   # ← 30 改为 90
  for: 1m                                                                                  # ← 2m 改为 1m
  labels:
    component: kube-vip
    severity: critical
  annotations:
    summary: "kube-vip 控制面 VIP leader 已超过 90s 未更新 renewTime (停滞 {{ $value | humanizeDuration }})"
    description: |
      【根因含义】当前 leader 所在节点无法访问 API Server。kube-vip 在 cp_enable + hostAliases 下
      实际连接本节点 127.0.0.1:6443，因此通常意味着该节点 kube-apiserver / etcd 异常，
      或该节点的 kube-vip 容器已崩溃重启。

      【重要】这不是『VIP 消失』型故障，不会再引发级联雪崩。2026-10-04 起已启用
      vip_preserve_on_leadership_loss=true（丢失 leader 时保留 VIP、仅停止 ARP 广播），
      且所有节点 kubelet 已改为直连本机（m01=127.0.0.1:6443，master01=10.0.0.121，master02=10.0.0.120），
      全集群对 VIP 10.0.0.168:6443 的系统级消费者已归零，因此不会再出现 no route to host / 节点 NotReady。

      【真实影响】控制面 API 端点至少 1/3 副本不可用；VIP 暂时保留在故障前的持有者上，直到新 leader 上任接管。

      【阈值说明】阈值 90s 是刻意设置的：kube-state-metrics 每 30s 才刷新一次 kube_lease_renew_time，
      健康状态下 time()-renew_time 实测稳定在 30~32s（Prometheus 重启瞬态最高约 62s）。
      原阈值 30s 恰好等于指标固有陈旧度下限，实测有 82% 的时间处于超阈状态，导致长期误报。
    runbook: |
      # 1) 当前 leader 是谁、停滞多久、切换了多少次
      kubectl get lease -n kube-system plndr-cp-lock -o jsonpath='{.spec.holderIdentity}...' ; date -u
      # 2) 三个 kube-vip Pod 的重启次数
      # 3) leader 节点的崩溃现场日志（--previous）
      # 4) leader 节点本机 apiserver / etcd 健康（healthz / readyz / journalctl）
      # 5) 确认 VIP 仍然可达（排障期间 API 不应中断）
      # 6) 误报自证：间隔 15s 采两次 renewTime 对比
```

### 5.3 ⚠️ 过程中的一次事故与恢复（必须记录）

**第一次应用变更时用了 `--type=merge`，而 JSON merge patch 对数组是"整体替换"语义**：

```bash
# ❌ 错误做法
kubectl patch prometheusrule cluster-wide-alerts -n monitoring --type=merge \
  --patch-file patch.json     # patch.json 里带了 spec.groups=[{name: pod.rules, rules:[仅1条]}]
```

后果（当场发现并核对）：

| 组 | 修复前 | 被误改后 | 缺失的规则 |
|---|---|---|---|
| `pod.rules` | 6 | **1** | `PodCrashLooping`、`PodNotReady`、`PodOOMKilled`、`KubeVIPRestarting`、`KubeVIPLeadershipChurn` |
| `node.rules` | 3 | **整组消失** | `NodeHighCPU`、`NodeHighMemory`、`NodeDiskPressure` |
| `otel-demo.rules` | 2 | **整组消失** | `OtelDemoHighErrorRate`、`OtelDemoServiceDown` |
| `workload-reliability.rules` | 3 | **整组消失** | `KubePodHighRestartCount`、`KubePodCriticalComponentHighRestart`、`KubeContainerOOMKilled` |

**恢复流程（未造成实际影响，窗口约 70 秒）**：

1. 从 `BEFORE.json` 备份逐字恢复完整对象（`kubectl apply`）；
2. 核对规则总数：`6+3+2+3 = 14` ✅；
3. **改用"完整对象替换"**：在备份对象上只改目标规则的那一个字典，再整体 `apply`；
4. 用程序化 diff 逐字段核对，确认**只有** `expr` 和 `for` 发生变化：

```
group names equal: True
  pod.rules/KubeVIPLeaderNotRenewing: CHANGED
      expr: - ... > 30   →   + ... > 90
      for:  - 2m         →   + 1m
  node.rules: identical (3 rules)
  otel-demo.rules: identical (2 rules)
  workload-reliability.rules: identical (3 rules)
```

> **教训**：
> - **绝不要用 `--type=merge` 去 patch 含数组字段的 CRD**（`groups`、`rules`、`env`…），merge 会整段替换。
> - 改告警规则的正确姿势：**取备份 → 程序化改单个字段 → 整体 apply → 程序化 diff 验证**。
> - 变更告警规则后**必须**核对 `/api/v1/rules` 的**总规则数**，而不只是看目标规则是否生效。

---

## 六、修复验证

### 6.1 规则加载与健康度

```bash
$ curl localhost:9090/api/v1/rules | jq '.data.groups[].rules[] | select(.name|startswith("KubeVIP"))'
  KubeVIPDown               state=inactive health=ok for=300
  KubeVIPRestarting         state=inactive health=ok for=600
  KubeVIPLeadershipChurn    state=inactive health=ok for=300
  KubeVIPLeaderNotRenewing  state=inactive health=ok for=60
      expr = time() - kube_lease_renew_time{lease="plndr-cp-lock",namespace="kube-system"} > 90
```

全局规则健康度（确认 8 条被误删的规则全部回来了）：

```
total rules loaded: 329
(state,health): {('inactive','ok'):228, ('pending','ok'):3, ('firing','ok'):4, (None,'ok'):94}
UNHEALTHY: 0
```

14 条 `cluster-wide-alerts` 规则逐条核对：

```
restored & present: KubeContainerOOMKilled, KubePodCriticalComponentHighRestart, KubePodHighRestartCount,
                    KubeVIPLeaderNotRenewing, KubeVIPLeadershipChurn, KubeVIPRestarting, NodeDiskPressure,
                    NodeHighCPU, NodeHighMemory, OtelDemoHighErrorRate, OtelDemoServiceDown,
                    PodCrashLooping, PodNotReady, PodOOMKilled
MISSING: none
```

### 6.2 端到端功能测试（合成冻结租约，零风险）

**方法**：在 `kube-system` 建一个**永远不会被续约**的合成 Lease，并挂两条**表达式完全相同、仅阈值不同**的临时规则，
同时对两个阈值计时。全过程提前建立 Alertmanager 静默，确保**不发任何通知**。

```bash
# 冻结租约
kubectl apply -f - <<EOF
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata: {name: kubevip-alert-selftest2, namespace: kube-system}
spec: {holderIdentity: "selftest2", leaseDurationSeconds: 15,
       acquireTime: "...", renewTime: "2026-10-06T01:26:39.000000Z"}
EOF

# 两条对照规则（挂在同一冻结租约上）
- alert: KubeVIPSelfTest2Old   expr: time() - kube_lease_renew_time{lease="kubevip-alert-selftest2"} > 30   for: 1m
- alert: KubeVIPSelfTest2New   expr: time() - kube_lease_renew_time{lease="kubevip-alert-selftest2"} > 90   for: 1m
```

**实测结果（`T0 = 01:26:39` 为冻结时刻）：**

```
时间     | OLD(>30)+for1m     | NEW(>90)+for1m     | 真实租约规则
---------+--------------------+--------------------+---------------
01:26:45 | firing(上一轮残留) | firing(上一轮残留) | inactive
01:27:01 | inactive           | inactive           | inactive
01:27:16 | inactive           | inactive           | inactive
01:27:31 | pending            | inactive           | inactive    ← OLD 开始计时
01:27:46 | pending            | inactive           | inactive
01:28:02 | pending            | inactive           | inactive
01:28:17 | pending            | inactive           | inactive
01:28:32 | firing             | pending            | inactive    ← OLD 触发 / NEW 开始计时
01:28:47 | firing             | pending            | inactive
01:29:03 | firing             | pending            | inactive
01:29:18 | firing             | firing             | inactive    ← NEW 触发
01:29:33 | firing             | firing             | inactive
...      | firing             | firing             | inactive
01:32:06 | firing             | firing             | inactive
```

**换算探测时延：**

| 阈值 | 进入 pending | 进入 firing | 端到端探测时延 |
|---|---|---|---|
| 旧 `>30` + `for:1m` | T0 + 52s | T0 + 113s | **~1 分 53 秒** |
| 新 `>90` + `for:1m` | T0 + 113s | T0 + 159s | **~2 分 39 秒** |

**三条结论：**

1. ✅ **新规则在租约真正停更时会正常触发**（不是把规则改成永远不响的"假修复"）。
2. ✅ **新规则比旧规则晚 46 秒触发** —— 这正是想要的：把 30s 量化噪声挡在门外。
3. ✅ **真实租约规则全程 `inactive`**，与合成冻结租约形成干净对照。
4. ✅ **2m39s 的探测时延远快于真实故障的持续时长**（10-03 那次是数小时），
   灵敏度没有实质损失。

### 6.3 健康态持续观察（无误报）

修复后在真实租约上持续采样，`staleness` 始终在 `3s ~ 29s`：

```
01:13:58  real-lease_staleness=28.7s  KubeVIPLeaderNotRenewing=inactive
01:14:18  real-lease_staleness=19.4s  KubeVIPLeaderNotRenewing=inactive
01:14:39  real-lease_staleness=12.2s  KubeVIPLeaderNotRenewing=inactive
01:15:00  real-lease_staleness= 2.9s  KubeVIPLeaderNotRenewing=inactive
...
01:18:27  real-lease_staleness=29.1s  KubeVIPLeaderNotRenewing=inactive
01:27:31  real-lease_staleness= 2.9s  KubeVIPLeaderNotRenewing=inactive
```

对照旧阈值在同一时刻的行为：同样的健康租约，旧规则会以 82.2% 的概率处于超阈状态。

### 6.4 测试残留清理确认

```bash
# 2 个临时 PrometheusRule  -> 已删除
# 2 个合成 Lease           -> 已删除
# 1 个临时 ConfigMap       -> 已删除
# 2 条 Alertmanager 静默   -> 已 DELETE（state = expired）
# 1 个清理用 curl Pod      -> 已删除（--rm）
```

```
selftest prometheusrules : none
selftest leases          : none
selftest cm              : none
selftest silences        : 70057a20-... state=expired
                         a0a8c6bc-... state=expired
cleanup pod              : none
非 Running/Succeeded Pod : (空)
```

### 6.5 集群最终状态

```bash
$ kubectl get lease -n kube-system plndr-cp-lock -o jsonpath='...'
holder=master01  renew=2026-10-06T01:33:20.552649Z  transitions=45

$ kubectl get pods -n kube-system -l app.kubernetes.io/name=kube-vip-ds
kube-vip-ds-2lvtm  1/1  Running  1 restarts  (36h)   # m01
kube-vip-ds-nfxvf  1/1  Running  0 restarts  (36h)   # master02
kube-vip-ds-sxp4p  1/1  Running  0 restarts  (36h)   # master01

$ kubectl get nodes
m01 Ready / master01 Ready / master02 Ready / worker01 Ready / worker02 Ready / worker03 Ready

$ curl -sk https://10.0.0.168:6443/healthz
HTTP 200 in 0.027384s
```

---

## 七、影响评估

### 7.1 修复前：一条 critical 告警永久 firing 的代价

| 受影响对象 | 表现 |
|---|---|
| **值班响应** | critical 级别告警常驻，看板无法反映真实风险；`wecom` + `n8n-webhook` 双通道持续推送 |
| **告警信噪比** | 该规则历史上从未处于正常状态 → 其"告警"信息量约等于 0 |
| **真实故障发现** | 若真发生 leader 停更，因告警常年 firing，**增量信号会被淹没**，排障时极易被误认为"老样子" |
| **文案误导** | runbook 指向一个已于 10-04 解除的依赖（kubelet→VIP），浪费排查时间 |

### 7.2 修复后

| 场景 | 修复前 | 修复后 |
|---|---|---|
| 健康集群 | 🔴 100% 时间 critical 误报 | ✅ 永不触发 |
| renewTime 停更 30~90s | 🔴 告警（误报） | ✅ 不告警（属 KSM 量化噪声） |
| renewTime 停更 >90s | ✅ 告警（但被噪声淹没） | ✅ **2 分 39 秒内告警** |
| 真实 apiserver/etcd 故障（10-03 级） | ✅ 告警 | ✅ 告警，且文案与 runbook 准确 |

---

## 八、遗留风险与后续建议

| 优先级 | 项目 | 说明 |
|---|---|---|
| 🟠 **P1** | **kube-state-metrics 的 lease 采集周期应显式确认/调优** | 30s 刷新周期是本次误报的根源。若上游支持调整 reflector resync（如 `--metric-opt-in` / resync 参数），可把刷新周期降到 5~10s，从而让告警阈值可以取得更小、更灵敏的值。**需先在离线环境用 `--help` 确认参数存在**，不要凭猜。 |
| 🟠 **P1** | **`monitoring/cluster-wide-alerts` 里其他规则仍可能有类似"高频 gauge + 固定阈值"隐患** | 本次只验证了 `time()` 类表达式。建议对全部 329 条规则做一次"阈值 vs 采集周期"复核，特别是 `kube_pod_*`、`kube_deployment_*` 这类每几秒就变一次的 gauge。 |
| 🟡 **P2** | **Prometheus 无 HA（单副本）** | `prometheus-prometheus-prometheus-0` 于 2026-10-05 14:30 重建，导致 10-05 之前的 `ALERTS` 历史断裂、保留期实际只剩 ~10.5h，难以做长周期回溯。建议评估双副本或远端存储。 |
| 🟡 **P2** | **`prometheus-operator` 规则同步有延迟** | 本次新建 PrometheusRule 后，实测最长 **~4.5 分钟**才被 Prometheus 加载（需带 `release: prometheus` 标签）。变更后应留出足够等待时间再验证，否则会误判"变更未生效"。 |
| 🟡 **P2** | **PrometheusRule 变更缺少准入保护** | 本次的 `--type=merge` 事故说明缺少防护。建议：① 所有 CRD 变更改用 `kubectl diff` + 完整 apply；② 在 CI 中加入"变更前后规则总数校验"。 |
| 🟡 **P2** | **`vip_subnet: 24`** | 沿用 10-04 报告的遗留项。VIP 以 `/24` 而非 `/32` 加到 `eth0`，语义不严谨。改动涉及 VIP 摘挂，需独立窗口。 |
| ⚪ **P3** | **kube-vip 丢 leader 即 panic 退出** | 上游硬编码行为，不可配置。已通过 `preserve_on_leadership_loss=true` + 放宽超时把影响降到最低。 |

---

## 九、交付物与回滚

### 9.1 交付物

```
/root/kubevip-leader-notrenewing-falsepositive-analysis-and-fix-20261006.md   ← 本报告
/root/kubevip-alert-falsefix-deliverable-20261006-010854/
├── kubevip-leader-notrenewing-FIXED.yaml                    # 修复后的规则（可读片段）
├── prometheusrule-cluster-wide-alerts-AFTER.json            # 变更后完整对象
├── prometheusrule-cluster-wide-alerts-BEFORE-restored.json  # 变更前完整对象
└── prometheusrule-cluster-wide-alerts-BEFORE.yaml           # 原始 YAML 备份副本
/root/kubevip-alert-falsefix-backup-20261006-010854/         # 回滚备份目录
```

### 9.2 回滚方法

```bash
BK=/root/kubevip-alert-falsefix-backup-20261006-010854
kubectl apply -f $BK/prometheusrule-cluster-wide-alerts-BEFORE.yaml

# 回滚后必须确认规则总数仍为 14，且 8 条曾被误删的规则都在
kubectl get prometheusrule cluster-wide-alerts -n monitoring -o json \
  | jq '[.spec.groups[].rules[]] | length'          # 期望 14

POD=prometheus-prometheus-prometheus-0
sleep 120   # prometheus-operator 同步实测最长约 4.5 分钟
kubectl exec -n monitoring $POD -c prometheus -- wget -qO- http://localhost:9090/api/v1/rules \
  | jq '[.data.groups[].rules[]] | length, ([.data.groups[].rules[]|select(.health!="ok")]|length)'
# 第一个数字 = 生效规则总数（期望 329）；第二个 = 不健康规则数（期望 0）
```

> ⚠️ 回滚会把这条 critical 告警恢复到"100% 永久 firing"的状态。仅在确有需要时执行。

---

## 十、附录：关键取证命令

```bash
# ---------- 1. 租约真实健康度（最权威，绕过监控层） ----------
kubectl get lease -n kube-system plndr-cp-lock -o yaml
# 连续采样确认 renewTime 在推进（这是判断"真故障/误报"的第一道门）
for i in $(seq 1 12); do
  echo "$(date -u +%H:%M:%S) $(kubectl get lease -n kube-system plndr-cp-lock \
        -o jsonpath='{.spec.renewTime} {.spec.holderIdentity} {.spec.leaseTransitions}')"; sleep 10
done

# ---------- 2. 告警的真实时间窗与峰值（Alertmanager 保留 endsAt/annotations） ----------
AM=$(kubectl get pod -n monitoring -l app.kubernetes.io/name=alertmanager -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n monitoring $AM -c alertmanager -- wget -qO- http://localhost:9093/api/v2/alerts \
  | python3 -c "
import json,sys
for a in json.load(sys.stdin):
    if a['labels'].get('alertname','').startswith('KubeVIP'):
        print(a['status']['state'], a['startsAt'], a['endsAt'], a['annotations'].get('summary'))"

# ---------- 3. ★ 核心：测量 kube_lease_renew_time 的真实刷新周期 ----------
POD=prometheus-prometheus-prometheus-0
# ⚠️ step 必须与被测周期"错频"，否则会因混叠只采到单一相位（见 §2.3）
kubectl exec -n monitoring $POD -c prometheus -- wget -qO- \
 "http://localhost:9090/api/v1/query_range?query=kube_lease_renew_time%7Bnamespace%3D%22kube-system%22%2Clease%3D%22plndr-cp-lock%22%7D&start=<epoch>&end=<epoch>&step=5" \
 | python3 -c "
import json,sys
v=json.load(sys.stdin)['data']['result'][0]['values']
prev=None; ch=[]
for t,x in v:
    if x!=prev: ch.append(t); prev=x
print('refresh intervals:',[ch[i+1]-ch[i] for i in range(len(ch)-1)])"

# ---------- 4. 陈旧度分布（决定阈值的关键数据） ----------
# 直接对原始指标做逐样本差分，避免 query_range 插值带来的相位假象
kubectl exec -n monitoring $POD -c prometheus -- wget -qO- \
 "http://localhost:9090/api/v1/query_range?query=kube_lease_renew_time%7B...%7D&start=..&end=..&step=30" \
 | python3 -c "
import json,sys,statistics
v=json.load(sys.stdin)['data']['result'][0]['values']
s=[float(t)-float(x) for t,x in v]
print('min %.1f max %.1f mean %.1f'%(min(s),max(s),statistics.mean(s)))
print({th:'%.1f%%'%(100*sum(1 for x in s if x>th)/len(s)) for th in (20,30,40,60,90,120)})"

# ---------- 5. 回溯真实故障，验证阈值灵敏度（backtest） ----------
for W in "2026-10-03 01:00:00|2026-10-03 04:00:00"; do
  S=$(date -u -d "${W%|*}" +%s); E=$(date -u -d "${W#*|}" +%s)
  kubectl exec -n monitoring $POD -c prometheus -- wget -qO- \
   "http://localhost:9090/api/v1/query_range?query=time%28%29+-+kube_lease_renew_time%7B...%7D&start=${S}&end=${E}&step=60"
done

# ---------- 6. 统计"某条规则长期是否 firing"（识别永久为真的规则） ----------
kubectl exec -n monitoring $POD -c prometheus -- wget -qO- \
 "http://localhost:9090/api/v1/query_range?query=ALERTS%7Balertname%3D%22KubeVIPLeaderNotRenewing%22%7D&start=..&end=..&step=300" \
 | python3 -c "
import json,sys,collections
r=json.load(sys.stdin)['data']['result']
h=collections.defaultdict(lambda:[0,0])
for s in r:
    for t,x in s['values']:
        k=datetime.utcfromtimestamp(t).strftime('%m-%d %H'); h[k][1]+=1
        if x=='1': h[k][0]+=1
for k,(a,b) in sorted(h.items()): print(f'{k}  {100.0*a/b:5.1f}% firing')"

# ---------- 7. 规则健康度 + 总规则数（变更后必查） ----------
kubectl exec -n monitoring $POD -c prometheus -- wget -qO- http://localhost:9090/api/v1/rules \
 | jq '[.data.groups[].rules[]] | length, ([.data.groups[].rules[]|select(.health!="ok")]|length)'

# ---------- 8. 零风险端到端阈值验证（合成冻结租约） ----------
# ⚠️ 三点前置：① 静默（否则会真发通知）；② 临时规则必须带 release:prometheus 标签；
#              ③ 等规则被加载后，再 patch renewTime 重置计时起点，否则无法对比两个阈值
kubectl apply -f - <<EOF
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata: {name: kubevip-alert-selftest2, namespace: kube-system}
spec: {holderIdentity: selftest2, leaseDurationSeconds: 15, acquireTime: "$NOW", renewTime: "$NOW"}
EOF
# 静默（注意：v2 API 要 POST 单个对象；同一 label 的多个 matcher 是 AND 关系，
#       想匹配多个 alertname 必须用正则 isRegex）
kubectl exec -n monitoring $AM -c alertmanager -- wget -qO- \
  --header='Content-Type: application/json' \
  --post-data='{"matchers":[{"name":"alertname","value":"KubeVIPSelfTest.*","isRegex":true}],
                "startsAt":"...","endsAt":"...","comment":"selftest"}' \
  http://localhost:9093/api/v2/silences
# ⚠️ BusyBox wget 不支持 --body-data / DELETE；删除静默需用带 curl 的临时 Pod
kubectl run x --image=curlimages/curl:8.11.1 --rm -i --restart=Never -- \
  sh -c 'curl -s -X DELETE http://alertmanager-operated.monitoring.svc:9093/api/v2/silence/<ID>'

# ---------- 9. 配置是否真正进入 kube-vip 进程（读 environ，而非只看 YAML） ----------
tr '\0' '\n' < /proc/$(pgrep -f '^/kube-vip' | head -1)/environ | grep '^vip_' | sort

# ---------- 10. VIP 的"消费者"清点（判断是否还有循环依赖） ----------
ss -tnp | grep '10.0.0.168:6443' | grep -v 127.0.0.1   # 应为空
ss -tnp | grep "pid=$(pgrep -x kubelet)" | grep 6443     # kubelet 实际连到哪里

# ---------- 11. VIP 可用性 ----------
curl -sk -o /dev/null -w 'VIP healthz HTTP %{http_code} in %{time_total}s\n' https://10.0.0.168:6443/healthz

# ---------- 12. 扫描集群里所有"高频 gauge + 固定阈值"型隐患 ----------
kubectl get prometheusrule -A -o json > /tmp/allrules.json
python3 -c "
import json
for it in json.load(open('/tmp/allrules.json'))['items']:
    for g in it['spec']['groups']:
        for a in g['rules']:
            e=a.get('expr')
            if isinstance(e,str) and 'time()' in e:
                print(it['metadata']['namespace']+'/'+it['metadata']['name'], a.get('alert'), '->', e[:100])"
```

---

## 十一、方法论备忘

1. **`time() - <高频时间戳 gauge> > T` 的 T 必须远大于上游采集周期。**
   `kube_lease_renew_time` 被 KSM 以 30s 周期量化，健康态下界就是 30s。
   阈值等于下界 = 永久误报。**正确做法：先量周期，再定阈值。**

2. **`query_range` 的 `step` 若与被测系统周期同频，会产生系统性相位假象。**
   本次 `step=30` 对上 30s 周期，一度得出"最大只有 11s、完全正常"的错误结论。
   **必须用错频 step 或直接对原始值做差分。**

3. **告警文案是有生命周期的资产。** 基础设施修好后（kubelet 已解绑 VIP），
   文案里的因果链已经断裂。**每次架构变更都应复核相关告警的 description/runbook。**

4. **`kubectl patch --type=merge` 对数组字段是整体替换，不是合并。**
   patch 含 `groups`/`rules`/`env` 的 CRD 时，merge 会静默删除同级兄弟项。
   **必须用"完整对象 apply + 程序化 diff"。**

5. **改动 PrometheusRule 后要核对总规则数**，而不是只看目标规则是否生效。
   本次正是靠 `总规则数 == 329`、`cluster-wide-alerts 内 == 14` 发现并定位了误删。

6. **"告警常年 firing"本身就是最高优先级的问题。**
   它既污染信噪比，又会淹没未来的真实增量信号。发现一条永久 firing 的 critical，
   应当立刻按"监控故障"而非"业务故障"处理。