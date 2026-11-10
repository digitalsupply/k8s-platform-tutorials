# 05 · 进程：task_struct、fork/exec、信号、调度与 cgroup

> 本章证据：[`assets/evidence/pve-host/collect.txt`](assets/evidence/pve-host/collect.txt) 第 5 节、
> [`k8s-m01`](assets/evidence/k8s-m01/collect.txt)、[`k8s-worker01`](assets/evidence/k8s-worker01/collect.txt)、
> [`gitlab-201`](assets/evidence/gitlab-201/collect.txt)、[`harbor-202`](assets/evidence/harbor-202/collect.txt)、
> [`experiments/linux-lab.txt`](assets/evidence/experiments/linux-lab.txt) 第 7 节、
> [`k8s-security/worker01-cgroup.txt`](assets/evidence/k8s-security/worker01-cgroup.txt)。
>
> 这一章回答：**`ps` 里的 RSS/VSZ/STAT 到底是什么意思；为什么有僵尸进程；为什么 load average
> 很高但 CPU 很闲；容器里的 PID 1 和宿主机的 PID 是什么关系。**

## 1. 当时的情况

- PVE 宿主上 9 个 KVM 进程，每个 RSS 5–10GB，`ps` 看起来“内存都被 KVM 吃了”；
- m01 的 `kube-apiserver` RSS 1.7GB，`etcd` 190MB；
- worker01 上 1378 个线程，`load average 2.00`；
- GitLab 201 的 Ruby 进程 RSS 1.2GB × 4；
- 偶尔出现 `Z` 状态进程；
- 容器里 `ps` 只看到几个进程，宿主机 `ps` 能看到全部；
- 有人用 `ps` 的 RSS 相加判断内存，结果和 `free` 差很多。

## 2. 主要概念

### 2.1 进程是什么

内核用 `task_struct` 表示一个进程/线程：

```text
task_struct
  ├─ pid / tgid
  ├─ mm（地址空间，线程共享）
  ├─ files（打开的文件）
  ├─ fs（cwd/root）
  ├─ signal（信号处理）
  ├─ nsproxy（namespace）
  ├─ cgroups
  └─ sched_entity（调度实体）
```

- **进程**：有独立地址空间；
- **线程**：共享地址空间，内核里也是 `task_struct`；
- **PID**：命名空间内可见的 ID；
- **TGID**：线程组 ID（主线程 PID）。

### 2.2 fork / exec / wait

```text
fork()  → 复制 task_struct，子进程共享/CoW 地址空间
execve() → 加载新程序，替换地址空间
wait()/waitpid() → 父进程回收子进程退出状态
```

如果子进程退出而父进程没 `wait`，子进程变成 **zombie（Z）**：task_struct 还在，资源已释放。
父进程退出后，zombie 被 init/systemd 收养并回收。

### 2.3 进程状态

| 状态 | 含义 |
|---|---|
| `R` | running/runnable |
| `S` | interruptible sleep（等 I/O/事件） |
| `D` | uninterruptible sleep（通常等磁盘/NFS） |
| `Z` | zombie |
| `T` | stopped（SIGSTOP） |
| `I` | idle kernel thread |

`ps` 的 `STAT` 还会带 `s`（session leader）、`l`（多线程）、`+`（前台）、`N`（低优先级）。

### 2.4 调度与优先级

- `nice`：-20（最高）到 19（最低）；
- `priority`：内核动态优先级；
- CFS/EEVDF 按权重分配 CPU；
- `renice` 调 nice；
- `chrt` 调实时调度策略（慎用）。

真实实验：

```text
$ sleep 30 & p=$!; renice 10 -p $p
$ ps -o pid,ppid,ni,pri,stat,comm -p $p
    PID    PPID  NI PRI STAT COMMAND
2043949 2043948  10   9 SN   sleep
```

### 2.5 load average 不是 CPU 使用率

`/proc/loadavg` 统计 **R + D** 状态任务数（Linux 把不可中断睡眠也算进去）。
所以：

- NFS/磁盘卡住 → `D` 状态多 → load 高，CPU 可能很闲；
- 容器/线程多 → 任务数多；
- 要结合 `vmstat` 的 `r`/`b`、`%CPU`、PSI 看。

### 2.6 namespace 与 cgroup

```bash
lsns | head
cat /proc/1/cgroup
systemd-cgls /kubepods.slice | head
```

- namespace 决定“看到什么”；
- cgroup 决定“能用多少”；
- 容器 PID 1 在宿主机上是普通进程，只是 PID namespace 不同。

## 3. 真机证据

### 3.1 PVE 宿主：KVM 进程

```text
$ ps -eo pid,ppid,user,stat,ni,pri,pcpu,pmem,rss,vsz,comm --sort=-rss | head
    PID    PPID USER     STAT  NI PRI %CPU %MEM   RSS    VSZ COMMAND
1677443       1 root     Sl     0  19 86.9 15.3 10062420 11589316 kvm
1675010       1 root     Sl     0  19 77.9 15.1 9903632 11589312 kvm
1670131       1 root     Sl     0  19 79.0 12.3 8070688 9342504 kvm
   5169       1 root     Sl     0  19 15.7 10.8 7130864 11349180 kvm
...
```

- KVM 进程 RSS 约 10GB，是 guest 内存的宿主映射；
- `VSZ` 11.5GB 包含 QEMU 的虚拟地址空间；
- `%CPU` 是单核百分比，86.9 表示接近一个核跑满；
- 9 个 KVM + 其他进程，load average 8.21，但宿主有 40 核/80 线程，CPU 并不算高。

### 3.2 m01：K8s 控制面

```text
    PID    PPID USER     STAT  NI PRI %CPU %MEM   RSS    VSZ COMMAND
   7177    1403 root     Ssl    0  19  8.4 29.4 1706704 3185860 kube-apiserver
   1517    1296 root     Ssl    0  19  5.9  3.2  190904 11873432 etcd
   2329    2022 root     Ssl    0  19  3.4  3.0  176040 1534228 cilium-agent
    925       1 root     Ssl    0  19  3.3  1.4   85980 2221056 kubelet
    830       1 root     Ssl    0  19  1.2  1.2   70076 2637044 containerd
```

- `kube-apiserver` 1.7GB RSS，是控制面最大的进程；
- `etcd` 190MB RSS，但 VSZ 11.8GB（Go 运行时虚拟地址空间，不代表物理内存）；
- `containerd-shim` 是每个 Pod 的 shim，父进程是 containerd。

### 3.3 worker01：业务 + 可观测性

```text
   9125 ... hao ... 271304 ... MainThread
   7570 ... 10001 ... 252368 ... loki
   1577 ... root ... 250596 ... cilium-agent
   5627 ... 1001 ... 250436 ... java
  26188 ... root ... 247744 ... alloy
  19142 ... root ... 139512 ... kubelet
```

- Pod 内进程在宿主机上以 UID（10001、1001）出现；
- `MainThread` 是 Python 应用的主线程；
- 容器进程和宿主进程共享内核，`ps` 都能看到。

### 3.4 GitLab 201：Ruby/PostgreSQL

```text
   1749 ... git ... 1230684 ... ruby
   1753 ... git ... 1206852 ... ruby
   1469 ... git ... 1075164 ... ruby
   1336 ... git ...  970136 ... ruby
   1327 ... gitlab-+ ... 242960 ... prometheus
   1600 ... gitlab-+ ... 110428 ... postgres
```

GitLab 的 Puma/Sidekiq 是内存大户；`git` 用户运行，不是 root。

### 3.5 僵尸进程实验

```text
$ ps -o pid,ppid,stat,comm -p 2044173
    PID    PPID STAT COMMAND
2044173 2044171 Z    python3

$ grep -E '^(Name|State|PPid|Uid)' /proc/2044173/status
Name:   python3
State:  Z (zombie)
PPid:   2044171
Uid:    0 0 0 0
```

父进程退出后，僵尸被 systemd 收养并回收。

### 3.6 cgroup 树

worker01：

```text
/kubepods.slice
├─kubepods-burstable.slice
│ ├─kubepods-burstable-pod7ad24f2f_...slice
│ │ ├─cri-containerd-2bc0...scope
│ │ │ └─2236 /usr/local/bin/frpc ...
│ │ └─cri-containerd-01db...scope
│ │   └─2028 /pause
...
```

每个 Pod 有 pod-level cgroup，每个容器有 container-level scope。
`memory.max`/`cpu.max`/`pids.max` 在这些目录下（见第 06/08 章）。

## 4. 实验：观察进程生命周期

```bash
# 进程树
ps -eo pid,ppid,user,stat,ni,pri,pcpu,pmem,rss,vsz,comm --sort=-rss | head -25
pstree -ap | head

# 状态与 /proc
pid=$(pgrep -n sshd)
cat /proc/$pid/status | head -30
ls -l /proc/$pid/exe /proc/$pid/cwd /proc/$pid/root

# 优先级
sleep 30 & p=$!
renice 10 -p $p
ps -o pid,ppid,ni,pri,stat,comm -p $p
kill $p

# 命名空间
lsns | head
readlink /proc/$pid/ns/pid
readlink /proc/self/ns/pid

# cgroup
cat /proc/self/cgroup
systemd-cgls /kubepods.slice | head
```

## 5. 踩坑点

### 坑 1：用 RSS 相加判断内存

RSS 包含共享页（libc、page cache 映射），多进程相加会重复计算。
看内存用 `free`、cgroup `memory.current`、`smem`/PSS（如可用）。

### 坑 2：`VSZ` 很大不代表内存泄漏

Go/Java 程序会预留大量虚拟地址空间；`VSZ` 11GB、RSS 190MB 是正常的。
看 `RSS`/`PSS`/cgroup working set。

### 坑 3：load average 高但 CPU 闲

`D` 状态（NFS/磁盘/块设备）也计入 load。看 `vmstat` 的 `b` 列和 PSI。

### 坑 4：僵尸进程杀不掉

僵尸已经退出，`kill -9` 无效；要处理父进程（让它 `wait` 或退出）。
大量僵尸通常是父进程 bug。

### 坑 5：`ps` 看不到容器进程

容器 PID namespace 里 `ps` 只看到容器内进程；宿主机 `ps` 能看到全部。
排查容器要用 `crictl ps` / `crictl inspect`，不是只看宿主机 `ps`。

### 坑 6：PID 1 不回收子进程

容器里 PID 1 如果是普通应用，可能不处理 `SIGCHLD`，产生僵尸。
用 `tini`/`dumb-init` 或应用自己 `wait`。

### 坑 7：`D` 状态无法 kill

不可中断睡眠通常在等内核 I/O；`kill -9` 也要等 I/O 返回。先解决存储/NFS/块设备。

### 坑 8：线程数不是进程数

`ps -eLf | wc -l` 是线程数；`ps -e | wc -l` 是进程数。
Java/Go/Python 应用线程数可能远大于进程数。

## 6. 一页命令

```bash
ps -eo pid,ppid,user,stat,ni,pri,pcpu,pmem,rss,vsz,comm --sort=-rss | head -25
ps -eLf | wc -l
cat /proc/loadavg
cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io
cat /proc/<pid>/status
ls -l /proc/<pid>/exe /proc/<pid>/cwd
lsns | head
systemd-cgls /kubepods.slice | head
```
