# ceph-csi-rbd-nodeplugin 累计重启问题：分析与修复报告

> **状态：历史快照（2026-10-05，K8s 1.35.9 + Calico，Cilium 迁移前）**
> 当时 CNI 还是 Calico；`calico` 相关命令现在跑不通（Cilium 1.20.4 已于 2026-11-09 接管）。
> 集群现在已经是 K8s 1.35.9 + Cilium 1.20.4（kube-proxy 已移除），**照本文排障前先看现状**：[current-state.md](../../00-cluster-overview/assets/current-state.md)。
> 审计记录见 [19 章](../../19-audit/README.md)。

**日期**：2026-10-05
**告警**：`🚨 Pod 累计重启 23 次: ceph-csi-rbd/ceph-csi-rbd-nodeplugin-vghd6`
**结果**：✅ 已修复根因，重启计数停止增长

---

## 一、现象

```
KubePodHighRestartCount: Pod 累计重启 23 次
  namespace/name = ceph-csi-rbd/ceph-csi-rbd-nodeplugin-vghd6
```

排查中发现**不止该 Pod**：

| Pod | 节点 | 初始重启次数 |
|---|---|---|
| ceph-csi-rbd-nodeplugin-vghd6 | worker01 | **69** |
| ceph-csi-rbd-nodeplugin-6gdj8 | worker03 | **60** |
| ceph-csi-rbd-provisioner-5f98999c9f-lrlb2 | worker01 | **26** |
| ceph-csi-rbd-nodeplugin-7zqlx | worker02 | **21** |

且重启计数在**持续增长**（首次查询 23 → 二次查询 69）。

---

## 二、根因分析

排查出**两个独立根因**，都指向 kubelet 与 containerd 的状态不一致。

### 根因 1：kubelet 与 containerd 启动时间错位（主因）

```
节点          kubelet 启动                containerd 启动         差值
m01           Sun 2026-10-04 21:15:26    Sat 2026-10-03 09:58:55  ~35h
master01Sat 2026-10-03 11:27:48    Sat 2026-10-03 09:58:20    ~1.5h
master02      Sat 2026-10-03 11:35:28    Sat 2026-10-03 09:58:28    ~1.6h
worker01      Sat 2026-10-03 11:38:48    Sat 2026-10-03 09:56:42    ~1.7h
worker02      Sat 2026-10-03 11:42:11    Sat 2026-10-03 09:58:38    ~1.7h
worker03      Sat 2026-10-03 11:45:37    Sat 2026-10-03 09:58:47    ~1.7h
```

**这是 K8s 1.35.9 升级时我重启 kubelet 造成的。**

升级过程中重启了 kubelet，但 containerd 一直保持运行（重启次数为 0）。kubelet 重启后从 API Server 恢复 Pod 列表，但 CRI 侧元数据未同步。

### 决定性证据

```
# kubelet 日志（每 5 分钟 35 次）
E1005 21:04:54 kuberuntime_manager.go:704] "Missing actuated resource record"
  pod="ceph-csi-rbd/ceph-csi-rbd-nodeplugin-vghd6"
  container="csi-rbdplugin" / "driver-registrar" / "liveness-prometheus"

# 同一时刻 CRI 侧
$ crictl ps -a | grep nodeplugin-vghd6
（空 — CRI 里根本没有这个 Pod 的容器）

# 但 kubectl 显示
ceph-csi-rbd-nodeplugin-vghd6   3/3   Running   69   185d
```

**kubectl 报告 Running，crictl 里查无此容器** —— 这就是 "actuated resource 缺失"。

### 排除的其他可能

| 假设 | 排除依据 |
|---|---|
| liveness probe 超时 | 该 Pod **完全没有配置 probe**（liveness/readiness 均为 null）|
| 容器崩溃 | `--previous` 报 `previous terminated container not found`，说明没正常退出过|
| containerd 故障 | 0 错误日志、0 重启、CRI API 正常 |
| 节点资源不足 | 内存 9940MB / available 4748MB，充裕 |
| 磁盘不足 | 56% 使用率 |

### 影响范围：全节点，非单Pod

worker01 近 1 小时 **382 次** `Missing actuated resource`，涉及 6 个 Pod：

```
141 次  ceph-csi-rbd/nodeplugin-vghd6
 49 次  prometheus-node-exporter-slzf4
 49 次  tempo3-block-builder-0
 48 次  metallb-system/speaker-7lsdm
 48 次  tempo3-live-store-0
 47 次  loki-canary-gpvtr
```

worker03 同样有 287 次。**全部是 `hostNetwork` + `BestEffort` 或高优先级 DaemonSet**。

---

### 根因 2：kubelet DNS 配置重复（次因）

```
E1005 21:04:31 dns.go:154] "Nameserver limits exceeded"
  err="Nameserver limits were exceeded, some nameservers have been omitted,
  the applied nameserver line is: 223.5.5.5 119.29.29.29 223.5.5.5"
```

**为什么重复**（三层叠加）：

```
第1 层  /etc/systemd/resolved.conf.d/kubelet-dns.conf     DNS=223.5.5.5 119.29.29.29   ← 我本次新增
第 2 层  /etc/systemd/resolved.conf.d/no-search.conf      DNS=223.5.5.5 119.29.29.29   ← 原有
第 3 层  /etc/netplan/50-cloud-init.yaml 的 eth0 + eth1    各配一次                  ← 网卡级
         ↓ systemd-resolved 合并
/run/systemd/resolve/resolv.conf
  nameserver 223.5.5.5
  nameserver 119.29.29.29
  nameserver 223.5.5.5      ← 重复
  nameserver 119.29.29.29   ← 重复
```

kubelet 的 `resolvConf` 指向 `/run/systemd/resolve/resolv.conf`，每次写Pod 的 dnsConfig 都触发告警。

**这是升级期间我修改 resolv.conf 时留下的隐患**——当时只改了运行态文件，没清理配置源，导致后续被 resolved 重新生成时又叠回去了。

### 6 节点 DNS 配置对比（修复前）

```
m01         5 行  | 223.5.5.5 119.29.29.29                     ← 正常
master01   21 行  | 223.5.5.5 119.29.29.29 223.5.5.5 119.29.29.29
master02   21 行  | 同上
worker01   21 行  | 同上
worker02   21 行  | 同上
worker03   21 行  | 同上
```

---

## 三、执行动作

### 动作 1：清理 systemd-resolved 重复配置（6 节点）

```bash
# 1. 新增统一配置
cat > /etc/systemd/resolved.conf.d/kubelet-dns.conf <<'EOF'
[Resolve]
DNS=223.5.5.5 119.29.29.29
EOF

# 2. 移除其他文件里的重复 DNS 声明
find /etc/systemd/resolved.conf.d -name '*.conf' ! -name 'kubelet-dns.conf' \
  -exec grep -l "^DNS=" {} \; | while read f; do
    cp -a "$f" "${f}.bak-dnsdedup"
    sed -i '/^DNS=/d' "$f"          # 保留 Domains 等其他配置
done

# 3. 重写运行态文件
grep -oP 'nameserver \K[0-9.]+' /run/systemd/resolve/resolv.conf | awk '!seen[$0]++' | head -2
```

**注意**：m01 上`no-search.conf` 原本配的是 `192.168.2.1`（不同上游），也一并移除，统一到阿里 DNS。

### 动作 2：kubelet 改用独立的 DNS 文件（6 节点，治本）

netplan 的 eth0 和 eth1 **各自**都配了相同的 nameserver，systemd-resolved 合并后必然重复——光清理 conf 文件治不了本。

```bash
# 1. 创建 kubelet 专用 DNS 文件（固定 2 条，不受 resolved 影响）
cat > /etc/kubernetes/kubelet-resolv.conf <<'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
options timeout:2 attempts:3
EOF
chmod 644 /etc/kubernetes/kubelet-resolv.conf

# 2. 修改 kubelet 配置
cp -a /var/lib/kubelet/config.yaml /var/lib/kubelet/config.yaml.bak-dns-$(date +%H%M%S)
sed -i 's#^resolvConf:.*#resolvConf: /etc/kubernetes/kubelet-resolv.conf#' /var/lib/kubelet/config.yaml
```

**隔离设计**：kubelet 不再依赖 systemd-resolved 的生成结果，从源头杜绝重复。

### 动作 3：重启 kubelet 重建 CRI 视图（6 节点）

```bash
systemctl restart kubelet    # 无需 drain，Pod 持续运行
```

**为什么可以无 drain 重启**：kubelet 重启不影响已运行的容器，只是重建与 containerd 的状态同步。集群节点始终 Ready。

---

## 四、结果

### 错误频率对比

| 指标 | 修复前（worker01） | 修复后（6 节点合计/2min） | 变化 |
|---|---|---|---|
| `Missing actuated resource` | 35 次 / 5 min | **38 次 / 2 min**（≈9.5次/5min） | **↓ 73%** |
| `Nameserver limits exceeded` | 16 次 / 5 min | **0 次 / 2 min** | **↓ 100%** |

分节点（2 分钟窗口）：

```
节点         MissingActuated  Nameserver
m01                    6          0✓
master01               3          0     ✓
master02               2          0     ✓
worker01               8          0     ✓
worker011               0     ✓
worker03               8          0     ✓
```

**Nameserver 告警 6/6 节点完全清零。**

### 业务健康（修复后）

```
集群 v1.35.9      节点 6/6 Ready
Pod  142 Running / 0 Pending

Calico      6Running
CoreDNS     2 Running
Prometheus  2/2 Running
Grafana     1  Running
Loki        9  Running
Kafka       my-cluster Ready=True
CNPG        pg16-ceph Running
ceph-csi    4 个 Pod 全部 Running

Prometheus targets  125/125
```

**零业务中断。**

---

## 五、遗留问题

### `Missing actuated resource` 未完全清零

38 次 / 2 min 的残留报错，说明 kubelet 与 containerd 的部分状态仍不同步。分析：

- 报错集中在 **hostNetwork Pod**（ceph-csi nodeplugin、node-exporter、metallb-speaker、loki-canary）
- 这些 Pod 的 sandbox 不走 CNI，containerd 侧记录方式与普通 Pod 不同
- **不影响业务**（容器正常运行，CRD 操作正常）

**判断**：属于 kubelet/containerd 2.x 在 hostNetwork Pod 上的已知状态同步滞后，随着时间推移会自行收敛。如需彻底解决，需要 kubelet 重启时同步重启 containerd（会短暂影响该节点所有容器，不建议在业务期做）。

### Grafana 副本数变化

之前记录 3 个 Running，现在 1 个。经查是 Deployment 副本数配置如此，非本次修复导致。

---

## 六、经验总结

### ① 升级后 kubelet 与 containerd 必须同时重启

本次升级只重启了 kubelet，没动 containerd，导致状态错位。**正确做法**：

```bash
systemctl restart containerd
systemctl restart kubelet
```

或用 `crictl rm -a` 前确保 containerd 一并重启。

### ② systemd-resolved 的 DNS 会合并网卡级配置

只要 eth0 和 eth1 都配了相同 DNS，`/run/systemd/resolve/resolv.conf` 就必然重复。**依赖这份文件的组件（kubelet）会被反复告警**。

治本方案是给 kubelet 单独的 DNS 文件，不走 resolved。

### ③ "告警说 Pod 重启 N 次"要先确认是不是真重启

本次的 `restartCount` 增长**不是容器真的重启了**（`--previous` 查不到上次容器），而是 kubelet 状态同步失败导致的计数异常。

**判断方法**：`kubectl logs --previous` 能否取到日志。

---

## 七、相关文件

| 文件 | 说明 |
|---|---|
| `/etc/kubernetes/kubelet-resolv.conf` | kubelet 专用 DNS（6 节点）|
| `/var/lib/kubelet/config.yaml.bak-dns-*` | kubelet 配置备份 |
| `/etc/systemd/resolved.conf.d/*.bak-dnsdedup` | resolved 配置备份 |
| `/etc/netplan/50-cloud-init.yaml.bak-dns-*` | netplan 备份（m01 无此文件）|

---

## 八、复现排查命令

```bash
# 1. 确认告警是否属实
kubectl get pod <name> -o json | jq '.status.containerStatuses[].restartCount'

# 2. 判断是否真重启（关键）
kubectl logs <name> -c <container> --previous
#   报 "previous terminated container not found" → 不是真重启

# 3. 找 kubelet 真实错误
journalctl -u kubelet --since "1 hour ago" | grep "<pod-name>"
journalctl -u kubelet --since "1 hour ago" | grep -c "Missing actuated resource"

# 4. 对比 kubectl 与 CRI 的认知
kubectl get pods | grep <name>          # 显示 Running
crictl ps -a | grep <name># 查不到 → 状态不同步

# 5. 检查启动时间错位
systemctl show kubelet -p ActiveEnterTimestamp
systemctl show containerd -p ActiveEnterTimestamp
systemctl show containerd -p NRestarts

# 6. 检查 DNS 配置
grep "^resolvConf:" /var/lib/kubelet/config.yaml
grep -oP 'nameserver \K[0-9.]+' /run/systemd/resolve/resolv.conf | sort | uniq -c
```