# 00 · 集群全景：这套环境到底是什么样

> 这一章不是操作教程，而是“地图”。后面所有案例都发生在这套集群里，
> 先把拓扑、版本、边界和已知短板讲清楚，读其他章节时才不会被 IP、节点名和组件关系绕晕。

## 当时的情况

这是一套**跑在一台 PVE 宿主机上的实验/生产混合集群**：

- Kubernetes：`v1.35.9`，6 个节点（3 control-plane + 3 worker），kubeadm 部署；
- 容器运行时：containerd `2.3.2` + runc `1.4.3`；
- CNI：Cilium `1.20.4`，**全量 CNI + kube-proxy replacement + eBPF host routing + BPF masquerade + native routing**；
- 入口：Traefik `v3.7.17`（LoadBalancer VIP `10.0.0.252`），MetalLB Controller 仍负责 LB IPAM，L2 宣告已交给 Cilium；
- GitOps：ArgoCD `v3.5.3`，31 个 Application；
- 监控：kube-prometheus-stack `83.7.0` / prometheus-operator `0.90.1`，Prometheus `v3.x`；
- 日志：Loki `3.6.7` + Grafana Alloy `v1.20.0`；
- 追踪：Tempo 3.0.3（tempo-distributed），OTel Operator/Collector；
- 存储：外部 Ceph Reef `18.2.8`（3 台 VM、6 个 OSD），K8s 通过 ceph-csi 使用 RBD；另有 NFS StorageClass；
- 数据库/消息：CloudNativePG（PostgreSQL 16）、Strimzi Kafka、Redis；
- 交付：GitLab（宿主机 `192.168.67.201`）+ GitLab Runner + Tekton + Harbor + ArgoCD；
- 身份：oauth2-proxy + Dex，保护 ArgoCD/Tekton/Hubble/Alloy/Traefik 等 UI。

> 注意：K8s 与 Ceph 都是 PVE 上的 VM，**共享同一台物理机的 CPU、内存和磁盘**。
> 所以“节点内存 84%”“Ceph 慢”“Pod 抖动”经常是同一层的资源竞争，而不是某个组件单独的 bug。

## 主要概念与原理

### 1. 控制面与数据面

```text
kube-apiserver  ──► etcd（3 个 stacked 成员）
      ▲
      │ watch / 写入
kube-controller-manager / kube-scheduler / kubelet
      │
      ▼
Cilium Agent（DaemonSet，每节点一个）
      ├─ eBPF 程序挂在 TC / cgroup / socket 上
      ├─ BPF Map：Service LB、conntrack、ipcache、identity
      └─ Hubble：流级可观测性
```

- **apiserver 是唯一读写 etcd 的组件**；kubectl、controller、kubelet、operator 都通过它 watch。
- **Cilium 取代 kube-proxy 后**，ClusterIP/NodePort/LoadBalancer 的 DNAT 不再走 iptables，而是 eBPF Map + socket LB。
- **Traefik 只负责 L7 入口**；L4 VIP 由 MetalLB 分配、Cilium L2 宣告。

### 2. 三个“地址”不要混

| 地址 | 例子 | 谁分配 | 作用 |
|---|---|---|---|
| 节点 IP | `10.0.0.61` | PVE/静态 | 宿主机 underlay 通信 |
| Pod IP | `10.244.5.x` | Cilium Kubernetes IPAM（每节点 /24） | Pod 间直连，native routing |
| Service/VIP | `10.96.x.x` / `10.0.0.252` | apiserver / MetalLB | 虚拟地址，由 eBPF 或 L2 宣告承接 |

### 3. 为什么这套环境“看起来什么都有，但又处处是单点”

它是从实验环境逐步长出来的：组件齐全、GitOps 化程度高，但资源配额、副本数、备份、审计等
生产基线并没有同步补齐。`production-readiness-gaps-20261109.md` 把差距拆成 P0/P1/P2，
其中 etcd 备份已经在 2026-11-09 补上（CronJob `etcd-backup/etcd-snapshot`，每小时一次）。

## 踩坑点

### 坑 1：把 PVE 断电当成“K8s 组件随机崩溃”

早期大量 Pod 重启、etcd 抖动、Ceph PG 异常，时间戳都能对到 **PVE 宿主机断电/开机**。
如果只看 K8s 事件，会误判成 apiserver、CNI 或存储的独立故障。

**教训**：先建立“物理层 → VM → K8s → 组件”的时间线，再谈根因。

### 坑 2：把 `kubectl top` 当成真实内存

`kubectl top` 显示 working set，通常低于进程 RSS。apiserver 内存分析时必须直接抓
`/metrics` 的 `process_resident_memory_bytes`、heap、watch 数，否则会低估 20%–40%。

### 坑 3：版本表只看“能跑”，不看“官方测试矩阵”

集群是 1.35，但多个组件的官方兼容矩阵并不包含 1.35（例如当时的 ArgoCD 3.2.x、ceph-csi 3.16.x）。
“能启动”不等于“被验证过”，升级前要查矩阵，而不是等出事再查。

### 坑 4：把实验环境的“全组件”当成生产架构

31 个 ArgoCD App、147 个 CRD、单副本 Prometheus/Traefik/ArgoCD，在实验环境没问题；
放到生产就是 P0。`production-readiness-gaps` 里有完整清单，不要照抄这套拓扑上生产。

## 修复关键

1. **先固化事实**：节点、版本、命名空间、Helm Release、ArgoCD App、StorageClass、Ceph 健康度，全部落成快照（见 `assets/current-state.md`）。
2. **再标边界**：哪些是集群内组件，哪些在宿主机（GitLab/Harbor/PVE/Ceph），哪些是外部依赖（企业微信、Cloudflare、Tailscale）。
3. **最后排优先级**：数据恢复（etcd/PVC）> 入口与 GitOps 单点 > 资源水位 > 安全与多租户。
4. **每次变更留证据**：变更前备份 YAML、变更后抓状态、把命令和输出写进文档，而不是只留一句“已修复”。

## 本目录文档

| 文档 | 内容 |
|---|---|
| [infra-topology-truth.md](notes/infra-topology-truth.md) | PVE 上 9 台 VM 的真实拓扑，纠正“组件随机故障”的历史结论 |
| [k8s-cluster-report.md](notes/k8s-cluster-report.md) | 集群基本信息、节点、命名空间、工作负载、Service 盘点 |
| [cluster-diagnostics-20261007.md](notes/cluster-diagnostics-20261007.md) | kube-proxy nftables 切换后的集群诊断与重启分析 |
| [production-readiness-gaps-20261109.md](notes/production-readiness-gaps-20261109.md) | 生产化差距审计：P0/P1/P2 清单与建议 |
| [工具链版本对照表.md](notes/工具链版本对照表.md) | 全组件版本、EOL、1.35 兼容性与升级优先级 |

## 配套资产

| 资产 | 说明 |
|---|---|
| [current-state.md](assets/current-state.md) | 2026-11-10 16:03 的集群实况快照（节点/Helm/ArgoCD/Cilium/Ceph/监控/入口） |
| [cluster_inventory.py](scripts/cluster_inventory.py) | 只读盘点脚本：输出 Markdown 或 JSON，可定期执行做基线对比 |

```bash
# 生成 Markdown 快照
python3 docs/00-cluster-overview/scripts/cluster_inventory.py --format md > /tmp/cluster.md

# 生成 JSON（便于 diff）
python3 docs/00-cluster-overview/scripts/cluster_inventory.py --format json > /tmp/cluster.json
```

## 与其他章节的关系

- 宿主机、VM、LVM-thin、磁盘容量的“物理层地图”：[12 Proxmox VE](../12-proxmox-pve/README.md)；
- 集群如何逐步交给 Git、Secret 如何不落明文：[11 GitOps 平台化](../11-gitops-platform/README.md)；
- 存储/PV/CNPG 备份：[06 Storage / Ceph](../06-storage-ceph/README.md)；
- 入口/DNS/Service：[07 Networking](../07-networking/README.md)。

## 读完后你应该能回答

- 这套集群的控制面、数据面、入口、存储、可观测性分别由谁负责？
- 为什么 Cilium 接管 Service 后，`iptables-save` 里仍可能看到旧 `KUBE-*` 规则？
- 为什么“节点内存高”不一定是 K8s 调度问题？
- 这套环境距离生产还缺哪 5 件事？
