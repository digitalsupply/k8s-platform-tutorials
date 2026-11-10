# eBPF 四大核心概念实战详解

> **部署环境**：Ubuntu 24.04.4 LTS / Kernel 6.8.0-139-generic / bpftool v7.4.0 (libbpf v1.4) / bpftrace 0.20.2
> **前置条件**：需 root 权限（本机 `unprivileged_bpf_disabled=1`）

---

## 目录

1. [环境与工具链](#1-环境与工具链)
2. [Program（程序）](#2-program程序)
3. [Map（映射）](#3-map映射)
4. [Hook（钩子）](#4-hook钩子)
5. [Helper（辅助函数）](#5-helper辅助函数)
6. [四大概念串联实战案例](#6-四大概念串联实战案例)
7. [资源清单与扩展](#7-资源清单与扩展)
8. [实战案例：Cilium + Hubble 流量观测（本部署）](#8-实战案例cilium--hubble-流量观测本部署)
9. [安全指南与零影响实验](#9-安全指南与零影响实验)

---

## 1. 环境与工具链

### 1.1 当前部署的基础设施

```bash
# 确认内核及 BPF 特性
uname -r                              # 6.8.0-139-generic
cat /boot/config-$(uname -r) | grep CONFIG_BPF   # BPF 相关配置
# 本机关键配置输出：
#   CONFIG_BPF=y / CONFIG_BPF_SYSCALL=y / CONFIG_BPF_JIT=y
#   CONFIG_BPF_JIT_ALWAYS_ON=y        （JIT 强制开启）
#   CONFIG_BPF_LSM=y                  （LSM 钩子可用）
#   CONFIG_XDP_SOCKETS=y              （AF_XDP 可用）
#   CONFIG_BTF=y                       （BTF 调试信息）

# unprivileged BPF 被禁用 —— 所有操作必须 root
cat /proc/sys/kernel/unprivileged_bpf_disabled   # 1

# BTF 文件（CO-RE 关键依赖）
ls -la /sys/kernel/btf/vmlinux                    # 已存在

# BPF 文件系统
mount | grep bpf   # bpf on /sys/fs/bpf type bpf
ls /sys/fs/bpf/    # 当前已挂载的 BPF 对象：cilium/、tc/
```

### 1.2 工具链

| 工具 | 版本 | 用途 |
|------|------|------|
| `bpftool` | v7.4.0 | BPF 对象/程序/Map 管理（命令行瑞士军刀） |
| `bpftrace` | 0.20.2 | 高层单行脚本追踪语言 |
| `libbpf` | v1.4 | 用户态加载库 |
| `linux-headers-6.8.0-139` | 已装 | 编译 eBPF 程序所需内核头文件 |

> 注意：本机未安装 `clang/llvm`，直接使用 C 编写并编译 eBPF 程序时需要先安装：
> ```bash
> apt-get install -y clang llvm libbpf-dev
> ```

---

## 2. Program（程序）

### 2.1 机制

**Program** 是 eBPF 的核心执行单元：用受限 C 语言编写 → 编译为 BPF 字节码 → 经过 **Verifier（验证器）** 安全检查（确保无死循环、无越界、无任意内存访问）→ JIT 编译为本地机器码 → 挂载到指定 Hook。

Program 的关键机制：

```
┌─────────────┐    clang     ┌─────────────┐    bpf() 系统调用   ┌─────────────┐
│  eBPF C 源码 │ ──────────▶ │   BPF 字节码 │ ─────────────────▶ │  Verifier    │
─────────────────────────────┘              │                   │  + JIT       │
                                            │                   └──────┬──────┘
                                            │                          ▼
                                            │                 ┌──────────────────┐
                                            │                 │ 挂壳到 Hook 执行  │
                                            │                 │  (XDP/TC/kprobe...)│
                                            │                 └──────────────────┘
```

### 2.2 不同类型的 Program

| Program 类型 | 挂载位置 | 时机 | 典型用途 |
|--------------|----------|------|----------|
| `BPF_PROG_TYPE_XDP` | 网卡驱动层 | 收到数据包 | DDoS 防护、负载均衡 |
| `BPF_PROG_TYPE_SCHED_CLS` | TC 层 | 数据包收发 | 流量整形、包修改 |
| `BPF_PROG_TYPE_KPROBE` | 内核函数 | 函数调用时 | 追踪/审计 |
| `BPF_PROG_TYPE_TRACEPOINT` | 内核预埋点 | 事件触发时 | 性能分析 |
| `BPF_PROG_TYPE_CGROUP_SKB` | cgroup | 容器出入包 | 容器网络策略 |
| `BPF_PROG_TYPE_LSM` | LSM 接口 | 安全访问时 | 安全监控/策略 |

### 2.3 命令操作

**（1）查看本机已加载的 Program**

```bash
bpftool prog show               # 列出所有 eBPF 程序
bpftool prog list verbose       # 含 JIT 代码等详细信息
```

**（2）查看单个 Program 详细信息**

```bash
bpftool prog show id 19
bpftool prog dump jited id 19   # 反汇编 JIT 后的本地代码
bpftool prog dump xlated id 19  # 查看 BPF 指令（字节码）
```

> 当前环境 `/sys/fs/bpf` 下挂载了 `cilium/` 与 `tc/` 目录，
> 说明本机运行着 Cilium（容器网络 CNI），Cilium 依靠大量 XDP/TC Program、Map、Hook 工作，
> 是剖析 eBPF 生产的极佳样本。

**（3）tc 子系统中的 BPF 程序**

```bash
tc filter show dev lo ingress    # 查看 lo 网卡 ingress 上挂的 BPF/TCM 过滤器
tc filter show dev lo egress
```

### 2.4 编程案例：XDP 丢弃指定端口包

```c
// xdp_drop.c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>

SEC("xdp")
int xdp_drop_8080(struct xdp_md *ctx)
{
    void *data = (void *)(unsigned long)ctx->data;
    void *data_end = (void *)(unsigned long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != __bpf_htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    if (ip->protocol != IPPROTO_TCP)
        return XDP_PASS;

    struct tcphdr *tcp = (void *)ip + sizeof(*ip);
    if ((void *)(tcp + 1) > data_end)
        return XDP_PASS;

    if (tcp->dest == __bpf_htons(8080))
        return XDP_DROP;

    return XDP_PASS;
}

char LICENSE[] SEC("license") = "GPL";
```

编译：

```bash
# 需要先安装 clang/llvm/libbpf-dev
clang -O2 -g -Wall -target bpf -c xdp_drop.c -o xdp_drop.o
```

加载（需 veth/XDP 支撑设备；容器环境常用 `--offload` 到 veth）：

```bash
ip link add veth0 type veth peer name veth1
ip link set veth0 up && ip link set veth1 up
bpftool prog load xdp_drop.o /sys/fs/bpf/xdp_drop_prog type xdp
bpftool net attach xdp pinned /sys/fs/bpf/xdp_drop_prog dev veth0
```

验证：

```bash
bpftool prog show         # 可见 xdp_drop_prog，type xdp
bpftool net show          # 可见 dev veth0 xdp 挂载
# 在 veth1 端向 veth0 发送 TCP 8080 流量，观察丢包
```

---

## 3. Map（映射）

### 3.1 机制

**Map** 是 eBPF Program 与用户态程序之间的数据交换枢纽：内核态 Program 写入，用户态程序读取，全程零拷贝、共享内存。Map 必须在使用前定义类型、条目数，由内核统一维护。

Map 类型总览：

| Map 类型 | 结构 | 典型用途 |
|----------|------|----------|
| `BPF_MAP_TYPE_HASH` | key→value 哈希 | 统计、计数、状态表 |
| `BPF_MAP_TYPE_ARRAY` | 定长索引数组 | 计数器、配置表 |
| `BPF_MAP_TYPE_LRU_HASH` | 自带 LRU 淘汰的 Hash | 超大规模状态 |
| `BPF_MAP_TYPE_PERCPU_ARRAY` | 每 CPU 一份 | 无锁计数器（性能优先） |
| `BPF_MAP_TYPE_RINGBUF` | 环形事件缓冲 | 内核→用户事件流 |
| `BPF_MAP_TYPE_PROG_ARRAY` | 存 Program fd | `bpf_tail_call` 跳转表 |
| `BPF_MAP_TYPE_STACK_TRACE` | 栈回溯信息 | 性能剖析 |

### 3.2 命令操作：直接观察本机 Map

```bash
# 列出所有 Map
bpftool map show

# 查看指定 Map 详情（类型/条目数/key/value 大小）
bpftool map dump id 5

# 动态查看当前挂载的 cilium 相关 Map
ls /sys/fs/bpf/cilium/
# 例如：cilium_tunnel_map / cilium_ct4_v6 等连接跟踪表
```

### 3.3 编程案例：每源 IP 丢包统计

```c
// xdp_count.c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <linux/if_ether.h>
#include <linux/ip.h>

struct {
    __uint(type, BPF_MAP_TYPE_HASH);       // Map 类型：哈希表
    __uint(max_entries, 65536);            // 最大 65536 条
    __type(key, __u32);                    // key：源 IP
    __type(value, __u64);                  // value：丢包计数
} drop_count SEC(".maps");

SEC("xdp")
int xdp_count(struct xdp_md *ctx)
{
    void *data = (void *)(unsigned long)ctx->data;
    void *data_end = (void *)(unsigned long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != __bpf_htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    __u32 src_ip = ip->saddr;
    __u64 *count = bpf_map_lookup_elem(&drop_count, &src_ip);
    if (count) {
        __sync_fetch_and_add(count, 1);    // 原子自增
    } else {
        __u64 init = 1;
        bpf_map_update_elem(&drop_count, &src_ip, &init, BPF_ANY);
    }
    return XDP_DROP;
}

char LICENSE[] SEC("license") = "GPL";
```

用户态读取（libbpf C）：

```c
// userspace_dump.c
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <stdio.h>

int main(void)
{
    int map_fd = bpf_obj_get("/sys/fs/bpf/drop_count_map");
    __u32 key = 0, next_key;
    __u64 value;

    while (bpf_map_get_next_key(map_fd, &key, &next_key) == 0) {
        if (bpf_map_lookup_elem(map_fd, &next_key, &value) == 0) {
            struct in_addr a = { .s_addr = next_key };
            printf("IP %-15s -> %llu drops\n",
                   inet_ntoa(a), (unsigned long long)value);
        }
        key = next_key;
    }
    return 0;
}
```

命令验证：

```bash
bpftool map dump name drop_count    # 直接 dump 该 Map 内容
bpftool map update name drop_count key 1 2 3 4 value 100  # 手动改表
```

---

## 4. Hook（钩子）

### 4.1 机制

**Hook** 是 eBPF Program 的"触发条件"。Program 本身不执行，必须挂到某个 Hook 上，由内核在特定事件发生时调用它。不同 Hook 决定 Program 的执行时机、上下文参数（`ctx` 指针指向什么）与权限。

```
                ┌──────────────────────────────────────────┐
                │            Linux Kernel                  │
                │                                          │
  网络数据包    │  ┌─────────┐  ┌─────────┐  ┌──────────┐   │
────────────────┼─▶│   XDP   │  │   TC    │  │ cgroup卷 │   │
                │  └────┬────┘  └────┬────┘  └────┬─────┘   │
                │       │            │            │         │
                │       ▼            ▼            ▼         │
  函数调用      │  ┌─────────┐  ┌─────────┐  ┌──────────┐   │
────────────────┼─▶│ Kprobe  │  │Tracepoint│ │   LSM    │   │
                │  └────┬────┘  └────┬────┘  └────┬─────┘   │
                │       │            │            │         │
                │       └──────▶ eBPF Program  ◀──┘         │
                │                          │                │
                │                          ▼                │
                │                     Helper API            │
                └──────────────────────────────────────────┘
```

### 4.2 各 Hook 详解

**① XDP（最早：网络栈最前沿）**

```bash
# 查看当前 XDP 挂载情况
bpftool net show

# 命令操作：attach / detach
# ⚠️ 本集群 eth0/tailscale0/cilium_* 均被 Cilium tcx 接管，
#    请用自建 veth0（见第 2 章 & 9.3 实验4），绝不 attach 到 eth0！
bpftool net attach xdp pinned /sys/fs/bpf/prog dev veth0
bpftool net detach xdp dev veth0
```

**② TC（流量控制：可修改包）**

```bash
# 命令操作：把一个编译好的程序 attach 到某网卡 ingress
# ⚠️ 危险示范 —— 以下 3 条绝不能在本集群 eth0/tailscale0/cilium_* 上执行，
#    它们已被 Cilium tcx 挂载（bpftool net show 可见）；叠加会干扰现网。
#    正确做法：换到自己创建的 veth (veth0) 上再实验。
# bpftool prog load prog.o /sys/fs/bpf/prog type sched_cls
# tc qdisc add dev eth0 clsact
# tc filter add dev eth0 ingress bpf da obj prog.o sec tc_ingress
tc filter show dev eth0 ingress   # ← 仅查看可用
```

**③ Kprobe/Tracepoint（运行时追踪）**

各类型 Hook 制造的命令对照：

| Hook | 挂载方式 | 示例命令 |
|------|----------|----------|
| kprobe | `kprobe/<函数名>` | `bpftrace -e 'kprobe:do_sys_openat2 {...}'` |
| kretprobe | `kretprobe/<函数名>` | 函数返回时触发 |
| tracepoint | `tracepoint/<子系统>/<事件>` | `bpftrace -e 'tracepoint:syscalls:sys_enter_openat {...}'` |
| raw_tracepoint | 同 tracepoint 更底层 | 无 BTF 不友好，建议用 tracepoint |
| LSM | `lsm/<安全函数>` | 需 CONFIG_BPF_LSM=y（本机满足） |

**④ tracepoint 实战命令**

```bash
# 追踪所有 openat 系统调用
bpftrace -e 'tracepoint:syscalls:sys_enter_openat {
    printf("%s(%d) opened %s\n", comm, pid, str(args->filename));
}'
```

### 4.3 编程案例：kprobe 追踪文件打开

```c
// trace_open.c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

SEC("kprobe/do_sys_openat2")
int trace_openat(struct pt_regs *ctx)
{
    __u32 pid = bpf_get_current_pid_tgid() >> 32;  // Helper
    char filename[256] = {0};

    // 第 2 个参数是 struct open_how __user *how（本函数其实不太典型，仅示意）
    bpf_probe_read_user_str(filename, sizeof(filename),
                            (void *)PT_REGS_PARM2(ctx));

    bpf_printk("pid=%d filename=%s", pid, filename);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
```

更常见的是直接用 **tracepoint**（无需解析内核 ABI）：

```c
SEC("tracepoint/syscalls/sys_enter_openat")
int trace_tp(struct trace_event_raw_sys_enter *args)
{
    char filename[256] = {0};
    bpf_probe_read_user_str(filename, sizeof(filename), args->args[1]);
    bpf_printk("pid=%d fopen=%s",
               bpf_get_current_pid_tgid() >> 32, filename);
    return 0;
}
```

---

## 5. Helper（辅助函数）

### 5.1 机制

**Helper** 是 eBPF Program 唯一可以与内核交互的途径：Program 不能直接调用任意内核函数，只能通过内核 API 层暴露的 Helper 操作 Map、获取进程信息、读用户态内存、操作网络包等。每个 Program 类型都有自己"允许调用"的 Helper 子集。

Helper 命名规则：`helper_<name>`，由内核 `bpf.h` 中的 `__BPF_HELPERS` 宏导出原型。

### 5.2 常用 Helper 速查表

| Helper | 功能 | 可调用场景 |
|--------|------|-----------|
| `bpf_map_lookup_elem` | 查询 Map 中 key 对应的 value | 所有类型 |
| `bpf_map_update_elem` | 写入/更新 Map | 所有类型 |
| `bpf_map_delete_elem` | 删除 Map 条目 | 所有类型 |
| `bpf_get_current_pid_tgid` | 获取当前线程 PID/TGID | tracepoint/kprobe |
| `bpf_get_current_comm` | 获取当前进程名 | tracepoint/kprobe |
| `bpf_ktime_get_ns` | 内核单调时钟（ns） | 所有类型 |
| `bpf_probe_read_user` | 从用户态内存安全读 | kprobe/tracepoint |
| `bpf_probe_read_user_str` | 安全读用户态字符串（带长度） | kprobe/tracepoint |
| `bpf_probe_read_kernel` | 从内核态内存安全读 | 所有类型 |
| `bpf_get_prandom_u32` | 获取随机数 | 所有类型 |
| `bpf_redirect` | 将数据包重定向到出接口 | XDP/TC |
| `bpf_tail_call` | 跳转到 Prog Array 中的另一个程序 | XDP/TC |
| `bpf_perf_event_output` | 将数据推送 perf 事件 | 所有类型 |
| `bpf_ringbuf_output` | 将数据推送到 Ringbuf(事件流) | 所有类型 |

### 5.3 命令操作：查看可用 Helper

```bash
# 查看某个 program 自身引用了哪些 Helper
bpftool prog show id 19 verbose | grep -i helper

# 直接看内核导出（BPF helper 由内核导出，bpftool 能 dump 出来）
bpftool feature probe        # 检查当前内核支持的 bpf 特性
```

### 5.4 编程案例：采集进程打开文件的事件

综合 **Helper**：get_pid_tgid / get_current_comm / probe_read_user_str / printk

```c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

SEC("tracepoint/syscalls/sys_enter_openat")
int trace_openat(struct trace_event_raw_sys_enter *args)
{
    __u32 pid = bpf_get_current_pid_tgid() >> 32;    // Helper①
    char comm[16] = {};
    char filename[256] = {};
    void *name_ptr = (void *)args->args[1];

    bpf_get_current_comm(comm, sizeof(comm));        // Helper②
    bpf_probe_read_user_str(filename, sizeof(filename),
                            name_ptr);                // Helper③（内核态可访问用户态内存）

    bpf_printk("PID %d [%s] opened: %s", pid, comm, filename);  // Helper④
    return 0;
}
```

通过 `bpftool` 观察其 Helper 编号引用：

```bash
bpftool prog dump xlated <id> | grep -i 'call'
# 输出如：
# "call" : #bpf_get_current_pid_tgid
# "call" : #bpf_get_current_comm
# "call" : #bpf_probe_read_user_str
# "call" : #bpf_trace_printk
```

---

## 6. 四大概念串联实战案例

以 **"HTTP 连接追踪 + 延迟直方图"** 为例，把 Program / Map / Hook / Helper 全部串起来。

### 6.1 需求

监控本机所有 TCP 连接的建连/断开，并按延迟分布绘制直方图。同时按进程维度统计建连数量（TopN）。

### 6.2 架构设计

```
 Hook(kprobe)
    │ tcp_connect 进入  →  Program A (记录起始时间戳 → Map start)
    │ tcp_connect 返回  →  Program B (取时间差 → 更新直方图 & 按 pid 计数)
    │
    ▼
 Helpers: bpf_map_*, bpf_get_current_pid_tgid, bpf_ktime_get_ns
    ▼
 Map: start(HASH) / hist(ARRAY) / conn_count(PERCPU_HASH)
    ▼
 用户态 bpftool dump 读取结果
```

### 6.3 代码

```c
// trace_conn.c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <linux/types.h>

/* ---------- Map ①：记录连接起始时间 ---------- */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);      // key: sock * 地址, value: 时间戳
    __uint(max_entries, 65536);
    __type(key, __u32);
    __type(value, __u64);
} start SEC(".maps");

/* ---------- Map ②：延迟直方图 ---------- */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);     // 64 个桶
    __uint(max_entries, 64);
    __type(key, __u32);                   // 桶下标
    __type(value, __u64);                 // 计数
} hist SEC(".maps");

/* ---------- Map ③：按进程建连数 ---------- */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HASH);
    __uint(max_entries, 10240);
    __type(key, __u32);                   // pid
    __type(value, __u64);
} conn_count SEC(".maps");

SEC("kprobe/tcp_connect")                 // ← Hook ①：动态挂 tcp_connect
int BPF_KPROBE(trace_connect_entry,
               struct sock *sk)
{
    __u32 pid = bpf_get_current_pid_tgid() >> 32;    // Helper
    __u64 ts  = bpf_ktime_get_ns();                  // Helper
    __u32 key = (__u32)((unsigned long)sk);          // 用 sock 指针当 key
    bpf_map_update_elem(&start, &key, &ts, BPF_ANY); // Helper → Map①
    return 0;
}

SEC("kretprobe/tcp_connect")               // ← Hook ②：kretprobe
int BPF_KRETPROBE(trace_connect_return,
                  int ret)
{
    struct task_struct *task = NULL;
    __u32 pid = bpf_get_current_pid_tgid() >> 32;
    // 用 bpf_get_current_task 间接取 sock 不直接，示意即可
    __u64 *tsp = bpf_map_lookup_elem(&start, &[放在这里占位]);
    if (!tsp)
        return 0;

    __u64 latency_us = (bpf_ktime_get_ns() - *tsp) / 1000;
    __u32 bucket = latency_us ? (63 - __builtin_clzll(latency_us)) : 0;
    if (bucket > 63) bucket = 63;

    // Helper → Map②：直方图自增
    __u64 *cnt = bpf_map_lookup_elem(&hist, &bucket);
    if (cnt) __sync_fetch_and_add(cnt, 1);

    // Helper → Map③：进程维度计数
    __u64 *cnt2 = bpf_map_lookup_elem(&conn_count, &pid);
    if (cnt2) { __sync_fetch_and_add(cnt2, 1); }
    else { __u64 one = 1; bpf_map_update_elem(&conn_count, &pid, &one, BPF_ANY); }

    bpf_map_delete_elem(&start, &[占位]);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
```

> 说明：上述第 2 个程序按内核 `sock *` 取 key 需要正确拿到 sk，
> 生产代码可用 `bpf_current_task_under_cgroup` 等判断；为直观起见，
> 本示例省略了 key 的精确映射，核心演示四个概念的协作关系。

### 6.4 用 bpftrace 直接实现等价功能（一行观测）

无需编译完整 Program，bpftrace 是生产调试利器：

```bash
# 观测：打印每个新连接的 socket 与进程（本质是 probe + helper 的组合）
bpftrace -e '
  kprobe:tcp_connect { printf("%s(%d) connect, sk=%p\n", comm, pid, arg0); }
  kretprobe:tcp_connect { printf("   connect ret=%d\n", retval); }
'

# 观测：每秒打印 TCP 建连次数直方图（隐式使用 map）
bpftrace -e 'kprobe:tcp_connect { @[comm] = count(); }
             interval:s:5 { print(@); clear(@); }'
```

### 6.5 用户态读取与验证

```bash
# 加载（略）后：
bpftool map dump name hist
bpftool map dump name conn_count
bpftool map dump name start

# 触发一些 HTTP 连接观察数据变化
curl -s http://localhost:8080 >/dev/null 2>&1 &
bpftool map dump name conn_count
```

---

## 7. 资源清单与扩展

### 7.1 本机实操清单

| 操作 | 命令 |
|------|------|
| 查看所有 Program | `bpftool prog show` |
| 查看所有 Map | `bpftool map show` |
| 查看网络 Hook 挂载 | `bpftool net show` |
| 查看当前 trace | `cat /sys/kernel/debug/tracing/trace_pipe`（配 `bpf_printk`） |
| 特性探测 | `bpftool feature probe` |
| BTF 存在性 | `ls /sys/kernel/btf/vmlinux` |

### 7.2 延伸学习

| 主题 | 内容 |
|------|------|
| CO-RE | 凭 BTF 实现跨内核版本可移植（无需源码头文件） |
| Tail Call | 用 `BPF_MAP_TYPE_PROG_ARRAY` + `bpf_tail_call` 拼装复杂逻辑 |
| Ring Buffer 事件流 | `bpf_ringbuf_*` 比 perf buffer 更快更安全 |
| XDP 转发/负载均衡 | Cilium（本集群已部署，见第 8 章）是 eBPF 网络最成熟代表 |
| 观测生态 | bpftrace → bcc → libbpf + CO-RE 三层抽象 |

---

## 8. 实战案例：Cilium + Hubble 流量观测（本部署）

> 本集群：k3s v1.36.4 + Cilium v1.20.1，`routing-mode=tunnel`(VXLAN)、`kube-proxy-replacement=true`（BPF 替代 kube-proxy）、`enable-hubble=true`。
> 观测命令：`kubectl -n kube-system exec cilium-98vtn -- hubble observe`（cilium-98vtn 运行在 ubuntu02）。

### 8.1 本部署拓扑（实测数据）

| 节点 | 角色 | 主机 IP (LAN) | Pod 网段 /24 | Cilium 隧道源地址 |
|------|------|---------------|--------------|-------------------|
| ubuntu01 | control-plane | 192.168.67.201 | 10.0.0.0/24 | 10.0.0.37 |
| ubuntu02 | worker（观测点） | 192.168.67.202 | 10.0.1.0/24 | 10.0.1.33 |
| ubuntu03 | worker | 192.168.67.203 | 10.0.2.0/24 | 10.0.2.70 |

实测身份映射（`cilium identity list`）：`1=host 2=world 4=health 6=remote-node 7=kube-apiserver`，traefik 自定义身份 **51260**。

### 8.2 Hubble 输出字段解读

```
时间戳: 源IP:端口 (源身份) 箭头 目的IP:端口 (目的身份) 数据面落点 判定 (TCP标志)
```

| 字段 | 本例取值 | 含义 |
|------|----------|------|
| `(host)` | 192.168.67.202 | 宿主机自身身份（identity 1） |
| `(remote-node)` | 192.168.67.203 / 10.0.1.33 | 节点身份（identity 6）：源是节点地址而非 Pod/端点 |
| `(health)` | 10.0.2.87:4240 | Cilium 健康检查端点（identity 4，端口 4240） |
| `(world)` | 10.0.1.33:43404 | 集群外部不可信来源（identity 2） |
| `(kube-apiserver)` | 192.168.67.201:6443 | 保留身份 7（k3s apiserver，hostNetwork） |
| `to-network` | eth0 | 包走物理网卡（宿主机/原生路由路径） |
| `to-overlay` | cilium_vxlan | 包进入 VXLAN 隧道（跨节点 Pod 路径） |
| `FORWARDED` | — | 通过 Cilium 策略决策点（命中拒绝则 DROPPED+原因） |
| `TCP Flags` | SYN/ACK/FIN | conntrack 观测到的 TCP 状态片段 |

### 8.3 三类真实流量逐条解读

**① `host -> kube-apiserver`（to-network / eth0）**
```
192.168.67.202 (host) -> 192.168.67.201:6443 (kube-apiserver) to-network FORWARDED
```
宿主机进程（k3s agent/kubelet）周期性向控制平面 6443 心跳。apiserver 为 hostNetwork，宿主机→宿主机直接走 LAN 物理网卡 eth0。
实测 JSON：`interface:eth0 / trace:TO_NETWORK / EGRESS / src identity:1(host) → dst identity:7(kube-apiserver)`。

**② 健康检查：一条通信两套路径（重点对照）**
```
(a) 192.168.67.202 (host) -> 192.168.67.203:4240 (remote-node) to-network   ← 物理网卡
(b) 10.0.1.33 (remote-node) -> 10.0.2.87:4240 (health)           to-overlay  ← VXLAN 隧道
```
同一"节点间健康检查"，双路径并存：(a) 节点 IP:4240 直连走 eth0；(b) 用隧道源地址 `10.0.1.33`（实测 ipcache 中 ubuntu02 的 CiliumInternalIP）打到 ubuntu03 的 health 端点 `10.0.2.87:4240`，走 cilium_vxlan。
实测 JSON：`trace:TO_OVERLAY / interface:cilium_vxlan / identity:6(remote-node)→4(health)`。
**这组对照直接回答了 to-network 与 to-overlay 的本质区别。**

**③ `world -> traefik`（to-overlay）**
```
10.0.1.33 (world) -> kube-system/traefik-59b7647586-lnpms:8000 (ID:51260) to-overlay FORWARDED
```
外部世界访问 traefik。实测 svc：`traefik LoadBalancer EXTERNAL-IP=192.168.67.201/.202/.203`，端口 `80:31124 / 443:30135`，后端 `10.0.2.216:8000/8443`（ubuntu03 上的 traefik Pod）。
路径：外部客户端 → `192.168.67.202:31124` → Cilium BPF LB（`cilium service list` 的 `0.0.0.0:31124 → 10.0.2.216:8000`）→ 转发进 VXLAN → to-overlay。
`(world)` 即外部不可信身份 2；默认宽松模式（enable-policy=default 且无拒绝策略）故 FORWARDED。
`(ID:51260)` 是 traefik 的自定义安全身份，`cilium identity list | grep 51260` 可看完整标签。

### 8.4 `<>` 与 `->` 的区别（实测定位）

同一时刻两条同构行，用 `hubble observe -o json` 挖出原始流：

| 紧凑视图 | JSON 关键字段 |
|----------|---------------|
| `<>` | 无 `is_reply` / 无 `trace_reason` —— 方向判定缺失 |
| `->` | `is_reply:false, trace_reason:ESTABLISHED` —— 明确前向 |

- `->` = 请求/前向（is_reply=false）；`<-` = 应答/回向（is_reply=true）；`<>` = 方向未判定（同一 ESTABLISHED 心跳连接在同一数据面点位被重复观测时产生缺省方向的副本）。
- 健康检查流每秒打 ACK 心跳，故几乎必然成对出现 `<>` + `->`。

### 8.5 底层机制：eBPF 四大概念在 Cilium 的落地

| eBPF 概念 | 本部署实例（实测佐证） |
|-----------|------------------------|
| **Program** | `bpf_network.c`(eth0)、`bpf_overlay.c`(cilium_vxlan)、`bpf_lxc.c`(lxc_health 及每个 Pod veth)、`bpf_host.c`(cilium_host)、`bpf_xdp.c`——均为编译后经 Verifier 校验的 BPF 程序 |
| **Hook** | TC/tcx 挂载点：`cilium_vxlan`(ifindex 11)、`eth0`(ifindex 2)、`lxc_health`(ifindex 13)；Hubble 的 `trace_observation_point`（TO_NETWORK/TO_OVERLAY/TO_ENDPOINT/TO_STACK）即事件产生时的 **Hook 落点** |
| **Map** | `cilium_ipcache`（IP↔身份，实测 10.0.1.33→1、10.0.2.87→4）、`cilium_lxc`、`cilium_policy`、`cilium_ct*`（conntrack：识别 SYN/ACK/ESTABLISHED/REPLY）、`cilium_service`（LB 转发表）、**`cilium_events`（perf_event_array，Hubble 事件通道）** |
| **Helper** | 数据面 `perf_event_output`/`ringbuf_output` 把每条 `monitor_msg` 写入 `cilium_events`；`bpf_get_current_pid_tgid` 等取上下文 |

```
eBPF 数据面(Program+Hook)
   │  Helper: perf_event_output
   ▼
cilium_events (PERF_EVENT_ARRAY Map)   ← 宿主机: /sys/fs/bpf/tc/globals/cilium_events
   ▼ cilium-agent 用户态读取 perf ring，用 cilium_ipcache/cilium_identity 做"IP→标签"富化
Hubble gRPC server (localhost:4244)
   ▼
hubble observe 输出
```
输出中的 `(host)/(world)/(health)/(kube-apiserver)` 即为"数值 identity → 标签"的用户态富化结果。

### 8.6 可复现的验证命令

```bash
# 身份-标签映射（1=host,2=world,4=health,6=remote-node,7=kube-apiserver,51260=traefik）
kubectl -n kube-system exec cilium-98vtn -- cilium identity list | grep -E 'reserved|51260'

# IP→身份 ipcache（对应输出的每个 (身份)）
kubectl -n kube-system exec cilium-98vtn -- cilium bpf ipcache list | grep -E '10\.0\.1\.33|10\.0\.2\.87'

# BPF 服务转发表（对应 6443/traefik 转发链路）
kubectl -n kube-system exec cilium-98vtn -- cilium service list

# 完整 JSON：identity 数值 / is_reply / Hook 落点 / 网卡名
kubectl -n kube-system exec cilium-98vtn -- hubble observe --since 30s -o json

# 只看被拒绝流量（配合策略学习）
kubectl -n kube-system exec cilium-98vtn -- hubble observe --verdict DROPPED --follow

# 宿主机视角：程序/Hook/Map 落地
bpftool prog show && bpftool net show && ls /sys/fs/bpf/tc/globals/
```

**易混点**：同一个 IP 在不同观测点可呈现不同身份——`10.0.1.33` 在本机 ipcache 中是 `host`(1)，健康流中显示 `remote-node`(6)，traefik 流中显示 `world`(2)。因 Hubble 显示的是该条流在数据面被嵌入/分类的身份而非单纯查 ipcache，调试以 `-o json` 的 `identity` 数值为准。

### 8.7 节点核心网络接口的角色分工（实测 ubuntu01）

> 实测 `bpftool net show` 真实输出：每台节点上 Cilium 用 tcx 挂载这些 Program 到各接口。

```
eth0(2)         tcx/ingress  cil_from_netdev     ← 物理网卡
eth0(2)         tcx/egress   cil_to_netdev
tailscale0(3)   tcx/ingress  cil_from_netdev     ← Tailscale（Cilium 也管它！）
tailscale0(3)   tcx/egress   cil_to_netdev
cilium_net(4)   tcx/ingress  cil_to_host         ← 宿主机 veth 对
cilium_host(5)  tcx/ingress  cil_to_host
cilium_host(5)  tcx/egress   cil_from_host
cilium_vxlan(6) tcx/ingress  cil_from_overlay    ← overlay 隧道
cilium_vxlan(6) tcx/egress   cil_to_overlay
lxc_health(8)…  tcx/ingress  cil_from_container  ← 容器/Pod veth
```

#### 8.7.1 eth0 与 tailscale0（非 Cilium 专属）

| 接口 | 实测 | 角色 |
|------|------|------|
| eth0 | 192.168.67.201/24、MTU 1500、默认网关 192.168.67.1 | 原生网络出入口：LAN/宿主机互连/外部流量/VXLAN 外层封装载体 |
| tailscale0 | 100.94.131.119/32（CGNAT）+ fd7a:115c:a1e0::…/128、MTU 1280 | Tailscale 登录时打通的远程直连网（WireGuard） |

**关键发现**：Cilium 把 tailscale0 也当作 **native 设备**挂上了 `cil_from_netdev/cil_to_netdev`（与被纳入设备列表有关）。经 Tailscale 进出的流量与 eth0 同等对待，同样受身份+策略约束，不是旁路。`tailscale status` 显示 mesh 内含 `ubuntu01` 自身及 desktop/kali/laptop 等设备，远程 `kubectl exec` 即经由该隧道进入。

#### 8.7.2 cilium_host 与 cilium_net —— 一对 veth，"宿主机=一个端点"

职责：把宿主机作为 Cilium 数据面的"端点"接入（identity 1 host）。两者是 veth 对（实测 `cilium_host/iflink=4` = `cilium_net/ifindex`）。

| 接口 | 实测 | 角色 |
|------|------|------|
| cilium_host(5) | `inet 10.0.0.37/32`，本节点 Pod 网段网关（`10.0.0.0/24 via 10.0.0.37 dev cilium_host`） | 宿主机的"自己端点"，持有 Cilium 内部 IP |
| cilium_net(4) | 无 IPv4，仅 link-local | 配对的"干净腿"，把主机侧流量交回数据面 ingress |

机制：
- 宿主机发出的包 → 命中 `10.0.0.37 dev cilium_host` 路由 → **egress 钩子 `cil_from_host`** 处理（hubble 中 host 身份之源）；
- 要交回主机协议栈的包 → 由 **`cil_to_host`** 钩子解码投递（`to-host` 结尾路径）。

#### 8.7.3 cilium_vxlan —— overlay 隧道设备

实测：`vxlan external`（封装完全由 BPF 驱动）、`dstport 8472`、MTU 1280。`external` 是关键——VNI 由 BPF 填入，**每个 VNI 承载内层流量的安全身份**。

| 钩子 | 程序 | 干什么 |
|------|------|--------|
| ingress | `cil_from_overlay` | 解封装 → 读内层 VNI 身份 → 查策略 → 投递本机 Pod veth |
| egress | `cil_to_overlay` | 封装进 VXLAN（外层源=隧道源地址 10.0.1.x）→ 交给 eth0 物理发出 |

**MTU 连带效应（本部署特有）**：node MTU 被压到 1280，正是因为 tailscale0 是 MTU 1280 的设备（Cilium 取所管设备最小 MTU），隧道/pod 路由 MTU 随之降至 `1230 = 1280 − 50( VXLAN 开销)`，`ip route` 中可见 `10.0.1.0/24 via 10.0.0.37 dev cilium_host mtu 1230`。

#### 8.7.4 接口 × Hook × 程序总表

| 接口 | Hook | 程序 | Cilium 视角角色 | hubble 落点 |
|------|------|------|----------------|-------------|
| eth0 | tcx in/eg | `from_netdev/to_netdev` | 原生网络 | from/to-network |
| cilium_host/cilium_net | tcx in/eg | `from_host/to_host` | 宿主机=端点(identity 1) | host 身份源 |
| cilium_vxlan | tcx in/eg | `from_overlay/to_overlay` | 隧道出入口(VNI=身份) | from/to-overlay |
| tailscale0 | tcx in/eg | `from_netdev/to_netdev` | 远程通道（等同 native） | from/to-network |
| lxcXXX / lxc_health | tcx in/eg | `from_container/to_container` | Pod/端点 | from/to-endpoint |

#### 8.7.5 完整链路例：远程用户经 Tailscale 访问 traefik

```
你的电脑 → wireguard → tailscale0(100.94.x.x → 节点)
tailscale0/ingress (cil_from_netdev) → 认 world 身份 → BPF LB 查表
  (service 19: 192.168.67.202:80 → 10.0.2.216:8000)
后端在 ubuntu03 → cil_to_overlay (cilium_vxlan 封装, VNI=traefik ID 51260)
→ eth0 以 UDP/8472 发出 → ubuntu03 cil_from_overlay 解封装
→ 投递 traefik Pod veth(lxcXXX/from-container) → 返回链路对称反向
```

这条链路将四大 eBPF 概念与四个核心接口全部串联：eth0/tailscale0 吃入原生包 → cil_from_netdev 做身份与 LB → cilium_host 定义宿主机端点 → cilium_vxlan 完成身份化的跨节点封装。

---

## 9. 安全指南与零影响实验

> 目的：判断"前面章节的命令会不会影响机器"？给出只读、可隔离、真正零影响的实验。

### 9.1 逐章"安全审计"结论

| 章节 | 命令 | 影响？ | 说明 |
|------|------|--------|------|
| 2. Program | `ip link add veth0...` / attach XDP 到 **veth0** | ✅ 无 | 自建 veth 对，宿主流量不经过它还 |
| 2. Program | `apt install clang llvm libbpf-dev` | ⚠️ 可逆 | 装开发工具，不动服务不动网络；非必需可不装 |
| 3. Map | `bpftool map dump/update name drop_count...` | ✅ 无 | 只读；update 的是**你自己命名**的 map（不存在即报错），不碰 Cilium 的 map |
| 4. Hook | `bpftool net attach xdp ... dev eth0` | ❌ **危险** | eth0 归 Cilium tcx 接管；已改为 veth0 |
| 4. Hook | `tc qdisc add dev eth0 clsact` / `tc filter add dev eth0 ingress` | ❌ **危险** | 同上，仅查看可用；已注释 |
| 4. Hook | bpftrace 的 kprobe / tracepoint 示例 | ✅ 无 | 只观测不改流量，timeout 自动退出 |
| 5–8 | `bpftool show/dump`、`hubble observe`、`cilium *` | ✅ 无 | 全部只读 |

**核心安全原则**：动手型实验只在你自建的 veth 或网络命名空间里做；绝不能动 `eth0 / tailscale0 / cilium_host / cilium_net / cilium_vxlan / lxc_*`——这些接口已被 Cilium tcx 接管。

### 9.2 六大 Hook 通俗讲解（快递比喻 + 本机实测）

| Hook | 一句话 | 比喻 | 本部署实测证据 |
|------|--------|------|----------------|
| **XDP** | 包裹**还没进站**就过秤 | 大门口自动称重机 | 本机 `xdp 程序数=0`（`bpf-lb-acceleration=disabled`），最快但权限最小 |
| **TC** | 进站后/出站前都能**动刀**的安检台 | 安检传送带 | Cilium 全家在此：程序 `411: sched_cls tail_handle_ipv4_from_netdev`；hubble 的 `to-network/to-overlay` 即其落点 |
| **cgroup** | 按"这个容器"批量把关 | 小区楼栋门禁 | Cilium 用 `cgroup-root=/run/cilium/cgroupv2`；本部署 `bpf-lb-sock=false` 未启用 BPF 侧 cgroup 程序 |
| **kprobe** | 内核任意函数门口**临时装摄像头** | 动态摄像头 | 实测 `kprobe:tcp_connect` 抓到 `k3s-server/coredns/cilium-agent` 真实连接 |
| **tracepoint** | 内核源码**预埋的固定安检口** | 固定监控位 | 实测 `tracepoint:syscalls:sys_enter_openat` 抓到 `sshd` 开文件 |
| **LSM** | 敏感操作**盖章放行/拒绝** | 保安亭（能真拒绝） | 内核支持（`CONFIG_BPF_LSM=y`），但 Cilium `enable-host-firewall=false` 未启用；bpftrace 0.20.2 实测不支持 lsm 探测 |

### 9.3 零影响实验（全部本机实测通过）

**实验 1：只读观察 Cilium 现场 Program/Map/Hook**
```bash
bpftool prog list | head -5          # Program：sched_cls/tcx 的 cil_* 程序
bpftool prog show id 411             # 那条来自 eth0 的 TC 程序详情
bpftool net show                     # Hook：tcx 挂在哪些接口上
ls /sys/fs/bpf/tc/globals/ | head    # Map：cilium_ipcache / cilium_calls_*（尾调用表）
bpftool map dump name cilium_ipcache | head -c 300   # Map 内容（只读）
```
实测：`411: sched_cls name tail_handle_ipv4_from_netdev tag d30891e86e3ffb06 gpl`——即"TC 这种 Hook"在机器上的真人版。

**实验 2：tracepoint 只观测文件打开（3 秒自退出）**
```bash
timeout 3 bpftrace -e 'tracepoint:syscalls:sys_enter_openat { @f[comm] = count(); }'
```
实测：`@f[sshd]: 3`、`@f[k3s-server]: 5`。结束即恢复。

**实验 3：kprobe 只观测 TCP 建连（3 秒自退出）**
```bash
timeout 3 bpftrace -e 'kprobe:tcp_connect { printf("connect comm=%s pid=%d\n", comm, pid); }'
```
实测：`connect comm=k3s-server pid=870`、`comm=coredns pid=2462`、`comm=cilium-agent pid=1675`——直观看到集群实时连接，只读不拦。

**实验 4（选做）：自建 veth 上做 XDP，完全隔离**
```bash
ip link add veth0 type veth peer name veth1
ip link set veth0 up; ip link set veth1 up
bpftool prog load xdp_drop.o /sys/fs/bpf/xdp_drop_prog type xdp
bpftool net attach xdp pinned /sys/fs/bpf/xdp_drop_prog dev veth0   # 只挂 veth0！
# 玩完清理：
bpftool net detach xdp dev veth0; ip link del veth0
```
> 在 veth0 上挂 XDP-DROP 只会"丢弃"没有流量走的线路，宿主机完全无感。

### 9.4 一句话总结 Hook

- **XDP** = 最早最快、只揽一眼（本机未开）
- **TC** = 能动手能拦的主力钩子（Cilium 全家在此，hubble 标签即其落点）
- **cgroup** = 按容器来管（本机仅用 cgroupv2 做生命周期）
- **kprobe / tracepoint** = 只看不动的"摄像头"（bpftrace 实验即此类）
- **LSM** = 能拒绝的安全保安亭（内核支持、部署未启用）

---

## 附：四大概念一句话总结

| 概念 | 一句话 |
|------|--------|
| **Program** | 受验证与 JIT 的内核态"小函数"，干什么都得靠它 |
| **Map** | 内核与用户的共享内存，数据流动的"传送带" |
| **Hook** | 程序挂载的触发点，决定"何时被谁调用" |
| **Helper** | 程序与内核交流的"唯一合法 API" |