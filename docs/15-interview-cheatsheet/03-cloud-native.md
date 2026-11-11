# 03 · 云原生面试题：OOMKilled、Evicted、tini 与容器 PID 1

> 证据：[`assets/evidence/oom-evicted.txt`](assets/evidence/oom-evicted.txt)、
> [`tini-pid1.txt`](assets/evidence/tini-pid1.txt)、
> [`05-linux cgroup 样本`](../05-linux/assets/evidence/cgroup/worker01-pod-cgroup.txt)、
> [14 Containers](../14-containers/README.md)。

## 1. OOMKilled vs Evicted

### 一句话

**OOMKilled**：容器内存超过 cgroup `memory.max`，内核 OOM killer 杀进程，容器退出码通常 137；
**Evicted**：节点 Memory/Disk/PIDPressure，kubelet 驱逐 Pod，Pod 状态 `Reason=Evicted`。

### 展开

| 维度 | OOMKilled | Evicted |
|---|---|---|
| 触发者 | 内核 OOM killer | kubelet eviction manager |
| 范围 | 容器/cgroup | Pod/节点 |
| 触发条件 | 超 `memory.max` | 节点资源低于 eviction 阈值 |
| 结果 | 容器重启（同一 Pod） | Pod 被驱逐/重建 |
| 退出码 | 137（SIGKILL） | 不一定有容器退出码 |
| 看哪里 | `memory.events`、`describe pod` | `describe node`、Pod `Reason`、kubelet 日志 |

### 机器证据

cgroup 样本（worker01）：

```text
memory.max     67108864      # 64MiB
memory.current 18026496      # 17MiB
memory.events  oom 0, oom_kill 0
pids.max       11788
```

当前 6 节点：

```text
MemoryPressure False
DiskPressure   False
PIDPressure    False
```

当前 Pod 历史：

```text
lastState reasons: Unknown 27, Completed 5, Error 4
# 没有 OOMKilled/Evicted 历史
```

说明机制存在，但当前环境没有触发。

### 排查

```bash
kubectl describe pod <pod> | grep -i -E 'oom|evict|reason|exit'
kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[*].lastState}'
cat /sys/fs/cgroup/.../memory.events
journalctl -k | grep -i oom
kubectl describe node <node> | grep -i -E 'pressure|evict'
```

### 追问

- OOMKilled 一定是节点内存不足？不是，容器 limit 太小也会。
- Evicted 的 Pod 会重启吗？可能被 ReplicaSet/Deployment 重建到别的节点。
- `memory.max` 和 `memory.high` 区别？硬限制 vs 软限制（节流）。
- 为什么 exit code 137？128 + SIGKILL(9)。

## 2. 容器为什么需要 tini

### 一句话

容器的 PID 1 是应用本身，不是 systemd；PID 1 默认不回收僵尸、不处理默认 SIGTERM，
所以需要 `tini`/`dumb-init` 做 init，负责转发信号和 `wait` 子进程。

### 展开

- 容器里 PID 1 有特殊信号语义：没注册 handler 的 SIGTERM 可能被忽略；
- PID 1 不自动 `wait` 孤儿进程，可能产生僵尸；
- `tini` 作为 PID 1，转发信号给子进程，并 reap 僵尸；
- Docker/K8s 可用 `--init`/`shareProcessNamespace`/`tini`。

### 机器证据

frpc 容器：

```text
$ grep -E '^(Name|Pid|PPid|NSpid)' /proc/2236/status
Name:  frpc
Pid:   2236
PPid:  1916
NSpid: 2236 1
```

- 宿主机 PID 2236；
- 容器 namespace 里 PID 1；
- `PPid 1916` 是 containerd-shim；
- 没有 tini，frpc 自己就是 PID 1。

### 追问

- tini 和 dumb-init 区别？都做 signal/reap，实现/参数不同。
- K8s 怎么加？Dockerfile `ENTRYPOINT ["/sbin/tini","--"]`，或 `shareProcessNamespace`。
- PID 1 一定能收到 SIGTERM？不一定，应用要注册 handler。
- 僵尸一定有害？少量无害，大量耗 PID/进程表。

## 3. cgroup 与容器限制（补充）

### 一句话

容器资源限制最终落到 cgroup v2：`memory.max`、`cpu.max`、`pids.max`；K8s 的 requests/limits
由 kubelet/容器运行时翻译成 cgroup 值。

### 机器证据

```text
memory.max     67108864
cpu.max        10000 100000     # 10% CPU
pids.max       11788
cpu.stat       nr_throttled 33, throttled_usec 2154222
```

### 追问

- requests 和 limits 区别？调度依据 vs 运行时上限。
- CPU 超限会怎样？throttle，不是杀。
- 内存超限会怎样？cgroup OOM，不是 throttle。
- QoS 类别？Guaranteed/Burstable/BestEffort。

## 一页命令

```bash
# OOM
kubectl describe pod <pod> | grep -i -E 'oom|exit|reason'
cat /sys/fs/cgroup/.../memory.events
journalctl -k | grep -i oom

# Evicted
kubectl describe node <node> | grep -i pressure
kubectl get pod <pod> -o yaml | grep -A3 'reason: Evicted'

# PID 1
grep -E '^(Name|Pid|PPid|NSpid)' /proc/<pid>/status
crictl inspect <id> | jq '.info.runtimeSpec.process.args'

# cgroup
cat /sys/fs/cgroup/.../memory.max
cat /sys/fs/cgroup/.../cpu.max
cat /sys/fs/cgroup/.../pids.max
```
