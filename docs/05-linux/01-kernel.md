# 01 · 内核：从 `/proc` 到模块、命名空间与 LSM

> 本章证据：[`assets/evidence/pve-host/collect.txt`](assets/evidence/pve-host/collect.txt)、
> [`k8s-m01/collect.txt`](assets/evidence/k8s-m01/collect.txt)、
> [`k8s-worker01/collect.txt`](assets/evidence/k8s-worker01/collect.txt)。
>
> 这一章不背内核源码，而是回答：**我怎么知道这台机器现在在跑什么内核、加载了什么、
> 哪些参数在生效、哪些安全机制开着。**

## 1. 当时的情况

同一套业务跑在 9 台 Linux 上，内核版本却不一样：

| 主机 | 发行版 | 内核 | LSM |
|---|---|---|---|
| teacher（PVE 宿主） | Debian 12 | `6.8.12-15-pve` | `lockdown,capability,yama,apparmor` |
| m01 | Rocky 9.6 | `5.14.0-570.58.1.el9_6` | `lockdown,capability,landlock,yama,selinux,bpf` |
| master01/02、worker01/02/03 | Ubuntu 22.04.5 | `5.15.0-202-generic` | `lockdown,capability,landlock,yama,apparmor` |
| ubuntu01（GitLab） | Ubuntu 24.04.4 | `6.8.0-147-generic` | `lockdown,capability,landlock,yama,apparmor` |
| ubuntu02（Harbor） | Ubuntu 24.04.4 | `6.8.0-147-generic` | 同上 |

这带来了几个真实问题：

- 同一份 eBPF/Cilium 配置，在不同内核上行为不完全一致；
- Ceph-CSI 3.18 标准镜像要求 `x86-64-v3`，旧 CPU 直接 `SIGILL`；
- m01 是 SELinux，其他节点是 AppArmor，容器安全策略不能照抄；
- PVE 的 `6.8.12-15-pve` 是 Proxmox 定制内核，不是 Debian 原版；
- 很多人把 `/proc` 当“配置文件”，改了重启就丢。

## 2. 主要概念

### 2.1 内核到底管什么

```text
用户态进程
  │  syscall（read/write/open/ioctl/futex/clone/...）
  ▼
内核
  ├─ 进程调度（CFS/EEVDF）
  ├─ 内存管理（页表、page cache、swap、OOM）
  ├─ 文件系统（VFS、ext4/xfs/overlayfs/NFS）
  ├─ 网络协议栈（TCP/IP、netfilter、eBPF）
  ├─ 设备驱动（virtio、nvme、rbd）
  ├─ 安全（LSM、capability、seccomp、namespaces）
  └─ cgroup（资源隔离/限制/统计）
  ▼
硬件 / 虚拟化层（KVM、QEMU、PVE）
```

内核不是“一个进程”，而是**所有进程共享的特权代码**。用户态只能通过 syscall 进入内核。

### 2.2 `/proc` 与 `/sys` 不是普通文件

- `/proc`：内核暴露的**进程/内核状态**（`/proc/meminfo`、`/proc/<pid>/status`、`/proc/sys`）；
- `/sys`：设备/驱动/内核对象的**结构化视图**（`/sys/fs/cgroup`、`/sys/kernel/security`）；
- 读写这些文件会触发内核回调，不是“改磁盘上的文本”。

```bash
# 读：内核版本/启动参数
uname -a
cat /proc/cmdline
cat /proc/version

# 读：内核参数
sysctl kernel.pid_max vm.swappiness
cat /proc/sys/kernel/pid_max

# 读：安全模块
cat /sys/kernel/security/lsm
```

### 2.3 模块：内核功能的“插件”

```bash
lsmod | head
modinfo br_netfilter
modprobe br_netfilter
```

本集群 K8s 节点必须加载：

```text
overlay
br_netfilter
```

对应文件：

```text
/etc/modules-load.d/k8s.conf
```

`br_netfilter` 让 bridge 流量经过 iptables/nftables；没有它，`net.bridge.bridge-nf-call-iptables`
即使写成 1 也不生效。

### 2.4 命名空间与 cgroup：内核的“隔离”和“限制”

| 机制 | 作用 | 本章关注 |
|---|---|---|
| namespace | 让进程看到独立的 PID/NET/MNT/UTS/IPC/USER | 进程/容器隔离 |
| cgroup | 限制/统计 CPU、内存、IO、PIDs | 资源限制 |
| LSM | 强制访问控制（SELinux/AppArmor） | 权限模型 |
| seccomp | 限制可调用的 syscall | 容器安全 |

检查：

```bash
lsns | head
cat /proc/1/cgroup
cat /sys/fs/cgroup/cgroup.controllers
```

本环境所有主机都是 **cgroup v2**（`cgroup2` 挂载在 `/sys/fs/cgroup`）。

## 3. 真机证据

### 3.1 内核版本与启动参数

PVE 宿主：

```text
$ uname -a
Linux teacher 6.8.12-15-pve #1 SMP PREEMPT_DYNAMIC PMX 6.8.12-15 (2025-09-12T11:02Z) x86_64 GNU/Linux

$ cat /proc/cmdline
BOOT_IMAGE=/boot/vmlinuz-6.8.12-15-pve root=/dev/mapper/pve-root ro quiet
```

m01（Rocky）：

```text
$ cat /proc/cmdline
BOOT_IMAGE=(hd0,msdos1)/vmlinuz-5.14.0-570.58.1.el9_6.x86_64 \
root=/dev/mapper/rl-root ro crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M \
resume=/dev/mapper/rl-swap rd.lvm.lv=rl/root rd.lvm.lv=rl/swap
```

worker01（Ubuntu）：

```text
$ cat /proc/cmdline
BOOT_IMAGE=/vmlinuz-5.15.0-202-generic root=/dev/mapper/ubuntu--vg-ubuntu--lv ro
```

能看出：

- PVE 用 LVM `pve-root` 作为根；
- m01 有 `crashkernel` 和 `resume=`（kdump/swap）；
- worker/Ubuntu 使用 LVM root；
- 都是 `ro` 启动，systemd 后续 remount rw。

### 3.2 模块

PVE 宿主 `lsmod` 前几行（完整见证据）：

```text
Module                  Size  Used by
tcp_diag               12288  0
inet_diag              28672  1 tcp_diag
xt_connmark            12288  6
xt_conntrack           12288  4
nf_tables             344064  0
nf_conntrack          184320  4 xt_conntrack,nf_nat,xt_connmark,xt_MASQUERADE
...
```

K8s 节点：

```bash
$ lsmod | grep -E 'overlay|br_netfilter'
overlay               151552  30
br_netfilter           32768  0
```

### 3.3 内核参数：先看，不要猜

```bash
$ sysctl kernel.pid_max kernel.threads-max vm.overcommit_memory vm.swappiness \
  fs.file-max net.core.somaxconn net.ipv4.ip_forward net.ipv4.conf.all.rp_filter

kernel.pid_max = 4194304
kernel.threads-max = 511694
vm.overcommit_memory = 0
vm.swappiness = 10
fs.file-max = 9223372036854775807
net.core.somaxconn = 4096
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
```

不同主机并不一样：

| 主机 | overcommit | swappiness | rp_filter | threads-max |
|---|---:|---:|---:|---:|
| PVE 宿主 | 0 | 10 | 2 | 511694 |
| m01 | 1 | 60 | 0 | 44971 |
| worker01 | 1 | 60 | 0 | 78591 |
| GitLab 201 | 0 | 60 | 0 | 63138 |
| Harbor 202 | 0 | 60 | 2 | 47010 |

> `rp_filter=0` 是 Cilium 节点的实际值（`99-zzz-override_cilium.conf` 覆盖）。
> CNPG 曾因 `rp_filter=1` 出现 webhook 全集群超时，详见 06 章。

### 3.4 安全模块

```text
$ cat /sys/kernel/security/lsm
lockdown,capability,landlock,yama,selinux,bpf     # m01
lockdown,capability,landlock,yama,apparmor        # Ubuntu / PVE
```

- **SELinux**：m01（Rocky）启用；
- **AppArmor**：Ubuntu/PVE 启用；
- **landlock**：用户态沙箱能力；
- **yama**：ptrace 限制；
- **lockdown**：内核完整性保护。

但注意：宿主启用 SELinux ≠ 容器启用 SELinux。本集群 containerd 配置里
`enable_selinux = false`，所以容器进程不会自动获得 SELinux 标签。**宿主 LSM 和容器 LSM 要分开看。**

### 3.5 内核日志

```bash
journalctl -k -b --no-pager | tail -40
```

PVE 宿主最近的日志主要是 VM 网卡：

```text
Nov 09 20:49:57 teacher kernel: vmbr1: port 2(tap120i0) entered blocking state
Nov 09 20:49:57 teacher kernel: vmbr1: port 2(tap120i0) entered forwarding state
...
```

这说明“内核日志”不一定是内核 bug；大量是虚拟网卡、磁盘、USB、OOM、网络协议栈事件。

## 4. 实验：读内核，不猜内核

```bash
# 1. 当前内核与启动参数
uname -a
cat /proc/cmdline
cat /proc/version

# 2. 模块
lsmod | head
grep -R . /etc/modules-load.d/ 2>/dev/null
modinfo br_netfilter | head

# 3. 内核参数
sysctl -a 2>/dev/null | grep -E '^(kernel|vm|fs|net\.core)\.' | head -40

# 4. 命名空间/ cgroup
lsns
cat /proc/self/cgroup
mount | grep cgroup

# 5. 安全模块
cat /sys/kernel/security/lsm
cat /proc/self/status | grep -E 'Cap|Seccomp|NoNewPrivs'

# 6. 内核日志
journalctl -k -b --no-pager | tail -50
```

## 5. 踩坑点

### 坑 1：把 PVE 内核当 Debian 原版

`6.8.12-15-pve` 是 Proxmox 定制内核，带 KVM/网络/存储补丁。装普通 Debian 内核可能丢 PVE 功能。
升级 PVE 要按 PVE 的 `apt` 源和流程，不要手工 `apt install linux-image-amd64`。

### 坑 2：模块没加载，sysctl 写了也不生效

`net.bridge.bridge-nf-call-iptables=1` 依赖 `br_netfilter`。正确顺序：

```bash
modprobe br_netfilter
sysctl --system
```

并写入 `/etc/modules-load.d/k8s.conf` 保证重启后加载。

### 坑 3：`sysctl -w` 重启即丢

`sysctl -w` 只改运行时；持久化要写 `/etc/sysctl.d/*.conf`，再 `sysctl --system`。
本集群的 `99-zz-k8s-rp-filter.conf` 和 `99-zzz-override_cilium.conf` 就是两个不同优先级的文件。

### 坑 4：内核版本跨度过大，eBPF 行为不同

PVE `6.8`、m01 `5.14`、worker `5.15`。Cilium 的 eBPF 特性依赖内核版本；
升级 Cilium 前要查内核矩阵，不能只看 Kubernetes 版本。

### 坑 5：CPU 基线不是内核版本

`x86-64-v3` 是用户态 ABI/指令集基线，不是内核版本。Ceph-CSI 镜像在 v2 CPU 上
`SIGILL`，升级内核没用，要改 QEMU CPU 型号（见 12 章 / 01 章）。

### 坑 6：`dmesg` 被限制

`kernel.dmesg_restrict=1` 时普通用户看不了 dmesg。用 root 或 `journalctl -k`。
本环境 PVE/worker01 是 1，m01 是 0；排障时不要以为“没有日志”。

### 坑 7：把 `/proc` 当磁盘文件

`/proc/meminfo` 是实时生成的，`cat` 两次数字就变了；`/proc/<pid>` 在进程退出后消失。
脚本不要缓存 `/proc` 路径，也不要把 `/proc` 内容当持久配置。

## 6. 一页命令

```bash
uname -a
cat /proc/cmdline
cat /proc/version
lsmod | head
grep -R . /etc/modules-load.d/ 2>/dev/null
sysctl kernel.pid_max vm.swappiness fs.file-max
cat /sys/kernel/security/lsm
cat /proc/self/status | grep -E 'Cap|Seccomp|NoNewPrivs'
lsns | head
mount | grep cgroup
journalctl -k -b --no-pager | tail -40
```

> 本章的数字来自 [`assets/evidence/`](assets/evidence/README.md)；
> 换一台机器请重新采集，不要复制结论。
