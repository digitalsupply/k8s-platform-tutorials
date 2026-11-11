# 03 · 容器生命周期：create、start、exec、kill 与 PID 1

> 证据：[`assets/evidence/k8s/inspect-cilium.json`](assets/evidence/k8s/inspect-cilium.json)、
> [`inspect-frpc.json`](assets/evidence/k8s/inspect-frpc.json)、
> [`worker01-runtime.txt`](assets/evidence/k8s/worker01-runtime.txt)、
> [`05 Linux 进程章`](../05-linux/05-processes.md)。

## 1. 容器不是“启动一个进程”这么简单

```text
create
  ├─ 拉镜像/解层
  ├─ 生成 OCI config.json
  ├─ 创建 rootfs（overlayfs）
  └─ 创建容器元数据（containerd container）
start
  ├─ containerd 创建 task
  ├─ 启动 containerd-shim-runc-v2
  ├─ runc 创建 namespace/cgroup、pivot_root、exec
  └─ 容器 PID 1 开始运行
exec
  ├─ 在已有 namespace/cgroup 里再起一个进程
  └─ 不是“进入容器”，而是“加入容器”
kill/stop
  ├─ SIGTERM → 宽限期 → SIGKILL
  └─ shim 回收，containerd 更新状态
remove
  └─ 删 task/容器/可写层（镜像层保留）
```

## 2. pause / sandbox 容器

每个 K8s Pod 至少有一个 **pause** 容器：

- 持有 Pod 的 network/IPC/UTS namespace；
- 业务容器加入这些 namespace；
- 业务容器重启，pause 不变，Pod IP 不变；
- `ps` 里看到 `/pause`，很多是 `65535`/`nobody` 用户。

真实 worker01：

```text
containerd (703)
└─ containerd-shim-runc-v2 (1047)
   └─ pause (1072)
```

`crictl inspectp <pod>` 的 `runtimeSpec.linux.namespaces` 会指向 pause 的 `/proc/<pid>/ns/*`。

## 3. 状态与退出码

| 状态 | 含义 |
|---|---|
| Created | 已创建，未启动 |
| Running | 运行中 |
| Exited | 已退出，保留可写层 |
| Dead | 异常状态 |
| Paused | 暂停（cgroup freezer） |

退出码：

- `0`：正常退出；
- `1`：应用错误；
- `137`：SIGKILL（常见 OOM/超时）；
- `143`：SIGTERM；
- `139`：SIGSEGV；
- `132`：SIGILL（CPU 指令不兼容，如 Ceph-CSI v3 镜像在 v2 CPU）。

## 4. 信号与 PID 1

容器里的 PID 1 是应用进程，不是 systemd（除非你用 systemd 容器）。
PID 1 的特殊性：

- 不响应默认 SIGTERM（如果应用没注册 handler）；
- 不自动回收孤儿进程；
- `docker stop`/`crictl stop` 先 SIGTERM，超时 SIGKILL。

所以很多镜像用 `tini`/`dumb-init` 作为 PID 1，负责转发信号/reap 子进程。

## 5. 真机证据

### 5.1 运行时进程树

```text
$ ps -eo pid,ppid,user,stat,comm,args | grep -E 'containerd|shim|pause'
703   1 root Ssl containerd /usr/local/bin/containerd
1047  1 root Sl  containerd-shim ... -namespace k8s.io -id 5e77...
1072 1047 nobody Ss pause /pause
1128  1 root Sl  containerd-shim ... -namespace k8s.io -id da26...
1174 1128 65535 Ss pause /pause
1259 1047 nobody Ssl node_exporter /bin/node_exporter ...
```

- shim 的父进程是 1（containerd 交给 init 托管），不是 containerd；
- pause 的父进程是 shim；
- 业务容器进程（node_exporter）也在 shim 下。

### 5.2 crictl 状态

```text
$ crictl pods
POD ID        CREATED       STATE   NAME                         NAMESPACE   ATTEMPT
a82b9e...     18 hours ago  Ready   argocd-server-...            argocd      0
da26cc...     36 hours ago  Ready   cilium-h28cj                 kube-system 1
20ea31...     47 hours ago  NotReady cilium-h28cj                kube-system 0
...
```

同一个 Pod 名有两代 sandbox：

- `attempt 0` 的旧 sandbox 是 `NotReady`；
- `attempt 1` 的新 sandbox 是 `Ready`；
- 旧 sandbox 可能因为 kubelet/containerd 状态不一致残留。

这就是“`kubectl get pod` 正常，但 `crictl` 里有一堆旧 sandbox”的来源。

### 5.3 inspect 的 runtimeSpec

frpc（普通 Pod）：

```text
name frpc
image 192.168.67.202:8443/openwebui/frpc:v0.61.2
namespaces: pid(自身), ipc -> /proc/2028/ns/ipc, uts -> /proc/2028/ns/uts,
            network -> /proc/2028/ns/net, cgroup
root rootfs
mounts: /proc, /dev, /sys, /etc/frp, /etc/hosts, ...
```

Cilium（hostNetwork）：

```text
name cilium-agent
namespaces: ipc -> /proc/1174/ns/ipc, uts -> /proc/1174/ns/uts,
            network -> /proc/1174/ns/net
```

Cilium 的 network namespace 指向 pause 1174，而 1174 是 hostNetwork，所以它的 netns 就是宿主。

## 6. 实验

```bash
# 只读
crictl pods
crictl ps -a
crictl inspect <container-id> | head -80
crictl inspectp <pod-id> | head -80
crictl logs <container-id> --tail 50
crictl stats <container-id>

# Docker
docker ps -a
docker inspect <container> | head -80
docker logs --tail 50 <container>
docker top <container>
docker stats --no-stream

# 进程/namespace
ps -eo pid,ppid,user,stat,comm,args | grep -E 'containerd|shim|pause'
lsns -t net -o NS,PID,COMMAND | head
readlink /proc/<pid>/ns/net
nsenter --net=/proc/<pid>/ns/net ip -br a
```

> 不要在生产节点上 `crictl rm`/`docker rm`；只读命令足够定位大多数问题。

## 7. 踩坑点

### 坑 1：`docker stop` 很慢

应用没处理 SIGTERM，等到 `--time`/`StopTimeout` 超时才 SIGKILL。检查 PID 1 和 signal handler。

### 坑 2：容器里 PID 1 不回收僵尸

用 `tini`/`dumb-init`，或让应用自己 `wait`。否则大量 `Z` 进程。

### 坑 3：`crictl ps` 看不到旧 sandbox

`crictl ps` 默认只看 Running；用 `crictl ps -a` 和 `crictl pods`。

### 坑 4：`crictl` 和 `kubectl` 状态不一致

kubelet 缓存/CRI 状态可能短暂不一致；看 `crictl inspect`、kubelet 日志、containerd 日志。

### 坑 5：退出码 137 不一定是 OOM

也可能是 `crictl stop`/`docker stop` 超时 SIGKILL、节点驱逐、liveness probe 失败。
看 `dmesg`/cgroup `memory.events`/Pod events。

### 坑 6：退出码 132 = SIGILL

CPU 指令不兼容（x86-64-v3 镜像跑在 v2 CPU）。不是应用 bug，先查 `qm config`/`cpuinfo`。

### 坑 7：exec 不是“进入容器”

`docker exec`/`crictl exec` 是在容器 namespace 里新起进程，不是 SSH。容器里没有 sshd 也能 exec。

## 8. 一页命令

```bash
crictl pods
crictl ps -a
crictl inspect <id>
crictl inspectp <pod-id>
crictl logs --tail 100 <id>
crictl stats <id>
docker ps -a
docker inspect <name>
docker logs --tail 100 <name>
ps -eo pid,ppid,user,stat,comm,args | grep -E 'containerd|shim|pause'
```
