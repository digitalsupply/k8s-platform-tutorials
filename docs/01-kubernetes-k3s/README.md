# 01 · Kubernetes / k3s：Pod 到底是怎么跑起来的

## 当时的情况

案例环境是一个三节点 **k3s** 实验集群（Ubuntu），使用 Cilium 作为 CNI。
当时需要回答几个“看似简单但很容易答错”的问题：

- `ps aux` 里为什么看不到独立的 `kubelet`、`etcd` 进程？
- 一个 Pod 在宿主机上对应几个进程？`pause` 容器是什么？
- 容器里的 PID 1 和宿主机的 PID 是什么关系？
- Pod 的 IP、Service 的 IP、节点的 IP 分别由谁分配？
- 为什么 `kubectl exec ds/cilium` 有时看到的 BPF 表和另一台节点不一样？

这些问题不搞清楚，后面排查 Service 不通、Pod 网络异常、cgroup 资源问题都会靠猜。

## 主要概念与原理

### 1. k3s 是“单二进制”

k3s 把 kube-apiserver、controller-manager、scheduler、kubelet、etcd（或 SQLite）
等组件打包进一个 `k3s server` / `k3s agent` 进程。因此：

- `ps` 看到的是 `k3s server` / `k3s agent`，不是一堆独立组件；
- 日志用 `journalctl -u k3s`；
- 不能按标准 kubeadm 集群的进程名去找 kubelet。

### 2. Pod = sandbox + 容器

一个 Pod 至少包含：

- 一个 **pause / sandbox 容器**：持有网络命名空间、IPC 命名空间等；
- 一个或多个业务容器：共享 sandbox 的网络命名空间；
- 每个容器对应 containerd shim + runc 进程；
- 通过 cgroup 统一做资源限制；
- 通过 overlayfs 叠加镜像层和可写层。

所以“Pod 在宿主机上是一个进程”是错的；它是一个进程树/沙箱。

### 3. 三种 ID 要分清

| ID | 用途 |
|---|---|
| Pod UID | Kubernetes 对象身份 |
| sandbox ID | pause 容器 / 网络命名空间 |
| container ID | 业务容器 |

排查网络问题时，通常要用 sandbox ID 找到 netns，再用 `nsenter` 或 `lsns` 进入。

### 4. 两套网段

- **Cluster CIDR / Pod CIDR**：Pod IP 从哪里分配；
- **Service CIDR**：ClusterIP 从哪里分配，通常由 kube-proxy 或 Cilium eBPF 做 VIP→Pod 转换。

k3s 默认常见是 `10.42.0.0/16`（Pod）和 `10.43.0.0/16`（Service）；
但本案例的 Cilium 使用 `cluster-pool` IPAM，Pod 网段会按节点分配 `/24`，
所以不要死记默认值，要看实际配置。

## 踩坑点

### 坑 1：按 kubeadm 的经验找进程

在 k3s 里找 `kubelet`、`etcd` 独立进程会找不到，误以为集群没起来。
实际它们是 `k3s server` 的一部分。

### 坑 2：把 pause 容器当成业务容器

`pause` 是 sandbox，不是业务容器；它的生命周期代表 Pod 的网络命名空间。
业务容器重启时，sandbox 可能不变。

### 坑 3：PID 命名空间混淆

容器里的 `PID 1` 是容器内的视角；宿主机上是另一个 PID。
用 `ps -ef` 看到的父链通常是 `systemd → containerd-shim → 容器进程`。

### 坑 4：Pod CIDR 有空隙

`cluster-pool` IPAM “用过不回收”，节点删除后对应 `/24` 可能空着。
这不代表节点还在，也不代表网络断了。

### 坑 5：`kubectl exec ds/cilium` 打错节点

`ds/cilium` 会随机挑一个 Pod。不同节点的 BPF 表不同。
要明确指定节点，例如：

```bash
NODE=worker01
POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec "$POD" -- cilium-dbg bpf lb list
```

## 修复关键 / 观测方法

1. **用 sandbox/container ID 建立映射**，不要只看 Pod 名；
2. **用 cgroup 路径确认 Pod UID 与容器 ID**；
3. **用 `lsns` / `nsenter` 验证网络命名空间共享**；
4. **用 `crictl` / `ctr` 查容器运行时**；
5. **先确认节点，再执行 Cilium/BPF 命令**。

## 文档列表

| 文档 | 内容 |
|---|---|
| [k3s-cluster-analysis.md](k3s-cluster-analysis.md) | `ps aux` 状态码、k3s 集群全景、25 个 Pod 分类 |
| [k3s-pod-process-chain.md](k3s-pod-process-chain.md) | 从 systemd 到 shim 到容器进程的完整启动链路 |
| [k3s-pod-概念观测实验.md](k3s-pod-概念观测实验.md) | 10 个 Checkpoint：UID、sandbox、netns、PID、cgroup、overlayfs |
| [k3s-cilium-网络分析.md](k3s-cilium-网络分析.md) | Pod/Service 网段、Cilium eBPF 与 Calico 的机制对比 |

> 这些文档中的 IP 是实验环境地址，阅读时请替换成你自己的节点/Pod 网段。
