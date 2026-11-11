# 05 · 容器存储：overlay rootfs、volume、PVC 与镜像文件系统

> 证据：[`k8s/worker01-runtime.txt`](assets/evidence/k8s/worker01-runtime.txt)、
> [`docker/gitlab-201.txt`](assets/evidence/docker/gitlab-201.txt)、
> [`docker/harbor-202.txt`](assets/evidence/docker/harbor-202.txt)、
> [`pve/host-runtime.txt`](assets/evidence/pve/host-runtime.txt)、
> [05 Linux 文件系统章](../05-linux/03-filesystem-storage.md)。

## 1. 容器的三层存储

```text
镜像层（只读，共享）
  ↓
容器可写层（overlay upperdir，容器删除即丢）
  ↓
Volume / emptyDir / PVC（独立生命周期）
```

- **镜像层**：`/var/lib/containerd/.../snapshots` 或 `/var/lib/docker/overlay2`；
- **可写层**：每个容器一份；
- **Volume**：bind mount、emptyDir、PVC、RBD、NFS；
- **imagefs**：镜像+快照的实际文件系统，和节点根盘共享空间。

## 2. 容器里的 `df` 为什么是宿主机

容器没有独立文件系统配额（除非用 quota/xfs project quota）：

```bash
docker run --rm alpine df -h /
# 显示的是宿主机根盘/overlay
```

真正限制容器写入的是：

- `ephemeral-storage` requests/limits；
- `emptyDir.sizeLimit`；
- PVC 大小；
- 节点 `DiskPressure`。

## 3. 真机证据

### 3.1 worker01：镜像 9.12GB，BuildKit 7GB

```text
$ crictl imagefsinfo
mountpoint: /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs
usedBytes: 9123471360        # 9.12GB
inodesUsed: 290374

$ du -sh /var/lib/buildkitd-cache
7.0G

$ df -hT /
/dev/mapper/ubuntu--vg-ubuntu--lv ext4 57G 28G 28G 50% /
```

57G 根盘，镜像 9.1G + BuildKit 7G + 容器可写层/日志/emptyDir，剩下 28G。

### 3.2 GitLab 201：0 容器，20.69GB 镜像

```text
$ docker system df
Images 32 0 20.69GB 14.21GB (68%)
Containers 0 0 0B
Build Cache 12 0 1.037GB

$ du -sh /var/lib/docker
~20GB+
```

没有容器运行，镜像仍然占盘；这是“删容器≠删镜像”的典型。

### 3.3 Harbor 202：10 容器，5.55GB 镜像

```text
Images 20 10 5.552GB 1.846GB (33%)
Containers 10 10 9.433MB
Local Volumes 11 9 2.994kB
Build Cache 46 0 719.9MB

$ df -hT /
/dev/sda1 ext4 58G 33G 25G 57%
overlay 58G 33G 25G 57% ...（每层重复显示）
```

Harbor 的 overlay 行不能相加；真实占用看 `/dev/sda1`。

### 3.4 PVE：Docker 停了，3.1GB 还在

```text
$ systemctl is-active docker containerd
inactive
inactive

$ du -sh /var/lib/docker
3.1G

$ find /var/lib/docker/overlay2 -maxdepth 1 -type d | wc -l
75
```

服务停了，数据目录不会自动清空。

### 3.5 PVC / RBD

worker01 上：

```text
rbd4 10G disk /var/lib/kubelet/pods/.../mount
rbd6  5G disk /var/lib/kubelet/pods/.../mount
```

- RBD 是块设备，CSI attach/mount 到 Pod；
- `df` 只看到文件系统，`ceph df` 才看到池；
- RBD 通常 RWO，不能多节点同时写。

## 4. 存储类型对比

| 类型 | 生命周期 | 共享 | 典型 |
|---|---|---|---|
| 镜像层 | 镜像删除后 | 多容器共享 | rootfs |
| 容器可写层 | 容器删除后 | 不共享 | `/tmp` 写入 |
| emptyDir | Pod 删除后 | Pod 内容器共享 | 缓存/临时 |
| hostPath | 节点 | 依赖节点 | 系统 agent |
| PVC/RBD | PV 回收策略 | RWO/RWX | 数据库/应用数据 |
| NFS | 外部 | RWX | 共享文件 |
| BuildKit cache | 手动/GC | 构建共享 | CI 缓存 |

## 5. 清理

```bash
# Docker
docker system df -v
docker container prune
docker image prune
docker builder prune
docker system prune -a

# containerd/K8s
crictl imagefsinfo
crictl rmi --prune
crictl ps -a
kubectl delete pod --field-selector=status.phase=Succeeded -A

# BuildKit
buildctl du --verbose
buildctl prune --keep-storage 5GB

# PVE 残留
du -sh /var/lib/docker
# 确认 Docker 不再使用后，才考虑删除 /var/lib/docker
```

## 6. 踩坑点

### 坑 1：容器里 `df` 是宿主机

不要用容器里的 `df` 判断容器配额；看 cgroup/`ephemeral-storage`/PVC。

### 坑 2：overlay 行重复

Harbor/containerd 的每个 overlay 挂载都显示同一块盘；`df` 输出不能相加。

### 坑 3：删容器不释放镜像

镜像层是共享的；`docker image prune`/`crictl rmi` 才回收。

### 坑 4：BuildKit 缓存不在镜像列表

`crictl images` 看不到 `/var/lib/buildkitd-cache`；节点 DiskPressure 要一起看。

### 坑 5：`emptyDir` 没有 sizeLimit

默认可以用满节点磁盘；生产要设 `sizeLimit` 或使用 PVC。

### 坑 6：PVC 的 `df` 不是池容量

PVC 里 `df` 看文件系统；`ceph df`/`rbd du` 才看池实际占用。

### 坑 7：RWO 卷多节点挂载

`Multi-Attach error` 先查旧节点是否还 map/watcher，不要直接删 Pod。

### 坑 8：镜像层和日志一起撑爆根盘

containerd 日志、Pod 日志、emptyDir、BuildKit、镜像层都在根盘；要分别统计。

## 7. 一页命令

```bash
df -hT; df -i
findmnt -t overlay -o TARGET,SOURCE,OPTIONS | head
crictl imagefsinfo
docker system df -v
du -sh /var/lib/docker /var/lib/containerd /var/lib/buildkitd-cache
crictl rmi --prune
docker image prune
buildctl du --verbose
```
