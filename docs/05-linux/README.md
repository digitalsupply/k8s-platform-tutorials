# 05 · Linux：内核、用户态、存储、权限、进程、内存与 systemd

> 这一章不是“Linux 命令大全”，而是把 **9 台真实机器**（PVE 宿主、6 个 K8s 节点、
> GitLab 201、Harbor 202）的内核、文件系统、权限、进程、内存、systemd 逐层拆开。
>
> 所有数字、日志、命令输出都来自 [`assets/evidence/`](assets/evidence/README.md)，
> 不是教科书默认值。这里用可复制的命令 transcript 代替截图，便于检索和复现。
>
> 容器运行时（Docker/containerd/CRI/镜像/overlay/安全）单独放在
> [14 Containers](../14-containers/README.md)。
> 对应的面试一句话答案见 [15 面试速查](../15-interview-cheatsheet/README.md)。

## 当时的情况

同一套平台，底层却不是一个模子：

| 主机 | 发行版 | 内核 | init | 角色 |
|---|---|---|---|---|
| teacher | Debian 12 | `6.8.12-15-pve` | systemd 252 | PVE 宿主机 |
| m01 | Rocky 9.6 | `5.14.0-570` | systemd 252 | K8s control-plane |
| master01/02 | Ubuntu 22.04.5 | `5.15.0-202` | systemd 249 | K8s control-plane |
| worker01/02/03 | Ubuntu 22.04.5 | `5.15.0-202` | systemd 249 | K8s worker |
| ubuntu01（201，Hyper-V VM） | Ubuntu 24.04.4 | `6.8.0-147` | systemd 255 | GitLab |
| ubuntu02（202，Hyper-V VM） | Ubuntu 24.04.4 | `6.8.0-147` | systemd 255 | Harbor |

真实问题：

- PVE 宿主 64GB 内存只剩 622Mi `free`，但 `available` 还有 3GB；
- m01 5.5GB 内存跑 apiserver 1.7GB，没有 swap；
- worker01 根盘 57G 用 28G，`DiskPressure` 过；
- 容器镜像里的 setuid 程序被 `find /` 扫出来，误判成宿主机后门；
- Cilium/CSI 是 privileged，业务 Pod 也偷偷加 `SYS_ADMIN`；
- PVE 启动 3 分 55 秒，worker 启动 23 秒；
- `ulimit -n` 是 1024，`systemctl show` 却写 524288；
- Ceph-CSI 标准镜像在旧 CPU 上 `SIGILL`。

## 怎么读

| 章节 | 主题 | 先解决什么问题 |
|---|---|---|
| [01 内核](01-kernel.md) | `/proc`、模块、LSM、namespace、cgroup | 这台机器在跑什么内核，开了什么安全机制 |
| [02 用户态](02-userspace.md) | init、libc、ELF、登录 shell、环境 | 为什么二进制跑不起来、`ssh cmd` 环境不同 |
| [03 文件系统与存储](03-filesystem-storage.md) | VFS、inode、ext4/xfs、LVM、overlay、RBD | `df`/`du` 对不上、空间不回收 |
| [04 权限模型](04-permissions-ugo-to-capabilities.md) | UGO、ACL、setuid、capability、seccomp | 为什么 root 能读、容器为什么 privileged |
| [05 进程](05-processes.md) | task_struct、fork/exec、信号、调度、cgroup | `ps` 指标、僵尸、load average、容器 PID |
| [06 内存](06-memory.md) | 虚拟内存、page cache、overcommit、OOM、cgroup v2 | `free` 怎么看、为什么没 OOM、谁杀了容器 |
| [07 systemd 与启动](07-systemd-boot.md) | firmware→loader→kernel→systemd | 启动慢、服务起不来、unit 依赖 |
| [08 内核参数与限制](08-kernel-params-limits.md) | sysctl、ulimit、systemd、cgroup | 参数不生效、fd/pid/内存限制 |
| [09 跨层案例](09-case-studies.md) | PVE/Ceph/K8s/GitLab/Harbor 8 个案例 | 把前面概念串成排障链 |
| [labs/](labs/README.md) | 8 个实验 | 动手验证 |

推荐顺序：**01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 → 09**。
如果正在排障，直接看 09 的案例，再回到对应章节。

## 一条主线

```text
硬件 / PVE / KVM
  ↓
内核（调度、内存、VFS、网络、LSM、cgroup）
  ↓
用户态（systemd、libc、shell、服务）
  ↓
文件系统（ext4/xfs/overlay/RBD）+ 权限（UGO/ACL/capability）
  ↓
进程（fork/exec/信号/cgroup）+ 内存（page cache/anon/swap）
  ↓
K8s（kubelet/containerd/Cilium/Pod）
  ↓
应用（GitLab/Harbor/业务）
```

排障时不要跳层。一个“Pod OOM”可能是：

```text
应用泄漏 → cgroup memory.max → 节点 MemAvailable → PVE thin pool/内存 → 物理机
```

## 真机证据

| 证据 | 内容 |
|---|---|
| [`assets/evidence/pve-host/`](assets/evidence/pve-host/collect.txt) | PVE 宿主 11 节完整输出 |
| [`assets/evidence/k8s-m01/`](assets/evidence/k8s-m01/collect.txt) | m01（Rocky + SELinux） |
| [`assets/evidence/k8s-worker01/`](assets/evidence/k8s-worker01/collect.txt) | worker01（Ubuntu + RBD + overlay） |
| `k8s-master01/02`、`k8s-worker02/03` | 其余 K8s 节点 |
| [`assets/evidence/gitlab-201/`](assets/evidence/gitlab-201/collect.txt) | GitLab 宿主机 |
| [`assets/evidence/harbor-202/`](assets/evidence/harbor-202/collect.txt) | Harbor 宿主机 |
| [`assets/evidence/experiments/linux-lab.txt`](assets/evidence/experiments/linux-lab.txt) | umask/ACL/setuid/capability/稀疏文件/页缓存/僵尸/systemd 限制 |
| [`assets/evidence/k8s-security/pod-security-summary.txt`](assets/evidence/k8s-security/pod-security-summary.txt) | 138 个 Pod 的 hostNetwork/privileged/capabilities/seccomp |
| [`assets/evidence/limits/`](assets/evidence/limits/) | ulimit soft/hard、systemd 限制、fs.nr_open |
| [`assets/evidence/cgroup/`](assets/evidence/cgroup/) | worker01 Pod cgroup v2 样本 |

采集脚本：

```bash
bash docs/05-linux/scripts/collect_linux_evidence.sh > evidence.txt
ssh root@10.0.0.61 'bash -s' < docs/05-linux/scripts/collect_linux_evidence.sh > m01.txt
```

## 原有内容

| 文档 | 内容 |
|---|---|
| [sudo-su-详解.md](sudo-su-详解.md) | su/sudo、PAM、setuid、无密码 SSH、直接进 root 的原理与实验 |
| [notes/worker-disk-expansion-20261028.md](notes/worker-disk-expansion-20261028.md) | PVE 虚拟盘在线扩容：分区/LVM/ext4 全链路 |
| [notes/memory-analysis-m01.md](notes/memory-analysis-m01.md) | m01 节点内存构成、进程 TOP、Pod/容器内存拆解 |
| [notes/app-removal-record.md](notes/app-removal-record.md) | 宿主机 Zabbix/MariaDB/nginx/php-fpm 下线记录 |

## 配套脚本

| 脚本 | 说明 |
|---|---|
| [scripts/collect_linux_evidence.sh](scripts/collect_linux_evidence.sh) | 只读采集 11 类证据，输出 Markdown 风格文本 |
| [scripts/linux_lab_experiments.sh](scripts/linux_lab_experiments.sh) | 在 `/tmp` 做权限/ACL/capability/页缓存/僵尸/systemd 限制实验 |
| [scripts/sudo_audit.py](scripts/sudo_audit.py) | 只读 sudo/SSH 权限审计 |
| [scripts/grow-lvm.sh](scripts/grow-lvm.sh) | LVM 在线扩容辅助脚本 |
| [scripts/change_repo.sh](scripts/change_repo.sh) | Rocky Linux 仓库切换 |
| [scripts/change_epel.sh](scripts/change_epel.sh) | EPEL 仓库配置 |
| [scripts/dnf.sh](scripts/dnf.sh) | 常用包安装 |
| [scripts/kata-manager.sh](scripts/kata-manager.sh) | Kata Containers 安装/管理工具 |

```bash
# 只读审计
sudo python3 docs/05-linux/scripts/sudo_audit.py

# 真实实验（只在 /tmp，退出清理）
sudo bash docs/05-linux/scripts/linux_lab_experiments.sh
```

## 三个最容易犯的错

1. **用 `free` 的 `free` 判断内存**：看 `available` 和 cgroup `memory.current`；
2. **用 `df` 判断 thin pool/RBD**：`lvs`、`pvesm`、`ceph df`、`rbd du`；
3. **把容器镜像里的 setuid 程序当宿主机后门**：`find` 要排除 `/var/lib/docker`、`/var/lib/containerd`。

> 生产环境请遵循组织的权限/变更制度；本章实验只用于学习和排障。
