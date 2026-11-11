# 01 · Linux 面试题：链接、进程、内存、文件系统、cgroup

> 证据：[`assets/evidence/`](assets/evidence/README.md)、
> [05 Linux 证据](../05-linux/assets/evidence/README.md)。

## 1. 软链接和硬链接

### 一句话

**硬链接**：同 inode，不可跨文件系统，不可链目录；**软链接**：独立 inode，内容是目标路径。

### 展开

- 硬链接：目录项指向同一个 inode，`links` 计数 +1；删除一个名字只是减计数，inode 还在。
- 软链接：新建一个 inode（类型 `l`），内容是目标路径；目标删除后变成 dangling。
- 硬链接不能跨 FS（inode 只在同一个 FS 内唯一），不能链目录（防止目录环）。
- 软链接可以跨 FS、可以链目录。

### 机器证据

05 实验：

```text
1070350 -rw-r--r-- 2 root root 5 ... file
1070350 -rw-r--r-- 2 root root 5 ... hard
1070351 lrwxrwxrwx 1 root root 26 ... sym -> file

file inode=1070350 links=2 size=5 blocks=8
hard inode=1070350 links=2 size=5 blocks=8
sym  inode=1070351 links=1 size=26 blocks=0
```

### 追问

- 删除原文件硬链接还能用吗？能，只要 links > 0。
- 软链接 `ls -l` 的 size 是什么？目标路径长度。
- `mv` 跨 FS 会怎样？复制 + 删除，inode 变。
- 为什么目录不能硬链接？避免环、简化 `..` 和 fsck。

## 2. 僵尸进程怎么清

### 一句话

`kill -9` 无效；僵尸已经退出，只能**杀父进程**或让父进程调用 `wait()/waitpid()` 回收。

### 展开

- 子进程退出，父进程没 `wait` → 保留 task_struct，状态 `Z`；
- 僵尸不占 CPU/内存，只占 PID/进程表项；
- 父进程退出后，僵尸被 init/systemd 收养并回收；
- 大量僵尸通常是父进程没处理 `SIGCHLD`/没 wait。

### 机器证据

05 实验：

```text
$ ps -o pid,ppid,stat,comm -p 2044173
    PID    PPID STAT COMMAND
2044173 2044171 Z    python3

$ grep -E '^(Name|State|PPid|Uid)' /proc/2044173/status
Name:   python3
State:  Z (zombie)
PPid:   2044171
```

### 追问

- 僵尸能 `kill -9` 吗？不能，已经死了。
- 容器里 PID 1 不回收怎么办？用 `tini`/`dumb-init`，或应用自己 wait。
- 怎么找僵尸？`ps -eo pid,ppid,stat,comm | awk '$3 ~ /Z/'`。

## 3. 负载高 CPU 低

### 一句话

通常是有 **D 状态**（不可中断睡眠）进程卡在磁盘/NFS/块设备；看 `vmstat` 的 `b` 列、`/proc/<pid>/wchan`、PSI。

### 展开

Linux load average = R（可运行）+ D（不可中断睡眠）任务数。
所以：

- CPU 忙 → R 多；
- IO/NFS 卡 → D 多，CPU 可能很闲；
- 线程多也会推高任务数。

### 机器证据

PVE 宿主：

```text
$ cat /proc/loadavg
8.21 6.27 5.54 17/1367 2043064

$ vmstat 1 3
 r  b   swpd   free ...
 8  0 ...
15  0 ...
13  1 ...
```

GitLab 201：

```text
PSI io some avg10=36.67 avg60=18.54
PSI io full avg10=35.95 avg60=18.22
```

本环境没有持续 D 状态进程；用 PSI/`b` 列观察 IO 阻塞。

### 追问

- load 高一定 CPU 忙吗？不一定，D 也算。
- 怎么定位 D？`ps -eo pid,stat,wchan:32,comm | awk '$2 ~ /D/'`。
- NFS 卡死怎么查？`nfsstat`、`mountstats`、`dmesg`、`/proc/<pid>/stack`。

## 4. free 里 cache 高要不要清

### 一句话

不用；page cache 是可回收内存，看 `available`，不是看 `free`。

### 展开

- `buff/cache` 缓存文件页，内存紧张时自动回收；
- `free` 的 `free` 很小是正常；
- `available` 是“还能给新进程用多少”的估计；
- 手动 `drop_caches` 会降低性能，生产不要做。

### 机器证据

worker01：

```text
               total        used        free      shared  buff/cache   available
Mem:           9.7Gi       3.4Gi       332Mi        24Mi       6.0Gi       5.9Gi
```

PVE：

```text
Mem: 62Gi used 59Gi free 622Mi buff/cache 3.1Gi available 3.0Gi
```

### 追问

- cache 和 buffer 区别？buffer 是块设备元数据，cache 是文件页。
- `available` 怎么估？可回收 page cache + 可回收 slab，扣除保留。
- 什么时候要清？几乎不用；只在高性能测试/特定基准时。

## 5. df 和 du 不一致

### 一句话

最常见是**文件已删除但被进程持有**（deleted open file）；用 `lsof +L1` 或 `lsof | grep deleted` 排查。

### 展开

其他原因：

- 稀疏文件：`ls` 看 size，`du` 看块；
- overlay/挂载重复；
- 硬链接：`du` 只算一次；
- NFS/RBD 延迟、配额；
- inode 耗尽（`df -i`）。

### 机器证据

本机实验：

```text
$ lsof +L1
python3 2188195 root 3r REG 252,1 209715200 0 1070693 /tmp/df-du-deleted.bin (deleted)

$ readlink /proc/<pid>/fd/3
/tmp/df-du-deleted.bin (deleted)
```

05 稀疏文件实验：

```text
-rw-r--r-- 1 root root 1.0G sparse
0       sparse
size=1073741824 blocks=0
```

### 追问

- 删了文件空间不回来？`lsof +L1`；重启/清空进程。
- `du` 为什么小？稀疏/硬链接/挂载边界。
- inode 满怎么查？`df -i`，找小文件目录。

## 6. 改 ulimit 不生效

### 一句话

`ulimit` 只影响当前 shell/子进程；systemd 服务要改 unit 的 `LimitNOFILE=`，`limits.conf` 不一定管 systemd。

### 展开

- soft/hard：进程可把 soft 提到 hard；
- systemd unit 的 `LimitNOFILE` 设置的是服务进程限制；
- `pam_limits` 在登录时应用 `limits.conf`；
- 服务由 systemd 启动，不经过 PAM login，所以 `limits.conf` 可能不生效。

### 机器证据

m01：

```text
$ ulimit -Sn; ulimit -Hn
1024
524288

$ grep -E 'Max open files' /proc/self/limits
Max open files 1024 524288 files

$ systemctl show sshd.service -p LimitNOFILE
LimitNOFILE=524288
```

PVE 宿主 root shell 是 1048576，因为 sshd/登录链路给的 hard/soft 更高。

### 追问

- 怎么让服务生效？`systemctl edit` 加 `[Service] LimitNOFILE=...`，`daemon-reload`，重启。
- `fs.file-max`/`fs.nr_open` 区别？系统级 vs 单进程。
- 容器里 ulimit？由 runtime/securityContext 决定。

## 7. cgroup v1/v2 区别

### 一句话

v1 每个控制器一套层级（多棵树）；v2 统一单层级树 + controllers 委托（一棵树，按 subtree 控制）。

### 展开

- v1：cpu、memory、blkio 等各自挂载，进程在不同树里；
- v2：`/sys/fs/cgroup` 统一挂载，`cgroup.controllers` 列出可用控制器；
- v2 用 `cgroup.subtree_control` 决定子 cgroup 启用哪些控制器；
- systemd 默认 `cgroup v2`，K8s/容器也用它。

### 机器证据

```text
$ stat -fc '%T' /sys/fs/cgroup
cgroup2fs

$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory hugetlb pids rdma misc
```

m01/worker01/201/202 都是 `cgroup2fs`。

### 追问

- v1 有什么问题？多层级不一致、委托困难。
- v2 怎么限制内存？`memory.max`/`memory.high`。
- 容器里怎么看到？`/sys/fs/cgroup/...`，由 runtime 挂载。

## 8. Ubuntu 24.04 迁移坑

### 一句话

netplan 1.x、Python 3.12（stdlib 移除 distutils）、apt 新 solver；但 setuptools 可能提供 distutils shim。

### 机器证据

```text
Ubuntu 24.04.4 LTS
Python 3.12.3
apt 2.8.4
netplan.io 1.1.2

$ python3 -c "import distutils; print(distutils.__file__)"
/usr/lib/python3/dist-packages/setuptools/_distutils/__init__.py

$ python3 -S -c "import distutils"
ModuleNotFoundError: No module named 'distutils'
```

### 追问

- 为什么裸 Python 失败？`-S` 不加载 site-packages，setuptools shim 不在。
- 迁移建议：用 `setuptools`/`packaging`，别依赖 stdlib distutils。
- netplan 1.x 变化？`netplan get/set/try`，YAML 仍是 v2。

## 9. Rocky 9 相比 CentOS 7

### 一句话

NetworkManager + nmcli、nftables、chrony、dnf、cgroup v2；`network-scripts` 默认不再安装，但 ifcfg 文件可能仍存在。

### 机器证据

```text
Rocky Linux 9.6
dnf 4.14.0
nmcli 1.52.0
nftables 1.0.9
chrony 4.6.1

$ rpm -q network-scripts
未安装软件包 network-scripts
$ ls /etc/sysconfig/network-scripts
ifcfg-ens18 ifcfg-eth0 ifcfg-eth1 readme-ifcfg-rh.txt
```

### 追问

- `network-scripts` 一定没有？包没装，但 ifcfg 兼容文件可能还在。
- 防火墙？firewalld/nftables，不是 iptables service。
- 时间同步？chronyd，不是 ntpd。

## 10. SELinux 与 AppArmor

### 一句话

SELinux 用标签/上下文授权（类型强制）；AppArmor 用路径/配置文件授权。两者都是 LSM，可叠加其他 LSM。

### 机器证据

```text
# m01
lockdown,capability,landlock,yama,selinux,bpf
SELinux status: disabled

# worker01/201
lockdown,capability,landlock,yama,apparmor
apparmor-enabled
```

### 追问

- 本机为什么 disabled？实验镜像/配置选择；默认目标不等于实际状态。
- 容器里生效吗？宿主 LSM + 容器 securityContext/`enable_selinux` 共同决定；本集群 containerd `enable_selinux=false`。
- 怎么排查？`ausearch`/`audit2allow`（SELinux）、`dmesg`/`aa-status`（AppArmor）。

## 11. epoll 为什么快

### 一句话

红黑树管理 fd + 就绪链表回调，`epoll_wait` 只返回就绪 fd，避免每次 O(n) 遍历和整表拷贝。

### 展开

- `epoll_create` 创建 eventpoll 对象；
- `epoll_ctl` 把 fd 插入红黑树；
- 内核回调把就绪 fd 挂到 ready list；
- `epoll_wait` 只拷贝就绪事件到用户态。

注意：**不是“零拷贝”**；注册/等待仍有少量拷贝，但不再拷贝整个 fd 集合。

### 机器证据

Harbor nginx worker：

```text
$ ls -l /proc/4514/fd | grep eventpoll
lrwx------ 1 10000 10000 64 ... 9 -> anon_inode:[eventpoll]

$ cat /proc/4514/fdinfo/9
tfd: 10 events: 80000019 data: ... pos:0 ino:38 sdev:f
```

### 追问

- epoll 一定比 select 快？高并发、大量 idle 连接时明显；少量 fd 未必。
- 水平触发 vs 边缘触发？LT 可重复通知，ET 只通知一次，必须读到 EAGAIN。
- 为什么 nginx 用 epoll？事件驱动 + 少量 worker + 大量连接。

## 一页命令

```bash
# 链接
ls -li file hard sym

# 僵尸
ps -eo pid,ppid,stat,comm | awk '$3 ~ /Z/'

# load/D
vmstat 1 3
ps -eo pid,stat,wchan:32,comm | awk '$2 ~ /D/'
cat /proc/pressure/io

# 内存
free -h
cat /proc/meminfo | grep -E 'MemAvailable|Cached|AnonPages'

# df/du
df -hT; df -i
lsof +L1 2>/dev/null | head

# ulimit
ulimit -Sn; ulimit -Hn
cat /proc/self/limits | grep 'Max open files'
systemctl show <unit> -p LimitNOFILE

# cgroup
stat -fc '%T' /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers

# epoll
ls -l /proc/<pid>/fd | grep eventpoll
```
