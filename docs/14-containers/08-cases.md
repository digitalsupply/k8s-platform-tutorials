# 08 · 容器案例：12 个真实问题

> 所有案例来自本环境，证据在 [`assets/evidence/`](assets/evidence/README.md)。
> 每个案例按“现象 → 证据 → 原理 → 修复/建议”写。

## 案例 1：`ctr images ls` 是空的，但节点明明有镜像

### 现象

```text
$ ctr images list
REF TYPE DIGEST SIZE PLATFORMS LABELS
# 空
```

### 证据

```text
$ ctr namespaces list
k8s.io

$ ctr -n k8s.io images list
192.168.67.202:8443/compassio/backend:... 185.6 MiB
...
```

Harbor：

```text
$ ctr namespaces list
moby
moby_history

$ ctr -n moby images list
127.0.0.1:8443/compassio/buildkit:... 98.7 MiB
```

### 原理

containerd 有自己的 namespace；`ctr` 默认是 `default`，K8s 用 `k8s.io`，Docker 用 `moby`。

### 修复

```bash
ctr -n k8s.io images list
ctr -n moby images list
```

或者用 `crictl images`/`docker images`，不要用默认 namespace 的 `ctr` 判断“没镜像”。

## 案例 2：PVE 上 Docker 停了，3.1GB 还没释放

### 现象

```text
$ systemctl is-active docker containerd
inactive
inactive

$ du -sh /var/lib/docker
3.1G

$ find /var/lib/docker/overlay2 -maxdepth 1 -type d | wc -l
75
```

### 原理

Docker/containerd 停止不会删除镜像层/容器层；`/var/lib/docker` 是纯数据目录。

### 修复/建议

- 确认 Docker 不再使用；
- 临时启动 Docker 后 `docker system prune -a`；
- 或确认无引用后删 `/var/lib/docker`；
- 不要把 PVE 根盘当容器镜像仓库。

## 案例 3：GitLab 0 个容器，33 个 tag、32 个唯一镜像、20.69GB

### 现象

```text
Images 32 0 20.69GB 14.21GB (68%)
Containers 0 0 0B
```

最大镜像：

```text
4.5GB deeptutor:latest
4.5GB deeptutor:870f2dbe...
4.5GB 192.168.67.202:8443/deeptutor/deeptutor:870f2dbe...
2.94GB manim-test
2.23GB manim-lean2
1.88GB manim-lean
```

### 原理

- 同一镜像多个 tag，显示三份；
- 构建/测试镜像没有清理；
- `docker system df` 的 `RECLAIMABLE` 是估算。

### 修复

```bash
docker image prune
docker builder prune
docker system df -v
```

并给 Harbor 配 tag 保留策略，CI 不再无限推 `latest`。

## 案例 4：Harbor 容器 `CapDrop: ALL`，但仍能改 UID/GID

### 证据

```text
Privileged: False
CapAdd: ['CAP_SETGID', 'CAP_SETUID']
CapDrop: ['ALL']
NetworkMode: harbor_harbor
```

### 原理

Harbor 需要 `SETUID/SETGID` 切换用户，但不需要 `SYS_ADMIN`。
`drop ALL` + 按需 add 是最小权限的正确姿势。

### 建议

业务 Pod 也按这个模型：先 `drop: ["ALL"]`，再只加必需的 capability。

## 案例 5：worker01 41 Pod / 56 容器 / 41 镜像，imagefs 9.12GB

### 现象

```text
crictl pods -q | wc -l       41
crictl ps -a -q | wc -l      56
crictl images -q | wc -l     41
imagefs usedBytes            9123471360
```

### 原理

- Pod/容器/镜像不是一一对应；
- 一个 Pod 有 pause + 业务容器；
- imagefs 包含镜像层 + 快照；
- BuildKit 缓存另算 7GB。

### 建议

节点容量规划要分别算：

```text
镜像 9.1G + BuildKit 7G + 可写层 + 日志 + emptyDir + 系统盘
```

## 案例 6：hostNetwork Pod 的 netns 是宿主

### 现象

```bash
nsenter --net=/proc/1174/ns/net ip -br a
# 看到 eth0 10.0.0.122 / eth1 172.16.1.122 / cilium_host
```

### 证据

cilium-h28cj 是 `hostNetwork: true`；frpc 是普通 Pod：

```text
frpc:
lo
eth0@if9 10.244.3.145/32
default via 10.244.3.57
```

### 原理

hostNetwork Pod 不创建独立 netns，直接共享宿主网络。

### 建议

- 看到宿主网卡先查 `hostNetwork`；
- hostNetwork Pod 的 NetworkPolicy 行为不同；
- 业务 Pod 尽量不要 hostNetwork。

## 案例 7：138 个 Pod 中 10 个 privileged、35 个 hostNetwork

### 证据

```text
summary: pods=138 hostNetwork=35 privileged=10 capAdd=19
```

典型：

- Cilium：privileged + hostNetwork + `SYS_ADMIN/SYS_MODULE/SYS_PTRACE`；
- Ceph-CSI nodeplugin：privileged + `SYS_ADMIN`；
- BuildKit：privileged；
- node-exporter：hostNetwork + hostPID；
- 业务 deeptutor：普通容器 + `CHOWN/DAC_OVERRIDE/...`。

### 原理

平台组件需要特权；业务组件不需要。风险在于“业务也照抄 privileged”。

### 建议

- 平台 namespace 与业务 namespace 分开；
- 业务默认 `drop ALL` + `allowPrivilegeEscalation: false`；
- 定期审计 `hostNetwork/privileged/capAdd`。

## 案例 8：容器 OOM 不是节点 OOM

### 证据

```text
memory.max     67108864      # 64MiB
memory.current 18026496      # 17MiB
memory.events  oom 0, oom_kill 0
```

### 原理

cgroup v2 的 `memory.max` 是容器硬限制；超过杀容器内进程，节点可能完全正常。

### 排查

```bash
cat /sys/fs/cgroup/.../memory.events
kubectl describe pod <pod> | grep -i oom
crictl inspect <id> | jq '.status'
```

### 修复

- 提高 `resources.limits.memory`；
- 查应用泄漏；
- 不要用节点 `free` 判断容器 OOM。

## 案例 9：Ceph-CSI 容器 `SIGILL`

### 现象

Ceph-CSI 3.18.2 标准镜像在旧 CPU 节点启动即退出，exit code 132（SIGILL）。

### 原理

镜像编译为 `x86-64-v3`（AVX2/BMI2 等），节点 CPU 是 `x86-64-v2-AES`。
不是 glibc 缺失，也不是 Kubernetes 问题。

### 修复

- 临时用兼容构建（`-rocky9`）；
- 根治：PVE VM CPU 改为 `x86-64-v3`，stop/start；
- 验证 `grep avx2 /proc/cpuinfo`。

## 案例 10：BuildKit rootless + 7GB 缓存 + CA 问题

### 证据

```text
2322 rootlesskit buildkitd --oci-worker-no-process-sandbox ...
2359 buildkitd ...

du -sh /var/lib/buildkitd-cache
7.0G
```

### 原理

- BuildKit 用 rootlesskit 启动，容器内 PID/namespace 与普通容器不同；
- 缓存不在 `crictl images`，但占根盘；
- `buildctl` 客户端要信任 Harbor 自签 CA（`SSL_CERT_FILE`），daemon 侧也要 CA；
- 仓库写 BuildKit、集群跑 Kaniko 的漂移会让构建结果不可复现。

### 建议

- 固定 BuildKit 版本/镜像；
- 配 `buildctl du/prune`；
- CA 两侧都配；
- 仓库 Task 与集群实际镜像一致性检查。

## 案例 11：Harbor 的 `df` 显示 58G，但 anon 只有 284Mi

### 证据

```text
/dev/sda1 ext4 58G 33G 25G 57%
overlay 58G 33G 25G 57% ...（多个）
AnonPages 284Mi, Cached 4.5Gi
```

### 原理

- 每个 overlay 挂载显示同一块盘；
- 镜像层是 page cache/文件，不是 anon 内存；
- `df` 行不能相加。

### 建议

容量看 `/dev/sda1`，镜像看 `docker system df`，内存看 `AnonPages`/`MemAvailable`。

## 案例 12：`kubectl get pod` 正常，`crictl` 有旧 sandbox

### 证据

```text
crictl pods:
da26cc... Ready    cilium-h28cj attempt 1
20ea31... NotReady cilium-h28cj attempt 0
```

### 原理

Pod 重建时 kubelet 创建新 sandbox（attempt 1），旧 sandbox 可能因 CRI/containerd 状态不一致
残留；`kubectl` 只看当前 Pod，`crictl` 能看到历史。

### 修复

- 确认旧 sandbox 没有容器/任务；
- `crictl rmp <old-pod-id>`（谨慎）；
- 或重启 kubelet/containerd 让状态对齐；
- 根治：避免“只重启 kubelet 不重启 containerd”。

## 一张排障表

| 现象 | 先看 |
|---|---|
| 镜像拉不到 | `crictl pull`、`/etc/containerd/certs.d`、imagePullSecret |
| 容器起不来 | `crictl inspect`、`crictl logs`、exit code |
| 容器 Running 但没进程 | `crictl ps -a`、shim、kubelet 日志 |
| 网络不通 | `nsenter` netns、`ip r`、`cilium status` |
| 磁盘满 | `crictl imagefsinfo`、BuildKit cache、`df -i` |
| OOM | cgroup `memory.events`、`kubectl describe` |
| 权限拒绝 | securityContext、capability、readOnlyRootFilesystem |
| 状态不一致 | `ctr -n k8s.io tasks list`、containerd/kubelet 日志 |
