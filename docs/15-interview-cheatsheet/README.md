# 15 · 面试一句话答案：Linux / 网络 / 云原生

> 这不是又一份“八股表”。每题给：
>
> 1. **一句话答案**（面试可直接说）；
> 2. **机器实证 / 本环境纠偏**（避免背错）；
> 3. **追问与易错点**；
> 4. **详细章节链接**。
>
> 证据：[`assets/evidence/`](assets/evidence/README.md)。
> 详细原理：[05 Linux](../05-linux/README.md)、[07 Networking](../07-networking/README.md)、
> [14 Containers](../14-containers/README.md)。

## 一页速查

| 知识点 | 一句话答案 | 本环境实证/纠偏 |
|---|---|---|
| 软链接 vs 硬链接 | 硬链接同 inode、不可跨 FS、不可链目录；软链接独立 inode、存目标路径 | 05 实验：`file`/`hard` 同 inode `1070350`，`sym` 独立 `1070351` |
| 僵尸进程怎么清 | `kill -9` 无效；杀父进程或让父进程 `wait()` | 05 实验：`State: Z`，`PPid` 指向父进程 |
| 负载高 CPU 低 | 有 `D` 状态进程卡在 IO/NFS；看 `vmstat` 的 `b`、`wchan`、PSI | PVE load 8.21/40 核；GitLab IO PSI `full 35.95`；本环境无持续 D |
| free 的 cache 要不要清 | 不用；cache 可回收，看 `available` | worker01 `free` 332Mi 但 `available` 5.9Gi |
| TIME_WAIT vs CLOSE_WAIT | TIME_WAIT 主动关闭方，会自愈；CLOSE_WAIT 应用没 `close()` | worker01 TIME_WAIT 127；实验 CLOSE_WAIT 1 |
| 三次握手为什么不是两次 | 防历史重复 SYN + 确认双方收发能力 | tcpdump 抓到 SYN / SYN-ACK / ACK |
| refused / timeout / reset | refused=有 RST；timeout=无响应；reset=建立后被重置 | 本机实测三种异常 |
| df 和 du 不一致 | 文件已删除但被进程持有；`lsof +L1` | 200MiB 删除文件仍被 Python 打开，`(deleted)` |
| 改 ulimit 不生效 | systemd 服务要改 unit `LimitNOFILE`；`limits.conf` 不一定管 systemd | m01 soft 1024/hard 524288，systemd `LimitNOFILE=524288` |
| cgroup v1/v2 | v1 各控制器多层级；v2 统一单层级 + controllers 委托 | 所有主机 `cgroup2fs`，controllers 统一 |
| OOMKilled vs Evicted | OOMKilled=超 cgroup memory limit 被内核杀；Evicted=节点压力被 kubelet 驱逐 | 当前无 OOM/Evicted；6 节点压力条件全 False |
| Ubuntu 24.04 迁移坑 | netplan 1.x、Python 3.12、apt 新 solver；distutils 从 stdlib 移除 | 24.04.4 / Python 3.12.3 / netplan 1.1.2 / apt 2.8.4；setuptools 仍提供 shim |
| Rocky 9 vs CentOS 7 | NetworkManager、nftables、chrony、dnf、cgroup v2 | `network-scripts` 包未装但 ifcfg 文件仍在；SELinux 本机 disabled |
| SELinux vs AppArmor | SELinux 标签/上下文；AppArmor 路径 | m01 SELinux disabled；Ubuntu AppArmor enabled |
| 容器为什么要 tini | PID 1 不自动回收僵尸、默认不处理 SIGTERM | frpc `NSpid: 2236 1`，没有 tini |
| epoll 为什么快 | 红黑树 + 就绪链表，只返回就绪 fd | Harbor nginx worker `anon_inode:[eventpoll]`；注意“零拷贝”说法不准确 |

## 二、本环境纠偏（面试别背绝对话）

### 1. “Rocky 9 把 network-scripts 全删了”

不准确。本机：

```text
$ rpm -q network-scripts
未安装软件包 network-scripts

$ ls /etc/sysconfig/network-scripts
ifcfg-ens18  ifcfg-eth0  ifcfg-eth1  readme-ifcfg-rh.txt
```

- `network-scripts` 包确实不再默认安装；
- 但 ifcfg 文件仍可由 NetworkManager 读取/兼容；
- 真正变化是 **NetworkManager + nmcli + nftables + chrony + dnf + cgroup v2**。

### 2. “Rocky 默认 SELinux enforcing”

本机 m01：

```text
$ grep '^SELINUX=' /etc/selinux/config
SELINUX=disabled

$ getenforce
Disabled
```

Rocky/RHEL 的**默认目标**是 enforcing，但实验室/镜像可能关闭。
面试要说“机制”，不要断言“所有 Rocky 都 enforcing”。

### 3. “Ubuntu 24.04 没有 distutils”

准确说法：**Python 3.12 从标准库移除了 distutils**，但 `python3-setuptools` 可能提供
`setuptools._distutils` 兼容层。

本机：

```text
$ python3 -c "import distutils; print(distutils.__file__)"
/usr/lib/python3/dist-packages/setuptools/_distutils/__init__.py

$ python3 -S -c "import distutils"
ModuleNotFoundError: No module named 'distutils'
```

所以：

- 裸 Python、无 setuptools：会失败；
- 装了 setuptools：可能还能 import；
- 新代码应改用 `setuptools`/`packaging`，不要依赖 stdlib distutils。

### 4. “epoll 完全不拷贝”

不准确。`epoll_wait` 仍会把**就绪事件**拷贝到用户态；它避免的是：
- 每次遍历整个 fd 集合（O(n)）；
- 把整个 fd 集合反复拷贝。

准确说：**红黑树管理 fd，就绪链表回调，只返回就绪事件**。

### 5. “OOMKilled 和 Evicted 是一回事”

不是：

- **OOMKilled**：容器 cgroup 内存超 `memory.max`，内核 OOM killer 杀进程，Pod 重启；
- **Evicted**：节点 Memory/Disk/PIDPressure，kubelet 驱逐 Pod，Pod 可能被重建到别的节点。

本环境当前没有 OOM/Evicted 历史；6 节点压力条件全 `False`。机制仍要会。

## 三、详细章节

| 文件 | 内容 |
|---|---|
| [01-linux.md](01-linux.md) | 硬/软链接、僵尸、load、free、df/du、ulimit、cgroup、Ubuntu/Rocky、SELinux/AppArmor、epoll |
| [02-network.md](02-network.md) | TIME_WAIT/CLOSE_WAIT、三次握手、refused/timeout/reset |
| [03-cloud-native.md](03-cloud-native.md) | OOMKilled vs Evicted、tini、cgroup 与容器 |
| [labs/README.md](labs/README.md) | 复现实验 |
| [assets/evidence/](assets/evidence/README.md) | 机器输出 |

## 四、怎么用

1. 先看“一页速查”，能一句话说清；
2. 再看详细章节的“为什么”和“追问”；
3. 面试前跑一遍 [labs](labs/README.md) 的只读命令；
4. 不要把本环境的数字当通用结论，换机器要重新采集。

> 面试官要的不是“背答案”，而是你能从现象定位到内核/网络/运行时/编排层。
> 这一章的所有答案都能在本仓库找到证据。
