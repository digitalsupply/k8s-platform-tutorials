# 容器证据索引（2026-11-11）

这些输出来自实际机器，只读采集。命令、镜像、容器、cgroup、netns 都是当天状态。

## 1. 运行时分布

| 主机 | 运行时 | 状态 | 证据 |
|---|---|---|---|
| teacher（PVE） | Docker（已停）/ containerd（已停） | `inactive`，`/var/lib/docker` 3.1G、75 个 overlay 目录残留 | `pve/host-runtime.txt` |
| m01 / master01/02 / worker01/02/03 | containerd `2.3.2` + CRI | active，K8s 使用 | `k8s/worker01-runtime.txt`、`k8s/ctr-namespaces.txt` |
| worker01/02/03 | BuildKit rootless（CI） | Pod 内运行，`/var/lib/buildkitd-cache` 7.0G | `k8s/worker01-runtime.txt` |
| ubuntu01（GitLab 201） | Docker `29.9.2`（containerd `moby` namespace） | active，0 容器、33 个 tag / 32 个唯一镜像 20.69GB | `docker/gitlab-201.txt`、`docker/gitlab-images.txt` |
| ubuntu02（Harbor 202） | Docker `29.9.2`（containerd `moby` namespace） | active，10 容器、20 镜像 5.5GB | `docker/harbor-202.txt`、`docker/harbor-inspect.txt` |

## 2. 证据文件

```text
assets/evidence/
├── pve/host-runtime.txt                 # Docker/containerd 停止、3.1G 残留、无 socket
├── docker/gitlab-201.txt                # docker info/ps/images/df/overlay
├── docker/gitlab-images.txt             # 33 个 tag（32 个唯一镜像），最大 4.5GB
├── docker/harbor-202.txt                # Harbor 10 个容器、20 镜像、5.5GB
├── docker/harbor-inspect.txt            # harbor-core CapDrop ALL、CapAdd SETGID/SETUID
├── docker/ctr-namespaces.txt            # moby namespace 才有镜像
├── k8s/worker01-runtime.txt             # 41 pods / 56 containers / 41 images / 9.1G imagefs
├── k8s/ctr-namespaces.txt               # k8s.io namespace 才有镜像
├── k8s/cluster-runtime.txt              # 138 Pod
├── k8s/inspect-cilium.json              # Cilium privileged + hostNetwork
├── k8s/inspect-frpc.json                # 普通 Pod 默认 capabilities
├── k8s/inspect-node-exporter.json       # hostNetwork + hostPID
└── network/worker01-netns.txt           # hostNetwork vs 普通 Pod 的 netns
```

## 3. 关键数字

- worker01：`crictl pods` 41、`crictl ps -a` 56、`crictl images` 41，imagefs **9.12GB**；
- worker01：BuildKit 缓存 **7.0GB**，进程为 `rootlesskit → buildkitd`；
- GitLab 201：Docker **0 容器 / 33 tag（32 镜像）/ 20.69GB**，可回收 **14.21GB**；
- Harbor 202：Docker **10 容器 / 20 镜像 / 5.552GB**，Build Cache 719.9MB；
- PVE：Docker/containerd 都 inactive，`/var/lib/docker` **3.1GB**、75 个 overlay 目录；
- 集群：**138 Pod**；worker01 上 38 个 Pod；
- 05 章的 Pod 安全统计：138 Pod 中 **35 hostNetwork、10 privileged、19 add capabilities**。

## 4. 未采集

- 镜像内文件内容、Secret、环境变量；
- 容器业务数据；
- Docker 镜像仓库的认证信息。

> 这些输出用于教程举证，不包含可直接利用的凭据。
