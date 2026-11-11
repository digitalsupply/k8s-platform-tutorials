# G1 审计发现：docs/00-cluster-overview + docs/01-kubernetes-k3s

> 审计基准：[`../assets/ground-truth.md`](../assets/ground-truth.md)（2026-11-11 实测）。所有 kubectl 均为只读。
> 共 24 条：高 3 / 中 16 / 低 5，按严重度排序。

---

### [高] 断言集群"无任何 NetworkPolicy、跨节点访问不受策略限制"，与实测 23 条 NetworkPolicy 相反
- 位置: docs/01-kubernetes-k3s/notes/upgrade-1.29-to-1.35/02-升级方案.md:913
- 原文: 「| NetworkPolicy | **0** | **无任何 NetworkPolicy**（跨节点访问不受策略限制）|」
- 问题: 该行虽在"Calico 自定义 CRD 实例"表内，但结论写的是集群层面的安全事实。集群实际有 23 条 `networking.k8s.io/v1` NetworkPolicy，且当前数据面是 Cilium（`Kubernetes APIs` 列出 `networking.k8s.io/v1::NetworkPolicy`），策略是被强制执行的。按此结论排障会漏掉策略丢包这一最常见原因。
- 证据/正确说法: `kubectl get netpol -A --no-headers | wc -l` → **23**；含 `kafka/my-cluster-network-policy-kafka`、`china-study-free`、`tekton-pipelines`、`ceph-csi-rbd` 等。正确表述：Calico 的 `projectcalico.org/v3 NetworkPolicy` 实例为 0，但 Kubernetes 原生 NetworkPolicy 有 23 条并由 Cilium 执行。

---

### [高] 称 kube-proxy"配置为 iptables 模式、从未使用 ipvs"，与同目录执行报告、方案文档和实测全部冲突
- 位置: docs/01-kubernetes-k3s/notes/K8s-1.35-审计报告.md:28
- 原文: 「| 4 | kube-proxy `ipvs` 弃用 | ✅ **不适用** | kube-proxy 配置为 `mode: iptables`，从未使用 ipvs |」
- 问题: 同目录 `02-升级方案.md:26-38` 记录 `cm/kube-proxy mode: "ipvs"`、worker01 上 366 条 IPVS 规则、`lsmod` 已加载 ip_vs；`07-线3执行报告-kube-proxy完成.md` 整篇就是 2026-10-03 的 IPVS→iptables 迁移记录。所以"从未使用 ipvs"是硬性事实错误。更严重的是：实测集群里 **kube-proxy 已整体移除**（Cilium KPR 接管），把它列为"当前 iptables 模式、可列入技术债"会误导后续排障方向。
- 证据/正确说法: `kubectl -n kube-system get ds` → 只有 `cilium`(6/6) 与 `kube-vip-ds`(3/3)；`kubectl -n kube-system get pod | grep -c kube-proxy` → **0**；`kubectl -n kube-system get cm | grep kube-proxy` → 空；仅残留无 endpoints 的 `Service/prometheus-kube-proxy`（`kubectl get endpoints prometheus-kube-proxy` → `<none>`）。正确说法：kube-proxy 不存在，Service 由 Cilium eBPF 实现。

---

### [高] 把官方"升级到下一个版本(1.36)前切 containerd 2.0+"误读成"升 1.35 前必须切"，并据此确定整条升级线的顺序
- 位置: docs/01-kubernetes-k3s/notes/upgrade-1.29-to-1.35/01-现状盘点与官方要求.md:116
- 原文: 「且官方明确要求——**升到 1.35 前就应该先把 containerd 切到 2.0+**，而非等到 1.36 才被迫升。这与本方案「先升 containerd、再逐级升 K8s」的顺序完全一致，且是官方明确指引。」
- 问题: 同一节引用的官方原文是 "you must switch to 2.0 or later **before upgrading Kubernetes to the next version**"，指的是 1.35 → **1.36** 之前；而本节自己的 §2.1 矩阵也写着 1.35 支持 `2.2.0+ / 2.1.5+ / **1.7.28+**`。`09-线5执行报告:230`、`Kubernetes-1.35-详解.md:462` 同样写"1.35 是最后一个支持 containerd 1.x 的版本"。即 1.35 上跑 containerd 1.7.28+ 是官方支持的。该误读被 `03-执行总纲.md:79`（"官方要求「升 K8s 1.35 前必须先切 containerd 2.0+」"）再次引用，成为"containerd 必须排在最前"的唯一依据——实际上真正的前置理由只有一条：现役 1.7.22 < 1.7.28，且 1.7 分支 2026-09 已 EOL。
- 证据/正确说法: 正确说法：containerd 需升级的真实原因是版本低于 1.35 矩阵下限（1.7.28）与 1.7 分支 EOL，而不是"1.35 要求 2.0+"。升到 2.3.2 是可接受的取舍（LTS、跨 major 官方测试路径），但不应表述为"官方要求"。

---

### [中] 节点 CPU 使用率查询写成 `100 - 0 * avg(...)`，结果恒为 100
- 位置: docs/00-cluster-overview/notes/k8s-cluster-report.md:823
- 原文: 「'http://prometheus-operated.monitoring.svc.cluster.local:9090/api/v1/query?query=100%20-%200%20*%20avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))%20by%20(node)'」
- 问题: URL 解码后是 `100 - 0 * avg(rate(...)) by (node)`。乘 0 后整项为 0，任何节点都返回 100，且 `by (node)` 被乘法吞掉导致只剩一条无标签序列。作为"节点 CPU 使用率"的示例命令，使用者会得到恒定 100% 的假数据。
- 证据/正确说法: 实查 Prometheus：该表达式返回 `{"metric":{},"value":...,"100"}`；改成 `100 - (avg by (node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)` 返回 `13.446...`。正确写法必须去掉 `0 *` 并把 `*100` 放进括号。

---

### [中] 三台控制面全部执行 `kubeadm upgrade apply`，第二、三台应为 `kubeadm upgrade node`
- 位置: docs/01-kubernetes-k3s/assets/upgrade-scripts/upgrade-k8s-series.sh:174（流程见 notes/upgrade-1.29-to-1.35/03-执行总纲.md:243）
- 原文: 「local OUT=$(kx $N "kubeadm upgrade apply v$VER -y --ignore-preflight-errors=CoreDNSUnsupportedPlugins 2>&1")」；总纲写「kubeadm upgrade apply v1.30.x / # worker: kubeadm upgrade node」
- 问题: 脚本 `for N in $CP` 对 m01/master01/master02 依次执行 `apply`。kubeadm 官方流程是：`upgrade apply` 只在**第一台**控制面执行一次（升级集群级组件/证书/addon），其余控制面节点与 worker 一样用 `kubeadm upgrade node`（升级本机静态 Pod 清单、kubelet 配置、kube-proxy DaemonSet）。对第二、三台继续 apply 属于未定义用法，且会跳过 `upgrade node` 负责的 kubelet 配置迁移。
- 证据/正确说法: 正确顺序（每级）：① 第一台 CP：装 kubeadm → `kubeadm upgrade apply vX.Y.Z` → 装 kubelet/kubectl → 重启 kubelet；② 其余 CP 与所有 worker：装 kubeadm/kubelet/kubectl → `kubeadm upgrade node` → 重启 kubelet。实测当前 6 节点均为 v1.35.9，说明结果可用，但流程本身不是 kubeadm 支持的方式。

---

### [中] 声称当前 runc 为"1.3.3（6 节点一致）"，同目录修正记录与执行报告均为 5 台 1.1.14
- 位置: docs/01-kubernetes-k3s/notes/upgrade-1.29-to-1.35/02-升级方案.md:248
- 原文: 「| 当前 | 1.3.3（6 节点一致）|」
- 问题: `01-现状盘点与官方要求.md:348-363` 的"数据修正记录"明确写：m01=1.3.3（/usr/bin/runc），其余 5 台=**1.1.14**（/usr/local/sbin/runc），错误原因正是"SSH 到单节点后推断 6 节点一致"。`05-线1执行报告:19` 也写"升级前 containerd 1.7.22 + runc 1.1.14（m01 为 1.3.3）"。方案文档未同步修正，导致 03 决策表、回滚脚本里的 `runc-1.3.3` 备份命名对 5 台节点不成立。
- 证据/正确说法: 正确：m01 1.3.3、master01/02 与 worker01/02/03 均 1.1.14；升级目标统一 1.4.3，回滚包应按节点实际版本命名。

---

### [中] "IPVS 模式下 kube-proxy 不生成 iptables 规则"——错误，且与本表自测的 8 行矛盾
- 位置: docs/01-kubernetes-k3s/notes/upgrade-1.29-to-1.35/07-线3执行报告-kube-proxy完成.md:36
- 原文: 「**迁移前 `KUBE-SERVICES` 只有 8 行是正常的** —— IPVS 模式下不生成 iptables 规则，所有 Service 转发都由 IPVS 内核模块处理。」
- 问题: IPVS 模式下 kube-proxy 仍然写 iptables：`KUBE-SERVICES` 里的 `KUBE-MARK-MASQ` 跳转、`KUBE-NODE-PORT`、`KUBE-FW-*`、`KUBE-POSTROUTING`、`KUBE-FIREWALL` 都在，只有"VIP→Pod 的 DNAT 决策"交给 IPVS。该文档上一行自己就列了迁移前 `KUBE-SERVICES`=8 行——若真不生成规则应为 0 行。把"不生成"当结论会让人在 IPVS 集群里放弃查 iptables（SNAT/masquerade 问题恰恰只在这些链里）。
- 证据/正确说法: 正确说法：IPVS 模式不生成 `KUBE-SVC-*`/`KUBE-SEP-*` 转发链，但生成 `KUBE-SERVICES` 的 masquerade 分支、`KUBE-NODE-PORT`、`KUBE-POSTROUTING`、`KUBE-FIREWALL` 等辅助链。

---

### [中] 说 iptables 模式下 kube-proxy 用 ip rule/route 把 Service 网段引到本机 lo——那是 IPVS 模式的行为
- 位置: docs/01-kubernetes-k3s/k3s-cilium-网络分析.md:151
- 原文: 「关键：kube-proxy 在每台机器用 ip rule/route 把 10.43.0.0/16 引到本机 lo」
- 问题: iptables 模式的 kube-proxy 不创建任何路由或 ip rule；`10.43.0.0/16 → lo` 的路由与 `kube-ipvs0` dummy 网卡是 **IPVS 模式** 的特征（每个 ClusterIP 挂一个 /32 到 kube-ipvs0）。紧接的下一段（152-154 行）又正确地描述 PREROUTING→KUBE-SERVICES→DNAT，两段自相矛盾。
- 证据/正确说法: iptables 模式：报文在 `OUTPUT`/`PREROUTING` 被 netfilter DNAT 改写到 Pod IP，再走正常路由，无需 Service 网段路由。可用 `ip route | grep 10.43` 在纯 iptables 节点验证为空。

---

### [中] 用 `containerRuntimeVersion` 检查 cgroup v1——该字段不反映 cgroup 版本
- 位置: docs/01-kubernetes-k3s/notes/Kubernetes-1.35-详解.md:551
- 原文: 「- [ ] **cgroup v1 节点**：全量扫描 `kubectl get nodes -o json | jq -r '.items[].status.nodeInfo.containerRuntimeVersion'`，确认无 v1 节点残留」
- 问题: `status.nodeInfo.containerRuntimeVersion` 的值形如 `containerd://2.3.2`，是运行时版本，与 cgroup v1/v2 无关。按这条执行会"永远通过"，漏掉真正的 cgroup v1 节点。
- 证据/正确说法: `kubectl get nodes -o wide` 的 CONTAINER-RUNTIME 列即该字段（本集群 6 节点均 `containerd://2.3.2`）。正确检查：节点上 `stat -fc %T /sys/fs/cgroup`（`cgroup2fs`=v2，`tmpfs`=v1），或看 `/proc/1/cgroup`；K8s-1.35-审计报告.md:25 用的正是 `stat -fc %T` 这条正确命令，两处不一致。

---

### [中] 说集群有"9 个 Released 孤儿 PV"，实际列了 10 条，且当前 17 个 PV 全部 Bound
- 位置: docs/01-kubernetes-k3s/notes/K8s-1.35-审计报告.md:105
- 原文: 「### 🟡 问题 3：9 个 `Released` 状态的孤儿 Ceph RBD PV」
- 问题: 标题写 9 个，下面列表是 10 行（pvc-1eaaa4c3…pvc-e4e45b3b…）。更要紧的是与集群实际状态冲突：`10-k8s-core-evidence.md:140` 写"17 PV 全 Bound"，实测也确为 17 Bound / 0 Released。以"9 个孤儿 PV 占着 Ceph 空间"作为待办会让人去清理不存在的对象。
- 证据/正确说法: `kubectl get pv --no-headers | awk '{print $5}' | sort | uniq -c` → `17 Bound`。若曾存在 Released PV，应标注为历史状态并给出当时的 `kubectl get pv` 输出。

---

### [中] 说"PodSecurity 标签仅 metallb-system 有"，实测 4 个命名空间已打标签
- 位置: docs/01-kubernetes-k3s/notes/K8s-1.35-审计报告.md:135
- 原文: 「| PodSecurity 标签 | **仅 metallb-system 有** | 其余 20+ 命名空间**完全没有** Pod Security Admission 约束。…」
- 问题: 与同目录 `10-k8s-core-evidence.md:379-383`（列 4 个 ns：china-study-free baseline、etcd-backup privileged、metallb-system privileged、tekton-pipelines restricted）和 `00-cluster-overview/notes/production-readiness-gaps-20261109.md:285-291` 直接矛盾。
- 证据/正确说法: 实测带 `pod-security.kubernetes.io/*` 标签的 ns 有 4 个：
  `china-study-free {enforce: baseline}`；`etcd-backup {audit/enforce/warn: privileged}`；`metallb-system {audit/enforce/warn: privileged}`；`tekton-pipelines {enforce: restricted}`。

---

### [中] 节点规格表把 master01 写成 6C/6G，实际 4 vCPU，且与同文档第 8.2 节自相矛盾
- 位置: docs/00-cluster-overview/notes/production-readiness-gaps-20261109.md:124
- 原文: 「| master01 | 46% | 53% | 6C/6G |」
- 问题: 同一文档 §8.2（第 640 行）写 `master01 | 4 | 910m | 5.8Gi`，即 4 核；`00-cluster-overview/assets/current-state.md:23` 的节点容量也是 `master01 4 6063400Ki`。按 6 核去评估 CPU 水位/扩容会算错。
- 证据/正确说法: `kubectl get nodes -o custom-columns='NAME:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory'` → master01 **4** 核 / 6063400Ki；6 核的只有 worker01、worker02。

---

### [中] Ceph 节点 IP 写成 10.0.0.116/117/118，实际是 10.0.0.31/41/51
- 位置: docs/00-cluster-overview/notes/k8s-cluster-report.md:617
- 原文: 「> **Ceph 恢复说明**: 2026-09-27 Ceph 存储节点 (10.0.0.116/117/118) 开机后，所有因存储不可用而异常的 Pod 已恢复正常运行。」
- 问题: 同目录 `infra-topology-truth.md:22-24` 与实测都写 ceph-01/02/03 = 10.0.0.31/41/51，RGW 在 10.0.0.31:7480。10.0.0.116/117/118 在本环境不存在。按这个 IP 去 ssh 排查 Ceph 会连到不存在的机器（或误连其他 VM）。
- 证据/正确说法: GROUND-TRUTH：`ceph -s` 3 mon（ceph-01..03）、RGW `10.0.0.31:7480`；`infra-topology-truth.md` 表格同。正确：10.0.0.31 / 10.0.0.41 / 10.0.0.51。

---

### [中] 「ceph df 已用 18 GiB（10%）」与同目录快照的 81 GiB、实测 92 GiB 相差 5 倍
- 位置: docs/00-cluster-overview/notes/infra-topology-truth.md:174
- 原文: 「`ceph df` 显示 180 GiB 总量、已用 18 GiB（10%），`MAX AVAIL` 各 pool 50 GiB。」
- 问题: `00-cluster-overview/assets/current-state.md:154` 的 `ceph -s` 快照是 `usage: 81 GiB used, 99 GiB / 180 GiB avail`；实测现在是 92 GiB / 180 GiB。用 10% 水位得出的"Ceph 还很空、短期不是瓶颈"的结论站不住（实际已过半）。18 GiB 很可能是把 `objects 27 GiB` 或某个 pool 的用量当成了集群用量。
- 证据/正确说法: GROUND-TRUTH：`ceph -s` 用量 **92 GiB / 180 GiB**（约 51%），465 pgs active+clean；同仓库 `current-state.md` 当时为 81 GiB（45%）。

---

### [中] `cluster-diagnostics` 先说告警被"触发"，后说该告警"逻辑上不会触发/当前未触发"
- 位置: docs/00-cluster-overview/notes/cluster-diagnostics-20261007.md:55（对照第 10 行）
- 原文: 「导致 Tempo3StorageBackendConnectFailing 告警触发（对象存储连接受影响）」…「当前未触发是因为 block-builder 实际未尝试连接对象存储。」
- 问题: 同一文档对同一告警给出互斥结论：第 10 行把它当作 nftables 切换的后果（说明它 firing 了），第 55 行又说它当前未触发、且对 block-builder 逻辑上不会触发。读者无法判断该告警到底可不可信，后面"排除 block-builder"的修复建议也失去依据。
- 证据/正确说法: 需要二选一并给证据：若 firing，应贴 `kubectl -n monitoring get prometheusrule` 里该规则 + `ALERTS{alertname=...}` 查询结果；若未 firing，第 10 行的因果链需删除。当前表述只能判定为自相矛盾。

---

### [中] 同一张表里既说"单副本 etcd 被 drain 会导致集群完全不可用"，又说"静态 Pod 不受 drain 影响反而安全"
- 位置: docs/01-kubernetes-k3s/notes/upgrade-1.29-to-1.35/02-升级方案.md:335
- 原文: 「| **etcd 是单副本还是多副本** | ⚠️ **需人工确认**。若 etcd 是单副本（实验环境很可能），**drain 该节点会导致集群完全不可用** |」
- 问题: 下一行（336）自己写「静态 Pod 不受 drain 影响 → 反而安全」。技术上也确实如此：kubeadm 的 etcd/apiserver 是 Mirror Pod，`kubectl drain` 不会驱逐它们（只会 cordon + 驱逐普通 Pod），无论 etcd 是 1 副本还是 3 副本都不会因 drain 停机。此外 §10.1 已实测 etcd 为 3 成员，"单副本"的假设在同一文档内已被推翻。
- 证据/正确说法: 实测 `kubectl -n kube-system get pod -l component=etcd` → etcd-m01/etcd-master01/etcd-master02 三副本 Running。正确说法：drain 控制面节点不会停 etcd/apiserver；风险来自"同时停 2 个成员"或"重启后静态 Pod 起不来"，不是 drain 本身。

---

### [中] 称 kube-proxy nftables 模式"1.31+ GA"，与同仓库"1.35 仍在演进/规则为空"的记载冲突
- 位置: docs/01-kubernetes-k3s/notes/upgrade-1.29-to-1.35/02-升级方案.md:757
- 原文: 「| K8s 支持 | 全版本支持 | 1.31+ GA |」
- 问题: 同一仓库对 nftables 模式的成熟度给出三种说法：此处"1.31+ GA"；`docs/01-kubernetes-k3s/README.md:88`"新，1.35 仍在演进，本集群曾遇到规则为空的问题"；`Kubernetes-1.35-详解.md:455-458`"ipvs 弃用、Linux 节点推荐迁移到 nftables（上游推荐模式）"。kube-proxy 的 nftables 后端在 1.31 是 Beta（KEP-3866），把 Beta 说成 GA 会让人误判"可以无风险直接切"。
- 证据/正确说法: 正确表述：1.31 进入 Beta；是否 GA 需按目标小版本 release note 核实，仓库内应以一处权威说法统一（README 的"仍在演进"与实测"nft 规则集为空"才是本环境的真实体验）。

---

### [中] 建议用 `kubectl delete pod --force` 绕过 PDB，而不是处理 PDB/副本数
- 位置: docs/01-kubernetes-k3s/notes/upgrade-1.29-to-1.35/05-线1执行报告-全集群完成.md:165
- 原文: 「这些都有 `80% minAvailable` 的 PDB，且单副本。**解决**：`kubectl delete pod --force`直接删除，等待在别节点重建。」
- 问题: PDB 存在的目的就是阻止"同时消失"。对单副本 Deployment 强删，等价于在无副本兜底时制造一次硬中断；对 StatefulSet/有状态 Pod 强删还会绕过优雅终止（SIGTERM、preStop、数据落盘）。文档把它写成"解决方案"而非"最后手段"，且没有"先确认无流量/已备份"的前置条件。本仓库另一处（08 报告）恰好记录了强删/清容器后 apiserver 全线起不来的事故，两条经验没有互相校正。
- 证据/正确说法: 正确做法：drain 前先临时调高副本或临时放宽 PDB（`maxUnavailable`），确认业务可容忍后再操作；`--grace-period=0 --force` 只用于确认已死的僵尸 Pod（如文档自己第 167-172 行的 5 天 Terminating 案例），并需注明数据风险。

---

### [中] 00 章把 1.29.8 + Calico + kube-proxy 时期的历史报告当作"集群基本信息"索引
- 位置: docs/00-cluster-overview/README.md:120
- 原文: 「| [k8s-cluster-report.md](../../00-cluster-overview/notes/k8s-cluster-report.md) | 集群基本信息、节点、命名空间、工作负载、Service 盘点 |」
- 问题: 该报告正文是 `v1.29.8`、containerd 1.7.22、Calico 3.27.4、kube-proxy 6 副本、MetalLB 池 172.16.1.220-221、knative 命名空间仍在（第 12、17、193、243 行）。而同一目录 `assets/current-state.md` 是 1.35.9 + Cilium 1.20.4 + kube-proxy 已移除。README 未标注"升级前快照"，两篇并列会让读者把 1.29 的拓扑当成现状（GT 也确认 knative 命名空间已下线）。
- 证据/正确说法: 应标注版本与日期（如"2026-09-27 升级前快照 v1.29.8/Calico"），或直接指向 current-state.md 作为现状；当前 README 第 17-28 行的"现状"描述与第 120 行索引的文档互不一致。

---

### [低] 同一次控制面升级，05 报告说"只 cordon 不 drain"，08 报告与脚本注释说"只 drain 不 cordon"
- 位置: docs/01-kubernetes-k3s/notes/upgrade-1.29-to-1.35/05-线1执行报告-全集群完成.md:46
- 原文: 「**control-plane 节点按方案只 cordon 不 drain** —— 静态 Pod 不受 drain 管辖…」；08 报告第 111 行「CP 升级**只 drain 不 cordon** —— 健康检查 Job 需要能调度到节点」
- 问题: 两种说法互斥，而且"只 drain 不 cordon"在语义上不成立——`kubectl drain` 的第一步就是 cordon。读者无法据此复现流程，也看不出哪份报告描述的是真实执行方式。
- 证据/正确说法: `kubectl drain` 文档：drain = cordon + evict。应统一表述为"CP 节点执行 drain（内含 cordon），完成后 uncordon"，或"仅 cordon、不 evict 业务 Pod"。

---

### [低] "实际只用到 3 个插件"后面列了 4 个
- 位置: docs/01-kubernetes-k3s/notes/upgrade-1.29-to-1.35/02-升级方案.md:89
- 原文: 「**两边的 conflist 完全相同，实际只用到 3 个插件**：`calico` / `calico-ipam` / `portmap` / `bandwidth`。」
- 问题: 数量与列举不一致（4 个）。这是"control-plane 只有 8 个插件也够用"这一结论的依据，数字错会让人怀疑论证本身。
- 证据/正确说法: 按上方 conflist（第 77-87 行）实际是 4 个 plugin 条目：calico（含 calico-ipam ipam）、portmap、bandwidth。应改为"4 个"。

---

### [低] 1.35 特性总数 60（17 GA）与正文"GA 特性详解（15 项）"、实际列举 14 项三处不一致
- 位置: docs/01-kubernetes-k3s/notes/Kubernetes-1.35-详解.md:7
- 原文: 「> - 增强项总数：**60 个**（**17 个 GA** / **19 个 Beta** / **22 个 Alpha**）」
- 问题: 第 17 行目录与第 140 行小节标题写"GA 特性详解（15 项）"，而 §3.1（6 项）+§3.2（8 项）实际只列 14 项。60/17/19/22 与 15、14 无法同时成立，读者按 17 GA 去核对会找不到 3 项。
- 证据/正确说法: 三者需统一（以官方 release notes 的 GA 数为准），或在小节注明"仅列重点 N 项"。

---

### [低] "containerd-shim-runc-v2 ×8"后面列了 9 个 PID
- 位置: docs/01-kubernetes-k3s/k3s-pod-process-chain.md:122
- 原文: 「| `containerd-shim-runc-v2` ×8 | 1246/1290/1358/2091/2125/2184/2222/2251/2304 | 每个**运行中容器**一个 shim |」
- 问题: PID 列 9 个（1246、1290、1358、2091、2125、2184、2222、2251、2304），数量写 8。该表是"每 Pod 一个 shim / 每容器一个 shim"论证的数据基础，计数不准会直接影响结论。
- 证据/正确说法: 按 PID 列表应为 9 个 shim；同时该行结论"每个运行中容器一个 shim"与 §3.2/3.3"同一 shim 管同 Pod 多容器"也需二选一。

---

### [低] GitLab 版本写 19.4，实测 API 返回 19.5.0
- 位置: docs/00-cluster-overview/README.md:43
- 原文: 「├─ ubuntu01 192.168.67.201  GitLab CE 19.4」
- 问题: GROUND-TRUTH 记录 `http://192.168.67.201/api/v4/version` → **19.5.0**（Community Edition）。同一目录 `assets/hyperv-host-20261111/README.md:15` 也写 19.4。版本号在 00 章两处一致地落后一个 minor，而 01 章工具链表又把 GitLab 排除在外，导致"当前版本"在仓库内无一处正确。
- 证据/正确说法: 正确写法：GitLab CE **19.5.0**（采集时间 2026-11-11，`/api/v4/version`）。
