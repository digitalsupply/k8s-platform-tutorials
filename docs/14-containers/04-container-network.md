# 04 · 容器网络：netns、veth、CNI 与 Cilium

> 证据：[`assets/evidence/network/worker01-netns.txt`](assets/evidence/network/worker01-netns.txt)、
> [`k8s/inspect-cilium.json`](assets/evidence/k8s/inspect-cilium.json)、
> [`k8s/inspect-frpc.json`](assets/evidence/k8s/inspect-frpc.json)、
> [05 Linux 网络章](../05-linux/01-kernel.md)。

## 1. 容器网络的基本单位是 network namespace

```text
宿主机 netns
├─ eth0 10.0.0.122
├─ eth1 172.16.1.122
├─ cilium_host 10.244.3.57
├─ lxcxxxx (veth)  ──┐
│                    │
│   Pod netns        │
│   ├─ lo            │
│   └─ eth0@if9 10.244.3.145/32
└─ 路由：10.244.0.0/24 via 10.0.0.61 ...
```

- 每个 Pod 有独立的 netns；
- 宿主机上一端是 `lxc*` veth，Pod 里是 `eth0@ifX`；
- CNI 负责创建 veth、分配 IP、写路由；
- Cilium 用 eBPF 替代 kube-proxy/iptables 做 Service LB。

## 2. hostNetwork：共享宿主 netns

如果 Pod 设置 `hostNetwork: true`：

- 不创建独立 netns；
- Pod 直接看到宿主 `eth0/eth1`；
- 端口冲突风险；
- 常用于 CNI/CSI/node-exporter/kube-vip 等系统组件。

真实证据（worker01）：

```text
# cilium-h28cj（hostNetwork）
$ nsenter --net=/proc/1174/ns/net ip -br a
lo       127.0.0.1/8
eth0     10.0.0.122/24 ...
eth1     172.16.1.122/16 ...
cilium_host 10.244.3.57/32

# node-exporter（hostNetwork）
$ nsenter --net=/proc/1072/ns/net ip -br a
lo / eth0 / eth1 / cilium_host ...
```

## 3. 普通 Pod：独立 netns + veth

frpc Pod：

```text
$ nsenter --net=/proc/2028/ns/net ip -br a
lo      UNKNOWN 127.0.0.1/8 ::1/128
eth0@if9 UP     10.244.3.145/32 ...

$ ip r
default via 10.244.3.57 dev eth0
10.244.3.57 dev eth0 scope link
```

- Pod IP `10.244.3.145/32`；
- 默认路由指向 `cilium_host` `10.244.3.57`；
- `eth0@if9` 是 veth 的 Pod 端，宿主机端是 `lxc...`。

## 4. 宿主机路由

worker01：

```text
default via 10.0.0.1 dev eth0
10.0.0.0/24 dev eth0
10.244.0.0/24 via 10.0.0.61 dev eth0
10.244.1.0/24 via 10.0.0.121 dev eth0
10.244.2.0/24 via 10.0.0.120 dev eth0
10.244.3.0/24 via 10.244.3.57 dev cilium_host
10.244.4.0/24 via 10.0.0.123 dev eth0
10.244.5.0/24 via 10.0.0.124 dev eth0
172.16.0.0/16 dev eth1
```

- 每个节点一个 Pod /24；
- 跨节点 `10.244.x.0/24 via 节点 IP`（native routing）；
- 本节点 `10.244.3.0/24` 走 `cilium_host`；
- Cilium 的 eBPF 程序在 veth/TC 上做转发。

## 5. CNI 与 Cilium

本集群：

- CNI：Cilium `1.20.4`；
- KubeProxyReplacement=true；
- Routing: native；
- IPAM: kubernetes（每节点 /24）；
- 没有 kube-proxy。

查看：

```bash
cilium status
cilium-dbg status --verbose | head
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data}' | jq
```

## 6. DNS 与 Service

- Pod `/etc/resolv.conf` 指向 CoreDNS `10.96.0.10`；
- Service CIDR `10.96.0.0/12`；
- Cilium eBPF 在 socket/TC 层做 DNAT，不走 iptables。

```bash
# 在 Pod 里
cat /etc/resolv.conf
getent hosts kubernetes.default.svc.cluster.local
curl -s http://kubernetes.default.svc/healthz
```

## 7. 实验

```bash
# 找 Pod 的 pause PID
crictl pods --no-trunc
crictl inspectp <pod-id> | jq '.info.runtimeSpec.linux.namespaces'

# 进入 netns（只读）
nsenter --net=/proc/<pause-pid>/ns/net ip -br a
nsenter --net=/proc/<pause-pid>/ns/net ip r
nsenter --net=/proc/<pause-pid>/ns/net cat /etc/resolv.conf

# 宿主机侧
ip -br link | grep -E 'lxc|cilium|veth'
ip r
cilium status
```

## 8. 踩坑点

### 坑 1：hostNetwork Pod 的 netns 就是宿主

`nsenter` 进去看到 `eth0/eth1` 不代表命令错了，先看 Pod 是否 `hostNetwork: true`。

### 坑 2：把 veth 当网卡名

Pod 里是 `eth0@if9`，宿主机是 `lxcxxxx`；`iflink` 对应关系用 `ip -d link` 看。

### 坑 3：Pod IP 与节点 IP 混用

Pod IP `10.244.x.x`，节点 `10.0.0.x`。Service `10.96.x.x` 又是另一个网段。

### 坑 4：Cilium 节点没有 kube-proxy

不要去找 `KUBE-SERVICES`/kube-proxy；Service 由 eBPF 实现。

### 坑 5：MTU

Cilium native routing 通常 1500；如果底层有隧道/VXLAN，要减开销。MTU 不对会“小包通、大包挂”。

### 坑 6：NetworkPolicy 与 DNS

NetworkPolicy 默认可能挡 DNS；放行 UDP/TCP 53，否则“短域名能通、长域名超时”。

### 坑 7：`nsenter` 的 PID 会变

Pod 重建/容器重启后 pause PID 变化；用 `crictl inspectp` 重新取，不要缓存。

## 9. 一页命令

```bash
crictl pods --no-trunc
crictl inspectp <pod-id> | jq '.info.runtimeSpec.linux.namespaces'
nsenter --net=/proc/<pid>/ns/net ip -br a
nsenter --net=/proc/<pid>/ns/net ip r
nsenter --net=/proc/<pid>/ns/net cat /etc/resolv.conf
ip -br link | grep -E 'lxc|cilium|veth'
ip r
cilium status
```
