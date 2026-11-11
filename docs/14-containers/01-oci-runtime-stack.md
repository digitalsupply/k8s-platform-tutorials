# 01 · 运行时栈：Docker、containerd、CRI、shim 与 runc

> 证据：[`assets/evidence/docker/`](assets/evidence/docker/)、
> [`assets/evidence/k8s/ctr-namespaces.txt`](assets/evidence/k8s/ctr-namespaces.txt)、
> [`assets/evidence/pve/host-runtime.txt`](assets/evidence/pve/host-runtime.txt)。

## 1. 先分清三层

```text
用户/编排层
  ├─ docker CLI / docker compose
  ├─ kubectl / kubelet（CRI）
  └─ nerdctl / ctr（调试）
        │
        ▼
容器管理层
  ├─ dockerd（Docker 自己的 API/网络/卷）
  ├─ containerd（镜像/容器/任务/namespace）
  └─ CRI 插件（containerd 内置 CRI）
        │
        ▼
运行时层
  ├─ containerd-shim-runc-v2（每个容器一个 shim）
  └─ runc（真正 clone + namespaces + cgroups + exec）
```

- **Docker**：CLI + dockerd + containerd + runc，额外提供网络/卷/构建；
- **containerd**：CNCF 的容器管理器，K8s 通过 CRI 调它；
- **CRI**：Kubernetes 的运行时接口（`RuntimeService`/`ImageService`）；
- **shim**：containerd 和容器进程之间的“保活代理”，容器退出后 shim 负责收尸；
- **runc**：OCI runtime，负责创建 namespace/cgroup、pivot_root、exec。

## 2. OCI 两个规范

| 规范 | 内容 |
|---|---|
| OCI Image Spec | manifest、config、layer、digest、平台 |
| OCI Runtime Spec | `config.json`：process、root、mounts、linux namespaces/cgroups |

`runc` 只认 OCI runtime spec；containerd 把镜像解成 rootfs，再生成 `config.json` 交给 runc。

## 3. namespace：containerd 的“隔离域”

containerd 自己也有 namespace（不是内核 namespace）：

```bash
ctr namespaces list
```

本环境：

- K8s 节点：`k8s.io`；
- Docker 主机：`moby`、`moby_history`；
- 默认 namespace：空。

真实证据（worker01）：

```text
$ ctr images list
REF TYPE DIGEST SIZE PLATFORMS LABELS
# 空

$ ctr -n k8s.io images list
192.168.67.202:8443/compassio/backend:...  application/vnd.docker...  185.6 MiB
...

$ ctr namespaces list
NAME
k8s.io
```

Harbor：

```text
$ ctr images list
# 空
$ ctr -n moby images list
127.0.0.1:8443/compassio/buildkit:v0.20.2-rootless ...
$ ctr namespaces list
moby
moby_history
```

> `ctr` 默认 namespace 是 `default`，不是 `k8s.io`/`moby`。看不到镜像不代表没有镜像。

## 4. Docker 与 containerd 的关系

Docker 29.x 仍然用 containerd 作为底层：

```bash
docker info | grep -E 'Server Version|Storage Driver|Cgroup|Runtimes|Default Runtime'
```

Harbor 202：

```text
Server Version: 29.9.2
Storage Driver: overlayfs
Cgroup Driver: systemd
Cgroup Version: 2
Runtimes: io.containerd.runc.v2 runc
Default Runtime: runc
Security Options: cgroupns
```

所以：

- `docker ps` 看到的是 dockerd 管理的容器；
- `crictl ps` 看到的是 CRI（kubelet）管理的容器；
- `ctr -n moby` 看到 Docker 的 containerd 对象；
- `ctr -n k8s.io` 看到 K8s 的 containerd 对象；
- 它们共用同一个 containerd 二进制，但 namespace 不同。

## 5. 为什么 `runc list` 是空的

worker01：

```text
$ runc list
time="..." level=error msg="open /run/runc: no such file or directory"
```

原因：containerd 用 `containerd-shim-runc-v2` 管理容器，runc 只在创建时短暂运行，
状态不在 `/run/runc`。要看容器用：

```bash
crictl ps
ctr -n k8s.io tasks list
ps -ef | grep -E 'containerd-shim|runc'
```

真实进程树：

```text
containerd (PID 703)
└─ containerd-shim-runc-v2 (PID 1047)
   └─ pause (PID 1072)
```

每个 Pod 至少有一个 pause/sandbox 容器；业务容器由同一个或另一个 shim 管理。

## 6. PVE 上的“运行时残留”

PVE 宿主：

```text
$ systemctl is-active docker containerd
inactive
inactive

$ du -sh /var/lib/docker
3.1G

$ find /var/lib/docker/overlay2 -maxdepth 1 -type d | wc -l
75

$ ls -l /var/run/docker.sock /run/containerd/containerd.sock
No such file or directory
```

说明：

- 服务停了，但镜像层/容器层还在磁盘；
- 没有 socket，`docker`/`ctr` 连不上；
- 这些残留不会自动清理，需要 `docker system prune`（服务起来）或手工删目录（确认无引用）。

## 7. 实验

```bash
# Docker 主机
docker version
docker info | grep -E 'Server Version|Storage Driver|Cgroup|Runtimes|Default Runtime'
docker ps -a
docker images
docker system df

# K8s 节点
crictl version
crictl info | head -40
crictl ps -a
crictl pods
ctr namespaces list
ctr -n k8s.io containers list | head
ctr -n k8s.io tasks list | head

# 进程树
ps -eo pid,ppid,user,comm,args | grep -E 'containerd|shim|pause' | grep -v grep
```

## 8. 踩坑点

### 坑 1：`ctr images ls` 看不到 K8s 镜像

默认 namespace 是 `default`。用 `ctr -n k8s.io images ls`。

### 坑 2：`crictl` 和 `docker` 看到的不是同一批容器

K8s 用 CRI/containerd；Docker 用 dockerd。两套 API/namespace，不能混用。

### 坑 3：`runc list` 为空

containerd 的 shim 管理状态，runc 不是常驻。用 `crictl`/`ctr tasks`。

### 坑 4：Docker 停了，磁盘没释放

镜像/容器层还在 `/var/lib/docker`。确认无引用后再 prune/删除。

### 坑 5：`containerd` 和 Docker 的 `moby` namespace

Docker 的镜像在 `moby`，不是默认 namespace；`ctr -n moby` 才能看到。

### 坑 6：`crictl` 版本与运行时 API

`crictl version` 显示 RuntimeName/RuntimeVersion；版本不匹配时命令可能报 `Unimplemented`。

## 9. 一页命令

```bash
docker version
docker info | grep -E 'Server Version|Storage Driver|Cgroup|Runtimes'
crictl version
crictl info | head -40
ctr namespaces list
ctr -n k8s.io containers list | head
ctr -n k8s.io tasks list | head
ps -eo pid,ppid,comm,args | grep -E 'containerd|shim|pause' | grep -v grep
```
