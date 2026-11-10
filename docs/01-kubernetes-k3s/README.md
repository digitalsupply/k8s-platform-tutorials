# 01 · Kubernetes：从 Pod 进程模型到 1.29 → 1.35 逐级升级

这个目录包含两段互补的经历：

1. **k3s 实验集群**：用最小环境把“Pod 在宿主机上到底是什么”拆开看清楚；
2. **kubeadm 生产集群**：把 6 节点集群从 `v1.29.8` 逐级升级到 `v1.35.9`，同时升级 containerd、Calico，并把 kube-proxy 从 IPVS 迁到 iptables。

前者建立概念，后者暴露真实工程问题。

## 当时的情况

### 场景 A：k3s 实验集群

一个三节点 k3s 集群（Ubuntu + Cilium）。当时的问题看起来都很基础：

- `ps aux` 里为什么看不到独立的 `kubelet`、`etcd` 进程？
- 一个 Pod 在宿主机上对应几个进程？`pause` 容器是什么？
- 容器里的 PID 1 和宿主机 PID 是什么关系？
- Pod IP、Service IP、节点 IP 分别由谁分配？
- 为什么 `kubectl exec ds/cilium` 看到的 BPF 表每台节点不一样？

### 场景 B：kubeadm 主集群

- 升级前：Kubernetes `v1.29.8`、containerd `1.7.22`、runc `1.1.14`、Calico `v3.27.4`、kube-proxy **IPVS**；
- 目标：`v1.35.9`、containerd `2.3.2`、runc `1.4.3`、Calico `v3.32.2`、kube-proxy **iptables**；
- 约束：不能跳版本，必须逐级 `1.29 → 1.30 → 1.31 → 1.32 → 1.33 → 1.34 → 1.35`；
- 环境限制：无法直连 `registry.k8s.io` / Docker Hub，需要镜像加速；
- 业务约束：Prometheus、Loki、Tempo、Kafka、CNPG、ArgoCD 全程不能长时间中断。

## 主要概念与原理

### 1. k3s 是“单二进制”

k3s 把 kube-apiserver、controller-manager、scheduler、kubelet、etcd（或 SQLite）
打包进一个 `k3s server` / `k3s agent` 进程。所以：

- `ps` 看到的是 `k3s server` / `k3s agent`，不是一堆独立组件；
- 日志用 `journalctl -u k3s`；
- 不能按 kubeadm 集群的进程名去找 kubelet。

### 2. Pod = sandbox + 容器

一个 Pod 至少包含：

- 一个 **pause / sandbox 容器**：持有网络、IPC 等命名空间；
- 一个或多个业务容器：共享 sandbox 的网络命名空间；
- 每个容器对应 containerd shim + runc 进程；
- 通过 cgroup 统一做资源限制；
- 通过 overlayfs 叠加镜像层和可写层。

所以“Pod 在宿主机上是一个进程”是错的；它是一个进程树/沙箱。

### 3. 三种 ID

| ID | 用途 |
|---|---|
| Pod UID | Kubernetes 对象身份 |
| sandbox ID | pause 容器 / 网络命名空间 |
| container ID | 业务容器 |

排查网络问题时，通常要用 sandbox ID 找到 netns，再用 `nsenter` / `lsns` 进入。

### 4. kubeadm 升级的版本偏斜规则

- **kubelet 不能高于 apiserver**（允许低 3 个 minor）；
- **kubectl 允许 ±1 minor**；
- **不能跳过 minor**，必须逐级升级；
- 控制面先升，再升 worker；
- 每个 minor 都要先升 `kubeadm`，再 `kubeadm upgrade plan/apply`，最后升 `kubelet/kubectl`。

### 5. 静态 Pod 与 etcd

kubeadm 的 apiserver/controller-manager/scheduler/etcd 都是 **static Pod**，
清单在 `/etc/kubernetes/manifests/`。升级时 kubeadm 改写清单和镜像，kubelet 检测到文件变化后重建 Pod。

etcd 是 **stacked etcd**：每个 control-plane 一个成员，数据在 `/var/lib/etcd`。
升级前必须做快照，且要验证快照可读。

### 6. kube-proxy 的三种模式

| 模式 | 实现 | 特点 |
|---|---|---|
| iptables | netfilter 规则 + DNAT | 成熟、规则多、随机负载均衡 |
| IPVS | 内核 IPVS + iptables 辅助 | 大 Service 规模性能好，但调试复杂 |
| nftables | nft 规则 | 新，1.35 仍在演进，本集群曾遇到规则为空的问题 |

本集群最终把 IPVS 迁到 iptables，再在后续 Cilium 改造中**彻底移除 kube-proxy**（见 02 章）。

## 踩坑点

### 坑 1：kubeadm 自我保护

直接升 control-plane 时，kubeadm 会检查自身版本，要求先安装目标版本的
`kubeadm/kubelet/kubectl`，否则报错。顺序不能反。

### 坑 2：CoreDNS `template` 插件阻塞 preflight

IPv4-only 集群里 CoreDNS 的 `template` 插件会让 kubeadm preflight 报错。
这是已知的检查误报，需要 `--ignore-preflight-errors` 精确放行，而不是全局跳过。

### 坑 3：1.30 把 metrics 绑到 127.0.0.1

kubeadm 1.30 给 controller-manager/scheduler 加了 `--bind-address=127.0.0.1`，
Prometheus 的 target 从 125 掉到 111。必须改回 `0.0.0.0` 或单独配置抓取地址。

### 坑 4：`apt-mark hold` 让 worker “装了但没重启”

1.31 升级时 worker 包已安装，但 hold 阻止了 kubelet 重启，出现“节点显示旧版本、服务端新版本”
的不一致，最终演变成 3 个 apiserver 全部无法启动。**升级后必须逐台确认 kubelet 进程和
`kubectl get node` 版本，而不是只看 apt 安装结果。**

### 坑 5：containerd 是手工二进制，不是包管理

本集群 containerd 在 `/usr/local/bin/containerd`，`dnf update` 无效。
升级脚本必须手工替换二进制、备份 `config.toml`、处理 systemd unit，并验证 `ctr version` / `crictl version`。

### 坑 6：config.toml 保持 v2

containerd 2.x 支持 v3 配置，但为了可回滚，本集群**保留 v2**，只替换二进制。
升级后要检查 `sandbox_image`（pause）、`SystemdCgroup`、mirror 配置是否仍在。

### 坑 7：镜像加速不是路径代理

`1ms.run` 按仓库分子域名：

| 子域名 | 对应仓库 |
|---|---|
| `k8s.1ms.run` | registry.k8s.io |
| `docker.1ms.run` | docker.io |
| `quay.1ms.run` | quay.io |
| `ghcr.1ms.run` | ghcr.io |

写成 `1ms.run/library/busybox` 会 404。正确做法是配置
`/etc/containerd/certs.d/<registry>/hosts.toml`。

### 坑 8：Calico 不能一步从 3.27 跳到 3.32

必须 `3.27 → 3.30 → 3.32` 两步，并且每步验证跨节点 Pod 网络、BGP/IPIP、NetworkPolicy。
升级 Calico 时 kube-proxy 仍是 IPVS，Service 规则和 Calico 规则会同时变化，排障要分开看。

### 坑 9：升级顺序错误会导致“集群活着但服务全挂”

正确顺序：**etcd 快照 → control-plane 逐台 → worker 逐台 → CNI → kube-proxy → 业务验证**。
任何一步跳过验证，后面都会把问题误判成“升级 bug”。

## 修复关键

1. **先定 12 项决策**：目标版本、containerd 方式、runc、pause、config 版本、CNI 差异、磁盘、etcd、Ceph 兼容、Calico 路径、kube-proxy 模式、回滚方案。
2. **每个 minor 都做 etcd 快照**，并验证快照文件大小和 `etcdutl snapshot status`。
3. **control-plane 逐台滚动**：`drain → 升 kubeadm → upgrade apply → 升 kubelet/kubectl → uncordon → 验证`。
4. **worker 逐台滚动**：先 `drain`，再升包、重启 kubelet、确认版本、`uncordon`。
5. **升级后验证四件事**：节点版本一致、etcd 3/3 healthy、DNS 正常、Prometheus targets 全 up。
6. **把镜像加速、hold、bind-address 这些“环境特例”写进脚本**，不要依赖记忆。

最终结果：6/6 节点 `v1.35.9`，containerd `2.3.2`，runc `1.4.3`，etcd `3.5.12`（后续升到 `3.6.6`），
Calico `3.32.2`，Prometheus 125/125 targets up。

## 本目录文档

### k3s 概念实验

| 文档 | 内容 |
|---|---|
| [k3s-cluster-analysis.md](k3s-cluster-analysis.md) | `ps aux` 状态码、k3s 集群全景、25 个 Pod 分类 |
| [k3s-pod-process-chain.md](k3s-pod-process-chain.md) | 从 systemd 到 shim 到容器进程的完整启动链路 |
| [k3s-pod-概念观测实验.md](k3s-pod-概念观测实验.md) | 10 个 Checkpoint：UID、sandbox、netns、PID、cgroup、overlayfs |
| [k3s-cilium-网络分析.md](k3s-cilium-网络分析.md) | Pod/Service 网段、Cilium eBPF 与 Calico 的机制对比 |

### Kubernetes 1.35 与升级

| 文档 | 内容 |
|---|---|
| [Kubernetes-1.35-详解.md](notes/Kubernetes-1.35-详解.md) | 1.35 重点特性：原地 resize、HPA、设备插件等 |
| [K8s-1.35-审计报告.md](notes/K8s-1.35-审计报告.md) | 升级后合规审计与工具链分析 |
| [k8s-cluster-audit-2026-10-03.md](notes/k8s-cluster-audit-2026-10-03.md) | 磁盘/镜像/资源开销巡检，回收约 52GB |
| [ansible-for-k8s-upgrade-analysis.md](notes/ansible-for-k8s-upgrade-analysis.md) | 为什么本次没用 Ansible，以及幂等脚本的取舍 |
| [knative-architecture-and-labs.md](notes/knative-architecture-and-labs.md) | Knative 架构与实验（该组件后续已移除） |
| [default-ns-pod-provenance.md](notes/default-ns-pod-provenance.md) | default 命名空间 Pod 来源追踪 |
| [pod-load-balancing-plan-20261003.md](notes/pod-load-balancing-plan-20261003.md) | 工作节点 Pod 负载均衡方案 |
| [compassio-autoscaling-analysis-20261109.md](notes/compassio-autoscaling-analysis-20261109.md) | HPA vs VPA：按 LLM 等待 P95 扩容，CPU 兜底 |
| [upgrade-1.29-to-1.35/](notes/upgrade-1.29-to-1.35/) | 9 篇完整升级记录：盘点、方案、总纲、4 条线执行报告 |

升级记录建议按顺序读：

1. `01-现状盘点与官方要求.md`
2. `02-升级方案.md`
3. `03-执行总纲.md`
4. `04`–`05` containerd
5. `06` Calico
6. `07` kube-proxy
7. `08` 1.30/1.31（含 apiserver 宕机复盘）
8. `09` 1.35 完成

## 配套资产

| 资产 | 说明 |
|---|---|
| [scripts/pod_inspect.py](scripts/pod_inspect.py) | 从 Pod 查到 sandbox、PID、cgroup、netns |
| [assets/upgrade-scripts/](assets/upgrade-scripts/) | `upgrade-containerd.sh`、`rollback-containerd.sh`、`upgrade-calico.sh`、`migrate-kube-proxy-iptables.sh`、`upgrade-k8s.sh`、`upgrade-k8s-series.sh` |
| [assets/ansible/](assets/ansible/) | Ansible inventory 与 containerd 重启 playbook（本次未采用，但保留对比） |
| [assets/containerd-config.toml](assets/containerd-config.toml) | containerd 2.3.2 的 v2 配置备份 |

```bash
# 查看 Pod 在宿主机上的进程链
sudo python3 docs/01-kubernetes-k3s/scripts/pod_inspect.py kube-system <pod-name>

# 升级脚本只读检查（先 bash -n，再按文档逐台执行）
bash -n docs/01-kubernetes-k3s/assets/upgrade-scripts/upgrade-k8s-series.sh
```

> 升级脚本中的节点 IP、SSH 口令、镜像地址需要按你的环境替换。
> 口令已在本仓库中脱敏。
