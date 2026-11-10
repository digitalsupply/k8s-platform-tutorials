# 06 · 内存：虚拟内存、page cache、overcommit、OOM 与 cgroup v2

> 本章证据：[`assets/evidence/pve-host/collect.txt`](assets/evidence/pve-host/collect.txt) 第 6 节、
> [`k8s-m01`](assets/evidence/k8s-m01/collect.txt)、[`k8s-worker01`](assets/evidence/k8s-worker01/collect.txt)、
> [`gitlab-201`](assets/evidence/gitlab-201/collect.txt)、[`harbor-202`](assets/evidence/harbor-202/collect.txt)、
> [`experiments/linux-lab.txt`](assets/evidence/experiments/linux-lab.txt) 第 6 节、
> [`k8s-security/worker01-cgroup.txt`](assets/evidence/k8s-security/worker01-cgroup.txt)。
>
> 这一章回答：**`free` 的 buff/cache 到底算不算用掉；为什么 `Committed_AS` 大于内存也没 OOM；
> `RSS`、cgroup `memory.current`、`kubectl top` 为什么对不上；OOM 到底杀了谁。**

## 1. 当时的情况

| 主机 | 总内存 | available | swap | Committed_AS / CommitLimit | overcommit |
|---|---:|---:|---:|---:|---:|
| PVE 宿主 | 62Gi | 3.0Gi | 8Gi（用 3.7Gi） | 75.7GB / 41.2GB | 0 |
| m01 | 5.5Gi | 1.3Gi | 0 | 5.68GB / 2.90GB | 1 |
| worker01 | 9.7Gi | 5.9Gi | 0 | 10.8GB / 5.09GB | 1 |
| GitLab 201 | 7.8Gi | 2.2Gi | 0 | 11.1GB / 4.07GB | 0 |
| Harbor 202 | 5.8Gi | 5.0Gi | 0 | 3.06GB / 3.03GB | 0 |

表面看很矛盾：

- PVE 宿主 `free` 只剩 622Mi，但 `available` 3.0Gi；
- `Committed_AS` 75.7GB 大于内存，但 `oom_kill 0`；
- m01 `available` 1.3Gi，但 apiserver 还活着；
- worker01 `used` 3.4Gi，`buff/cache` 6.0Gi，`available` 5.9Gi；
- Harbor `used` 只有几百 MiB，`buff/cache` 4.5Gi。

## 2. 主要概念

### 2.1 虚拟内存不是物理内存

```text
进程虚拟地址空间（VSZ）
  ├─ 代码段（file-backed，可共享）
  ├─ 数据段/堆（anon）
  ├─ 栈（anon）
  ├─ mmap 文件（page cache）
  └─ 未分配/保留地址
       │ 页表映射
       ▼
物理内存（RSS / page cache / slab / 内核）
```

- `VSZ`：虚拟地址空间大小，可能远大于物理内存；
- `RSS`：常驻物理页（包含共享页）；
- `PSS`：按共享比例分摊后的 RSS（更接近“真实占用”）；
- `USS`：进程独占内存。

### 2.2 page cache：不是“浪费”

Linux 用空闲内存缓存文件页：

- 读文件 → page cache；
- 写文件 → dirty page → writeback；
- 内存紧张 → 回收 clean page cache；
- `free` 的 `buff/cache` 大部分可回收。

所以 `free` 的 `free` 很小不代表内存不足，**看 `available`**。

### 2.3 anon vs file

| 类型 | 来源 | 可回收 |
|---|---|---|
| anon | 堆/栈/mmap 匿名页 | 需 swap/zswap，否则 OOM |
| file | 文件 page cache | 可直接回收 |
| slab | 内核对象 | 部分可回收 |
| shmem | tmpfs/共享内存 | 需 swap |

K8s 节点通常禁用 swap，所以 anon 内存压力直接触发 OOM。

### 2.4 overcommit

`vm.overcommit_memory`：

| 值 | 含义 |
|---|---|
| 0 | 启发式（默认），允许一定超额 |
| 1 | 总是允许，直到真正分配失败 |
| 2 | 严格，不超过 `CommitLimit` |

`CommitLimit = swap + RAM × overcommit_ratio%`（粗略）。
`Committed_AS` 是“已承诺的虚拟内存”，不是实际使用。

- PVE `overcommit=0`，`Committed_AS` 可以大于 `CommitLimit`（启发式允许）；
- m01/worker `overcommit=1`，更容易超分，OOM 风险更高；
- 生产数据库/控制面建议 `0` 或 `2` + 监控。

### 2.5 OOM killer

当 anon 内存 + 内核内存无法回收时，内核选择进程杀死：

```bash
dmesg | grep -i -E 'oom|killed process'
journalctl -k | grep -i oom
cat /proc/<pid>/oom_score
cat /proc/<pid>/oom_score_adj
```

K8s 里还有 **cgroup OOM**：容器超过 `memory.max`，内核杀容器内进程，Pod 重启。
看：

```bash
cat /sys/fs/cgroup/.../memory.events
```

### 2.6 cgroup v2 内存

```text
memory.max       硬限制
memory.high      软限制（节流）
memory.current   当前使用
memory.events    low/high/max/oom/oom_kill 计数
memory.stat      anon/file/slab/...
memory.pressure  PSI
```

真实样本（worker01 一个 Pod）：

```text
memory.max     67108864      # 64MiB
memory.current 18026496      # 17MiB
memory.events  oom 0, oom_kill 0
pids.max       11788
pids.current   9
cpu.max        10000 100000  # 10% CPU
cpu.stat       nr_throttled 33, throttled_usec 2.1s
```

## 3. 真机证据

### 3.1 PVE 宿主：64GB 被 KVM 吃掉

```text
MemTotal:       65565388 kB
MemFree:          637916 kB
MemAvailable:    3135164 kB
Buffers:          381340 kB
Cached:          1785932 kB
SwapTotal:       8388604 kB
SwapFree:        4460284 kB
AnonPages:      55105400 kB
Slab:            3078080 kB
KReclaimable:    1037072 kB
CommitLimit:    41171296 kB
Committed_AS:   75685328 kB
```

`free -h`：

```text
               total        used        free      shared  buff/cache   available
Mem:            62Gi        59Gi       622Mi        26Mi       3.1Gi       3.0Gi
Swap:          8.0Gi       3.7Gi       4.3Gi
```

`vmstat 1 3`：

```text
 r  b   swpd   free   buff  cache   si   so    bi    bo
 8  0 3928320 636520 381340 2823004    0    0    10    57
15  0 3928320 636520 381340 2823004  748   40  2800  2465
13  1 3928320 636520 381340 2823004 2984    0  5984  2041
```

- 8–15 个可运行任务，1 个 blocked；
- swap 已用 3.7Gi，`si/so` 有活动；
- `pgscan_kswapd 19.5M`、`pgsteal_kswapd 17.6M`，说明内核在持续回收；
- `compact_stall 7858`，内存碎片化明显；
- `oom_kill 0`，还没触发 OOM。

### 3.2 m01：控制面内存

```text
MemTotal:        5801092 kB
MemAvailable:    1394804 kB
AnonPages:       3239100 kB
Slab:            1152296 kB
CommitLimit:     2900544 kB
Committed_AS:    5683564 kB
```

- 5.5GiB 总内存，可用 1.3GiB；
- 没有 swap；
- `kube-apiserver` 1.7GB RSS；
- `Committed_AS` 5.68GB > `CommitLimit` 2.9GB，`overcommit=1`，靠“实际分配”兜底。

### 3.3 worker01：page cache 很大

```text
MemTotal:       10179360 kB
MemAvailable:    6233776 kB
Buffers:          894400 kB
Cached:          3912408 kB
AnonPages:       3042064 kB
Slab:            1686744 kB
Committed_AS:   10811668 kB
```

`free -h`：

```text
Mem: 9.7Gi used 3.4Gi free 332Mi buff/cache 6.0Gi available 5.9Gi
```

- `free` 只剩 332Mi，但 `available` 5.9Gi；
- 6GB buff/cache 大部分可回收；
- 没有 swap，anon 3GB 是真实压力。

### 3.4 GitLab 201 / Harbor 202

```text
# GitLab
MemTotal 7.8Gi, MemAvailable 2.2Gi, Cached 437Mi, AnonPages 5.0Gi
Committed_AS 11.1GB > CommitLimit 4.07GB

# Harbor
MemTotal 5.8Gi, MemAvailable 5.0Gi, Cached 4.5Gi, AnonPages 284Mi
Committed_AS 3.06GB ≈ CommitLimit 3.03GB
```

GitLab 的 Ruby/PostgreSQL 是 anon 内存大户；Harbor 主要是 page cache，实际 anon 很小。

### 3.5 cgroup OOM 事件

```text
$ cat .../memory.events
low 0
high 0
max 0
oom 0
oom_kill 0
```

- `max 0` 表示没有触达硬限制；
- 如果 `oom_kill` 增长，说明容器被杀，Pod 会重启。

## 4. 实验：page cache 与 available

```bash
free -m
dd if=/dev/zero of=/tmp/cache-test bs=1M count=200 conv=fsync status=none
free -m
rm -f /tmp/cache-test
sync
free -m
```

真实结果（PVE 宿主）：

```text
Mem: 64028 used 60929 free 998 buff/cache 2791 available 3099
# dd 200MiB 后
Mem: 64028 used 60923 free 803 buff/cache 2991 available 3104
# 删除后
Mem: 64028 used 60929 free 997 buff/cache 2792 available 3099
```

`used` 几乎不变，`buff/cache` 增加，`available` 基本不变——这就是 page cache 的作用。

## 5. 踩坑点

### 坑 1：看 `free` 的 `free` 判断内存不足

要看 `available`。`free` 小是 page cache 占用，不是泄漏。

### 坑 2：把 `VSZ` 当内存

`VSZ` 是虚拟地址空间；Go/Java 程序可能几十 GB。看 `RSS`/cgroup `memory.current`。

### 坑 3：`Committed_AS > 内存` 就以为要 OOM

`Committed_AS` 是承诺的虚拟内存，不是实际使用。`overcommit=0/1` 允许超分；
关键是 `MemAvailable` 和 cgroup `memory.current`。

### 坑 4：K8s 节点开 swap

kubelet 默认要求 swap off；开 swap 会改变内存回收/OOM 行为。
本环境所有 K8s 节点 `SwapTotal=0`。

### 坑 5：cgroup 限制和节点内存不是一回事

容器 `memory.max=64MiB`，节点还有 5GB；容器超了会 cgroup OOM，不是节点 OOM。
排查要看 `/sys/fs/cgroup/.../memory.events`。

### 坑 6：`kubectl top` 与 `free` 对不上

`kubectl top` 是 working set（RSS + 部分 cache），不是宿主机总内存；
也不包含未纳入 cgroup 的 host 进程。

### 坑 7：slab 泄漏

`Slab` 很大且 `SUnreclaim` 持续增长，可能是内核对象泄漏（dentry/inode/网络）。
看 `slabtop`、`/proc/slabinfo`。

### 坑 8：hugepages 配置了但没用

`HugePages_Total=0` 表示没预留；数据库/DPDK 才需要。
盲目开 hugepages 会减少可用内存。

### 坑 9：OOM 没有日志

`dmesg_restrict=1` 时普通用户看不到；用 root、`journalctl -k`。
容器 OOM 看 `memory.events` 和 kubelet 事件。

## 6. 一页命令

```bash
cat /proc/meminfo
free -h
vmstat 1 3
cat /proc/pressure/memory
cat /proc/vmstat | grep -E 'pgscan|pgsteal|oom_kill|compact'
sysctl vm.overcommit_memory vm.swappiness vm.min_free_kbytes
cat /sys/fs/cgroup/memory.current /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.events
slabtop -o | head
systemd-cgtop -b -n 1 | head
dmesg | grep -i -E 'oom|killed process'
```
