# 04 · 把新 VM 变成 K8s 节点：内核、containerd、kubelet 与 join

> 本章目标：在“已有 K8s 集群”的前提下，把一台刚由 Terraform/cloud-init 创建的 VM
> 配成**版本一致、网络一致、能安全加入**的节点。
> 代码在 [`../assets/iac/ansible/k8s-node.yml`](../assets/iac/ansible/k8s-node.yml) 和
> [`k8s-join.yml`](../assets/iac/ansible/k8s-join.yml)。

## 1. 现有集群事实（2026-11-10）

| 项 | 值 |
|---|---|
| Kubernetes | `v1.35.9`（kubeadm） |
| 控制面 | m01 `10.0.0.61`、master01 `.121`、master02 `.120` |
| Worker | worker01 `.122`、worker02 `.123`、worker03 `.124` |
| API VIP | `10.0.0.168:6443`（kube-vip） |
| Pod CIDR | `10.244.0.0/16`（Cilium IPAM） |
| Service CIDR | `10.96.0.0/12` |
| Cluster DNS | `10.96.0.10` |
| CNI | Cilium `1.20.4`，KPR=true、native routing，**无 kube-proxy** |
| 运行时 | containerd `2.3.2`，runc `1.4.3`，`SystemdCgroup=true` |
| pause | `registry.aliyuncs.com/google_containers/pause:3.10` |
| CPU | 6 节点均为 `x86-64-v3`（Ceph-CSI 3.18 标准镜像需要 AVX2） |
| 混合 OS | m01 Rocky 9.6；其余 Ubuntu 22.04.5 |

> 新增节点不是“装个 kubelet 就行”。版本、CIDR、containerd 配置、内核参数、
> Cilium 的 `rp_filter` 任何一项不一致，都会出现 `NotReady` 或 webhook 超时。
>
> 本章参数取自 m01（10.0.0.61）的 `/etc/sysctl.d/`、`/etc/modules-load.d/`、
> `/etc/containerd/config.toml`、`/etc/containerd/certs.d/`，以及 `kubeadm-config` /
> `kubelet-config` ConfigMap；不是凭记忆写的默认值。
> 原始快照见 [`../assets/iac/reference/m01/`](../assets/iac/reference/m01/README.md)。

## 2. 主要概念

### 2.1 kubelet 版本偏斜

- kubelet **不能高于** apiserver；
- 允许低 3 个 minor，但本集群统一 `v1.35.9`；
- kubectl 允许 ±1 minor；
- 新节点加入前先 `kubeadm version -o short` 对齐。

### 2.2 containerd 的两个关键配置

| 配置 | 本集群值 | 作用 |
|---|---|---|
| `SystemdCgroup` | `true` | 与 kubelet `cgroupDriver: systemd` 一致 |
| `sandbox_image` | `pause:3.10` | Pod sandbox 镜像，必须能拉到 |
| `config_path` | `/etc/containerd/certs.d` | 镜像仓库 mirror/CA 配置 |

`SystemdCgroup=false` 的典型现象：Pod 启动后 cgroup 层级不对，kubelet 报
`failed to create containerd task` 或资源限制不生效。

### 2.3 CNI 与 kube-proxy

本集群 Cilium 已开启 `kube-proxy-replacement=true`，kube-proxy 已移除。
新节点只需要：

- 装 containerd + kubelet/kubeadm；
- 加入集群；
- Cilium agent 自动以 DaemonSet 调度到新节点并安装 CNI 配置。

**不要**在新节点上再装 kube-proxy 或 Calico。

### 2.4 `rp_filter`：CNPG webhook 的隐形杀手

本集群曾出现 m01 `net.ipv4.conf.all.rp_filter=1` 导致 CNPG webhook 全集群超时。
最终节点统一 loose 模式：

```conf
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.eth0.rp_filter = 2
net.ipv4.conf.eth1.rp_filter = 2
```

Cilium 还会写 `99-zzz-override_cilium.conf`（`all=0`），以最终 `sysctl` 值为准。
新增节点必须和现有节点一致，否则 CNPG/网络策略会出现“只在新节点上失败”。

## 3. 操作步骤

### 3.1 先跑主机基线

见第 03 章：

```bash
cd docs/12-proxmox-pve/assets/iac/ansible
ansible-playbook -i inventory-k8s.ini baseline.yml --limit k8s-lab
```

### 3.2 配置内核模块与 sysctl

`k8s-node.yml` 会写：

```text
/etc/modules-load.d/k8s.conf      overlay, br_netfilter
/etc/sysctl.d/k8s.conf            bridge-nf-call-iptables/ip6tables, ip_forward
/etc/sysctl.d/99-zz-k8s-rp-filter.conf  rp_filter=2
```

执行：

```bash
ansible-playbook -i inventory-k8s.ini k8s-node.yml --check --diff --limit k8s-lab
ansible-playbook -i inventory-k8s.ini k8s-node.yml --limit k8s-lab
```

验证：

```bash
ansible -i inventory-k8s.ini k8s-lab -m command -a 'sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.ipv4.conf.all.rp_filter'
ansible -i inventory-k8s.ini k8s-lab -m command -a 'lsmod | grep -E "overlay|br_netfilter"'
```

### 3.3 containerd

playbook 的逻辑：

1. 安装 containerd（Debian 用 `containerd`，Rocky 用 `containerd.io`）；
2. 如果 `/etc/containerd/config.toml` 不存在，`containerd config default` 生成；
3. 把 `SystemdCgroup` 改为 `true`；
4. 把 `sandbox_image` 固定为 `pause:3.10`；
5. 按 `containerd_registries` 生成 `/etc/containerd/certs.d/<registry>/hosts.toml`；
6. 重启 containerd。

验证：

```bash
containerd --version
crictl info | jq '.config.containerd.runtimes.runc.options.SystemdCgroup'
grep -E 'sandbox_image|SystemdCgroup' /etc/containerd/config.toml
```

> 现有集群的 containerd 是手工二进制 `/usr/local/bin/containerd`，不是包管理；
> playbook 用包安装是为了可复现，并会校验 `containerd --version` 必须包含 `2.3.2`。
> 如果发行版 repo 只有 1.6/2.1，需要改用官方 tarball 或内部固定版本 repo，
> **不要为了跑通而跳过版本校验**。迁移现有节点时不要直接重装，先看 01 章的升级记录。  
> `k8s-node.yml` 假定节点已配置好 containerd / Kubernetes 软件源；
> 全新 openEuler 最小镜像可能需要先加 Docker CE 或 openEuler 自带 repo。

### 3.4 kubelet / kubeadm / kubectl

playbook 安装三个包并写 kubelet extra args：

```bash
# Rocky
cat /etc/sysconfig/kubelet
# Ubuntu
cat /etc/default/kubelet
```

本集群的 kubelet 配置（来自 `kubelet-config` ConfigMap）：

```yaml
cgroupDriver: systemd
clusterDNS: [10.96.0.10]
clusterDomain: cluster.local
resolvConf: /run/systemd/resolve/resolv.conf
systemReserved:
  cpu: 100m
  memory: 256Mi
  ephemeral-storage: 1Gi
kubeReserved:
  cpu: 200m
  memory: 512Mi
  ephemeral-storage: 2Gi
evictionHard:
  memory.available: 100Mi
  nodefs.available: 10%
```

新节点加入后会从集群拉取 `kubelet-config`，不要手工覆盖。

### 3.5 获取 join 命令

在 m01：

```bash
kubeadm token create --print-join-command
```

输出类似：

```text
kubeadm join 10.0.0.168:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

> token 默认 24 小时过期；不要提交到 Git。`--discovery-token-ca-cert-hash` 必须匹配
> 当前集群 CA，不能从别的集群复制。

### 3.6 加入集群

```bash
ansible-playbook -i inventory-k8s.ini k8s-join.yml \
  -e 'kubeadm_join_command=kubeadm join 10.0.0.168:6443 --token ... --discovery-token-ca-cert-hash sha256:...'
```

`k8s-join.yml` 用 `creates: /etc/kubernetes/kubelet.conf` 保证幂等：
已经 join 的节点会跳过。

### 3.7 验证

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=<new-node>

# 跨节点网络
kubectl run netshoot --rm -it --image=nicolaka/netshoot --restart=Never -- \
  curl -sS http://kubernetes.default.svc/healthz

# 节点运行时
ssh root@<new-node> 'systemctl status containerd kubelet --no-pager'
ssh root@<new-node> 'crictl info | head'
```

Cilium 会在新节点上创建 `cilium-xxxxx` Pod；如果一直 Pending，看：

```bash
kubectl -n kube-system describe pod -l k8s-app=cilium --field-selector spec.nodeName=<new-node>
kubectl -n kube-system logs -l k8s-app=cilium --field-selector spec.nodeName=<new-node> --tail=100
```

## 4. 踩坑点

### 坑 1：kubelet 版本高于 apiserver

新节点装了 `1.36`，apiserver 还是 `1.35.9`，join 后 kubelet 反复重启。
先固定 repo/包版本：

```bash
apt-cache madison kubelet | head
dnf --showduplicates list kubelet | head
```

### 坑 2：`SystemdCgroup=false`

kubelet 用 systemd cgroup，containerd 用 cgroupfs，Pod 启动失败。
改 containerd 配置并重启：

```bash
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
```

### 坑 3：pause 镜像拉不到

`sandbox_image` 指向 `registry.k8s.io/pause:3.10`，但节点无法直连。
本集群用阿里云 pause，并在 containerd `certs.d` 配 mirror。

### 坑 4：`rp_filter=1`

CNPG webhook 超时、跨节点转发异常。统一改为 2，并确认 Cilium override 的最终值。

### 坑 5：CPU 不是 x86-64-v3

Ceph-CSI 3.18 标准镜像启动即 `SIGILL`。新节点 CPU 必须是 `x86-64-v3`：

```bash
qm config <vmid> | grep '^cpu:'
ssh root@<ip> 'grep -m1 "^flags" /proc/cpuinfo | grep -o avx2'
```

### 坑 6：swap 没关

kubelet 默认要求 swap off。`baseline.yml` 会 `swapoff -a` 并注释 fstab。

### 坑 7：主机名重复/不合法

K8s Node 名默认是 hostname。克隆 VM 如果都叫 `localhost`，join 会冲突。
cloud-init/Ansible 必须先设置唯一短主机名。

### 坑 8：join token 过期

`kubeadm token create` 默认 24h。过期后重新生成；不要复用旧 token。

### 坑 9：想回滚却直接删 VM

正确回滚：

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node>
ssh root@<node> 'kubeadm reset -f; rm -rf /etc/cni/net.d/*; reboot'
```

先 drain/delete node，再销毁 VM；否则可能留下 Pending Pod 和 Cilium 残留。

## 5. 一页命令

```bash
cd docs/12-proxmox-pve/assets/iac/ansible

ansible-playbook -i inventory-k8s.ini baseline.yml --limit k8s-lab
ansible-playbook -i inventory-k8s.ini k8s-node.yml --limit k8s-lab

# m01
kubeadm token create --print-join-command

# 控制机
ansible-playbook -i inventory-k8s.ini k8s-join.yml \
  -e 'kubeadm_join_command=kubeadm join 10.0.0.168:6443 --token ... --discovery-token-ca-cert-hash sha256:...'

kubectl get nodes -o wide
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```
