# 面试速查证据索引

这些输出用于证明“一句话答案”不是背的，而是能从机器上验出来。

| 文件 | 证明什么 |
|---|---|
| `handshake.txt` | 本机 loopback 上 tcpdump 抓到的 SYN / SYN-ACK / ACK 三次握手 |
| `network-states-pve-host.txt`、`network-states-worker01.txt`、`network-states-gitlab-201.txt`、`network-states-harbor-202.txt` | `ss` 的 ESTABLISHED / SYN-SENT / TIME_WAIT / CLOSE_WAIT 计数；worker01 有 127 个 TIME_WAIT |
| `connect-errors.txt` | 本机实测 `ConnectionRefusedError` / `TimeoutError` / `ConnectionResetError` |
| `close-wait.txt` | 一个“客户端关闭、服务端不 close”的实验，服务端进入 CLOSE_WAIT |
| `df-du-deleted.txt` | 删除但仍被进程打开的 200MiB 文件；`lsof +L1` 可见 `(deleted)` |
| `oom-evicted.txt` | 当前 138 Pod 的 lastState 原因统计、6 节点 Memory/Disk/PIDPressure 条件 |
| `cgroup-v2.txt` | 所有主机 `/sys/fs/cgroup` 都是 `cgroup2fs`，controllers 列表 |
| `os-migration-lsm.txt` | Ubuntu 24.04 / Rocky 9 的实际版本、Python 3.12、dnf/nmcli/nft/chrony、SELinux/AppArmor |
| `tini-pid1.txt` | frpc 容器进程 `NSpid: 2236 1`，PID 1 就是应用，没有 tini |
| `epoll-harbor-nginx.txt` | Harbor nginx worker 的 `anon_inode:[eventpoll]` 和 fdinfo |

## 复用 05 Linux 的证据

以下答案直接复用 [`05-linux/assets/evidence/`](../../../05-linux/assets/evidence/README.md)：

- 硬链接/软链接/稀疏文件：`experiments/linux-lab.txt`；
- 僵尸进程：`experiments/linux-lab.txt` 第 7 节；
- `free` 的 buff/cache：`pve-host/collect.txt`、`k8s-worker01/collect.txt` 第 6 节；
- `ulimit` soft/hard 与 systemd `LimitNOFILE`：`limits/`；
- cgroup v2：`cgroup/worker01-pod-cgroup.txt`。

## 存储证据

见 [`06-storage-ceph/assets/storage-basics/`](../../../06-storage-ceph/assets/storage-basics/README.md)：

- 分区/GPT/MBR、LVM/thin pool、fstab、NFS、Ceph、CSI/PV/PVC、SMART、dmesg。

## Kubernetes 证据

见 [`01-kubernetes-k3s/assets/interview-evidence/`](../../../01-kubernetes-k3s/assets/interview-evidence/README.md)：

- apiserver/etcd/scheduler/controller-manager、kubelet/CRI/CNI/CSI；
- QoS、LimitRange/Quota、PDB、探针、证书、etcd 备份；
- CRD/Operator、Webhook、APIService、多租户、HPA/VPA、Cilium、Gateway API。

## 全量验证矩阵

[`00-verification-matrix.md`](../../00-verification-matrix.md) 汇总了 Linux/网络/存储/K8s 共 60+ 条断言的
✅ 实测 / ⚠️ 部分 / ❌ 不具备 / 📚 仅原理。

## 采集边界

- 没有制造真实 OOM/Evicted（会影响生产）；用 cgroup 样本和节点条件说明机制；
- 没有真实 NFS 卡死；用 `vmstat b`、PSI 和 `wchan` 方法说明 D 状态；
- 所有实验在 `/tmp` 或 loopback，退出清理。
