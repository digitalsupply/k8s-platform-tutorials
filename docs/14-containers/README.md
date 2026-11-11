# 14 · 容器运行时与容器化：Docker、containerd、OCI、CRI、镜像、网络、存储与安全

> 这一章单独成类，因为容器横跨 **PVE 宿主机、GitLab/Harbor 的 Docker、K8s 的 containerd/CRI、
> CI 的 BuildKit**，既不属于纯 Linux，也不只属于 Kubernetes。
>
> 证据：[`assets/evidence/`](assets/evidence/README.md)，全部来自实际机器。

## 当时的情况

同一套平台同时跑着三种“容器形态”：

| 位置 | 运行时 | 实际状态 |
|---|---|---|
| PVE 宿主 `teacher` | Docker + containerd | **都停了**，但 `/var/lib/docker` 还有 **3.1GB / 75 个 overlay 目录** |
| GitLab `192.168.67.201` | Docker `29.9.2` | 0 个容器，**33 个 tag / 32 个唯一镜像 / 20.69GB**，可回收 14.21GB |
| Harbor `192.168.67.202` | Docker `29.9.2` | **10 个 Harbor 容器 / 20 个镜像 / 5.55GB** |
| K8s 6 节点 | containerd `2.3.2` + CRI | 138 个 Pod，worker01 上 41 Pod / 56 容器 / 41 镜像 / **9.12GB imagefs** |
| CI worker | BuildKit rootless | `/var/lib/buildkitd-cache` **7.0GB** |

真实问题：

- `ctr images ls` 是空的，因为镜像在 `k8s.io`/`moby` namespace；
- `runc list` 报 `/run/runc` 不存在，但容器明明在跑；
- PVE 上 Docker 已经停了，磁盘却没释放；
- GitLab 没有容器，镜像却占了 20GB；
- Harbor 容器 `CapDrop: ALL`，但 `CapAdd: SETGID/SETUID`；
- Cilium/CSI 是 privileged，业务 Pod 也偷偷加 `SYS_ADMIN`；
- hostNetwork Pod 的 `nsenter` 看到的是宿主网卡；
- 容器里 `df` 显示 57G，实际不是容器配额；
- BuildKit 缓存 7GB，节点磁盘吃紧。

## 怎么读

| 章节 | 主题 | 解决的问题 |
|---|---|---|
| [01 运行时栈](01-oci-runtime-stack.md) | OCI、Docker、containerd、CRI、shim、runc | 容器到底由谁创建、`ctr` 为什么看不到镜像 |
| [02 镜像与层](02-images-layers-overlayfs.md) | manifest、layer、digest、overlayfs、GC | 镜像为什么占 20GB、删容器为什么不释放 |
| [03 生命周期](03-container-lifecycle.md) | create/start/exec/kill、pause、PID 1、信号 | `crictl`/`docker` 状态为什么不一致 |
| [04 网络](04-container-network.md) | netns、veth、CNI、Cilium、hostNetwork | Pod IP 怎么来、为什么 `nsenter` 看到宿主网卡 |
| [05 存储](05-container-storage.md) | overlay rootfs、volume、PVC、RBD、imagefs | 容器里 `df` 为什么是宿主机、缓存去哪了 |
| [06 安全](06-container-security.md) | capability、seccomp、LSM、privileged、PSS | 哪些 Pod 该 privileged，哪些不该 |
| [07 排障](07-container-debugging.md) | docker/crictl/ctr/nsenter/kubectl debug | 容器起不来、拉不到镜像、OOM、SIGILL |
| [08 案例](08-cases.md) | 12 个真实容器案例 | 把前面知识串成排障链 |
| [labs/](labs/README.md) | 只读 + 可选实验 | 动手验证 |

推荐顺序：**01 → 02 → 03 → 04 → 05 → 06 → 07 → 08**。

## 一张图

```text
docker CLI / kubectl / crictl
        │
        ▼
dockerd / kubelet（CRI）
        │
        ▼
containerd（namespace: moby / k8s.io）
        │  create task
        ▼
containerd-shim-runc-v2
        │  exec
        ▼
runc → clone/namespaces/cgroups → 容器进程
        │
        ├─ overlayfs rootfs（镜像层 + 可写层）
        ├─ netns/veth/CNI（Cilium）
        └─ cgroup（CPU/内存/PIDs）
```

容器不是“轻量 VM”：

- 没有自己的内核，系统调用直接进宿主内核；
- 隔离靠 namespace + cgroup + capability + LSM + seccomp；
- 镜像只是**只读层**，容器写的是 overlay 可写层；
- 容器的“根文件系统”是宿主机上的目录/挂载，不是磁盘镜像。

## 关键数字（真实）

```text
PVE Docker 残留       3.1GB / 75 overlay dirs
GitLab 201            33 tags / 32 images / 20.69GB / 0 containers / 14.21GB reclaimable
Harbor 202            10 containers / 20 images / 5.55GB
worker01              41 pods / 56 containers / 41 images / 9.12GB imagefs
worker01 BuildKit     7.0GB cache
K8s cluster           138 pods
Pod security          35 hostNetwork / 10 privileged / 19 add capabilities
```

## 与其它章节的关系

- 内核/namespace/cgroup/capability 原理：[05 Linux](../05-linux/README.md)；
- K8s 节点/Cilium/Service：[01 Kubernetes](../01-kubernetes-k3s/README.md)、[02 Cilium](../02-cilium-ebpf/README.md)；
- Harbor/CI/BuildKit：[10 CI/CD](../10-cicd-delivery/README.md)；
- Ceph RBD/PVC：[06 Storage](../06-storage-ceph/README.md)；
- PVE 宿主/VM：[12 Proxmox](../12-proxmox-pve/README.md)。

## 配套脚本

| 脚本 | 说明 |
|---|---|
| [scripts/collect_container_evidence.sh](scripts/collect_container_evidence.sh) | 只读采集 Docker/containerd/CRI/cgroup/netns/存储证据 |

```bash
bash docs/14-containers/scripts/collect_container_evidence.sh > /tmp/container-evidence.txt
ssh root@10.0.0.122 'bash -s' < docs/14-containers/scripts/collect_container_evidence.sh > /tmp/worker01-container.txt
```

> 本章的 `crictl`/`docker` 命令都是只读；需要创建容器时请在实验机执行，不要在生产 Harbor/GitLab 上跑。
>
> 面试一句话答案（OOMKilled/Evicted、tini 等）见
> [15 面试速查](../15-interview-cheatsheet/README.md)。
