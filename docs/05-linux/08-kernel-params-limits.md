# 08 · 内核参数与资源限制：sysctl、ulimit、systemd 与 cgroup

> 本章证据：[`assets/evidence/limits/`](assets/evidence/limits/)、
> [`pve-host/collect.txt`](assets/evidence/pve-host/collect.txt) 第 8 节、
> [`k8s-m01`](assets/evidence/k8s-m01/collect.txt)、[`k8s-worker01`](assets/evidence/k8s-worker01/collect.txt)、
> [`gitlab-201`](assets/evidence/gitlab-201/collect.txt)、[`harbor-202`](assets/evidence/harbor-202/collect.txt)。
>
> 这一章回答：**为什么 `ulimit -n` 是 1024，`systemctl show` 却写 524288；改 `/etc/sysctl.conf`
> 为什么没生效；容器里的 `nofile`/`pid`/`memory` 到底受谁限制。**

## 1. 当时的情况

- PVE 宿主 root shell `ulimit -n` = **1048576**；
- m01/worker/201/202 root shell `ulimit -n` = **1024**，但 `systemd` 的 `LimitNOFILE` 是 **524288**；
- `fs.file-max`：201 是 1000000，其他是 `9223372036854775807`；
- `net.core.somaxconn`：201 是 2048，其他 4096；
- `vm.overcommit_memory`：PVE/201/202 是 0，k8s 节点是 1；
- `rp_filter`：PVE/202 是 2，k8s 节点是 0；
- `/etc/security/limits.conf` 基本为空，限制主要来自 systemd/PAM/内核默认。

## 2. 主要概念

### 2.1 sysctl 的层次

```text
/proc/sys/<subsystem>/<key>
  ↕
sysctl <key>
  ↕
/etc/sysctl.d/*.conf
/etc/sysctl.conf
```

加载顺序（大致）：

```text
/etc/sysctl.d/*.conf（按文件名排序）
/etc/sysctl.conf
```

后面的覆盖前面的。`sysctl --system` 重新加载所有配置。

常用命名空间：

| 前缀 | 作用 |
|---|---|
| `kernel.*` | PID、线程、panic、sysrq、randomize |
| `vm.*` | 内存、swap、overcommit、dirty |
| `fs.*` | 文件句柄、inotify、aio |
| `net.core.*` | 全局限流/连接队列 |
| `net.ipv4.*` | TCP/IP、转发、rp_filter |
| `net.ipv6.*` | IPv6 |

### 2.2 ulimit：进程级软/硬限制

```bash
ulimit -Sn     # soft open files
ulimit -Hn     # hard open files
ulimit -a
cat /proc/self/limits
```

- **soft**：当前生效值，进程可自行提高到 hard；
- **hard**：上限，非 root 不能提高；
- `LimitNOFILE` 是 systemd 给服务的 hard/soft 配置；
- `fs.nr_open` 是内核允许的单进程最大 fd 数；
- `fs.file-max` 是系统级最大文件句柄数。

### 2.3 systemd 限制 vs shell 限制

`systemctl show <unit> -p LimitNOFILE -p LimitNPROC` 看 unit 的配置；
`/proc/<pid>/limits` 看进程实际值。

真实 m01：

```text
$ ulimit -Sn; ulimit -Hn
1024
524288

$ grep -E 'Max open files|Max processes' /proc/self/limits
Max processes             22485   22485   processes
Max open files            1024    524288  files

$ systemctl show sshd.service -p LimitNOFILE -p LimitNPROC
LimitNOFILE=524288
LimitNPROC=22485
```

解释：

- systemd 把 **hard** 设为 524288；
- 登录 shell 的 **soft** 仍是 1024（PAM/默认）；
- 进程可以 `ulimit -n 524288` 自己提高，但不能超过 hard。

### 2.4 PAM limits

`/etc/security/limits.conf` 和 `/etc/security/limits.d/*.conf` 由 `pam_limits` 应用。
`sshd`/`login`/`su` 的 PAM 配置决定是否加载。

```bash
grep -R . /etc/security/limits.conf /etc/security/limits.d 2>/dev/null
grep -R pam_limits /etc/pam.d 2>/dev/null
```

### 2.5 cgroup v2 限制

systemd 的 `MemoryMax`、`CPUQuota`、`TasksMax` 最终写到 cgroup：

```bash
cat /sys/fs/cgroup/system.slice/<unit>/memory.max
cat /sys/fs/cgroup/system.slice/<unit>/cpu.max
cat /sys/fs/cgroup/system.slice/<unit>/pids.max
```

K8s 的 Pod/容器限制也在 cgroup：

```bash
cat /sys/fs/cgroup/kubepods.slice/.../memory.max
```

### 2.6 关键参数

| 参数 | 作用 | 过大/过小风险 |
|---|---|---|
| `fs.file-max` | 系统级 fd 上限 | 太大无意义，太小会 `ENFILE` |
| `fs.nr_open` | 单进程 fd 上限（`RLIMIT_NOFILE` 的上限值） | 调小会让 `ulimit -n` 提不上去；**与 `fs.file-max` 无大小约束关系**（file-max 是系统级总量，nr_open 是单进程闸门） |
| `kernel.pid_max` | PID 上限 | 太小会 `fork: Cannot allocate memory` |
| `kernel.threads-max` | 线程上限 | 与内存/pid 相关 |
| `vm.overcommit_memory` | 内存超分策略 | 1 容易 OOM，2 可能分配失败 |
| `vm.swappiness` | swap 倾向 | K8s 节点通常 0/10 |
| `net.core.somaxconn` | listen backlog | 高并发服务要够大 |
| `net.ipv4.ip_local_port_range` | 临时端口 | 客户端连接多要扩大 |
| `net.ipv4.conf.*.rp_filter` | 反向路径过滤 | 1 严格，易误丢包；Cilium 节点用 0/2 |

## 3. 真机证据

### 3.1 限制总表

| 主机 | ulimit soft/hard | unit LimitNOFILE | fs.nr_open | fs.file-max | pid_max | threads-max | somaxconn |
|---|---|---|---:|---:|---:|---:|---:|
| PVE 宿主 | 1048576 / 1048576 | sshd 524288 | 1048576 | 9.22e18 | 4194304 | 511694 | 4096 |
| m01 | 1024 / 524288 | sshd 524288 | 1073741816 | 9.22e18 | 4194304 | 44971 | 4096 |
| worker01 | 1024 / 1048576 | ssh 524288 | 1048576 | 9.22e18 | 4194304 | 78591 | 4096 |
| GitLab 201 | 1024 / 1048576 | ssh 524288 | 1048576 | 1000000 | 4194304 | 63138 | 2048 |
| Harbor 202 | 1024 / 1048576 | ssh 524288 | 1048576 | 9.22e18 | 4194304 | 47010 | 4096 |

> 201 的 `fs.file-max=1000000` 是 Ubuntu 默认；其他主机是 `9223372036854775807`（几乎无上限）。
> `fs.nr_open` 才是单进程真正上限。

### 3.2 `/proc/self/limits`

```text
Max processes             22485   22485   processes
Max open files            1024    524288  files
Max locked memory         8192    8192    bytes
Max pending signals       22485   22485   signals
```

- `Max open files` 的 soft 1024、hard 524288；
- `Max locked memory` 8MB，影响 `mlock`/eBPF/数据库；
- `Max processes` 与 `threads-max`/cgroup pids 相关。

### 3.3 `fs.file-nr`

```text
# PVE
6432    0    9223372036854775807
# m01
2496    0    9223372036854775807
# worker01
4448    0    9223372036854775807
# GitLab 201
9248    0    1000000
```

格式：`已分配  未使用  上限`。第一列接近上限时才需要担心。

### 3.4 `rp_filter` 差异

```text
PVE:      net.ipv4.conf.all.rp_filter = 2
m01:      net.ipv4.conf.all.rp_filter = 0
worker01: net.ipv4.conf.all.rp_filter = 0
201:      net.ipv4.conf.all.rp_filter = 0
202:      net.ipv4.conf.all.rp_filter = 2
```

Cilium 节点用 0/2，strict 1 会导致 CNPG webhook/转发异常。改之前先看 Cilium 的
`99-zzz-override_cilium.conf`，不要只改 `99-zz-k8s-rp-filter.conf`。

### 3.5 systemd 临时限制

```text
$ systemd-run --unit=lab --property=MemoryMax=64M --property=CPUQuota=20% /bin/sleep 30
$ systemctl show lab -p MemoryMax -p CPUQuota -p TasksMax
MemoryMax=67108864
TasksMax=16
$ cat /sys/fs/cgroup/system.slice/lab.service/memory.max
67108864
$ cat .../cpu.max
20000 100000
```

## 4. 实验：soft/hard 与 cgroup

```bash
# 1. 看当前 soft/hard
ulimit -Sn; ulimit -Hn
cat /proc/self/limits | grep -E 'Max open files|Max processes'

# 2. 在子 shell 提高 soft（不超过 hard）
( ulimit -n 4096; ulimit -Sn )
ulimit -Sn

# 3. 看 systemd unit 的限制
systemctl show sshd -p LimitNOFILE -p LimitNPROC
systemctl show user.slice -p LimitNOFILE

# 4. 看内核全局限制
sysctl fs.file-max fs.nr_open kernel.pid_max kernel.threads-max
cat /proc/sys/fs/file-nr

# 5. 临时 cgroup 限制
systemd-run --unit=lab-mem --property=MemoryMax=64M --property=CPUQuota=20% /bin/sleep 30
systemctl show lab-mem -p MemoryMax -p CPUQuota
cat /sys/fs/cgroup/system.slice/lab-mem.service/memory.max
systemctl stop lab-mem
```

## 5. 踩坑点

### 坑 1：只改 `/etc/sysctl.conf`

很多发行版优先读 `/etc/sysctl.d/*.conf`，且文件名排序。改完要：

```bash
sysctl --system
sysctl <key>
```

不要只 `sysctl -w`。

### 坑 2：`ulimit -n` 改了，服务还是 1024

`ulimit` 只影响当前 shell/子进程。systemd 服务要改 unit 的 `LimitNOFILE=`，
然后 `daemon-reload` + 重启服务。

### 坑 3：soft 1024 / hard 524288 被误判为“限制没生效”

`systemctl show` 显示的是 unit 配置（hard），`ulimit -Sn` 是当前 soft。
进程可以自己提高 soft 到 hard；不是矛盾。

### 坑 4：`fs.file-max` 很大但 `fs.nr_open` 限制单进程

`file-max` 是系统级，`nr_open` 是单进程。`LimitNOFILE` 不能超过 `nr_open`。

### 坑 5：`rp_filter=1` 导致 Cilium/CNPG 异常

严格模式会丢弃“反向路径不一致”的包。Cilium 节点统一 0/2，并注意多个 sysctl 文件的覆盖顺序。

### 坑 6：`vm.overcommit_memory=1` 提高 OOM 风险

K8s 节点允许超分，但数据库/控制面要监控 `Committed_AS`/`MemAvailable`。
不要在不了解业务的情况下改成 1。

### 坑 7：`somaxconn` 与 backlog 不匹配

应用 listen backlog 大于 `somaxconn` 时会被截断。高并发入口要同时调
`net.core.somaxconn` 和应用 backlog。

### 坑 8：`pid_max` 改大不等于线程数够

`kernel.threads-max`、cgroup `pids.max`、`ulimit -u` 都可能先限制。
容器里还要看 `pids.max`。

### 坑 9：cgroup 限制与 ulimit 双重限制

systemd `TasksMax`/`MemoryMax` 和 `LimitNPROC`/`LimitNOFILE` 是不同层；
排查看 `/proc/<pid>/limits` + `/sys/fs/cgroup/...`。

## 6. 一页命令

```bash
sysctl kernel.pid_max kernel.threads-max vm.overcommit_memory vm.swappiness
sysctl fs.file-max fs.nr_open
cat /proc/sys/fs/file-nr
ulimit -a
cat /proc/self/limits
systemctl show <unit> -p LimitNOFILE -p LimitNPROC -p MemoryMax -p CPUQuota -p TasksMax
cat /sys/fs/cgroup/system.slice/<unit>/memory.max
cat /sys/fs/cgroup/system.slice/<unit>/cpu.max
cat /sys/fs/cgroup/system.slice/<unit>/pids.max
```
