# 02 · 镜像与层：manifest、digest、overlayfs 与镜像回收

> 证据：[`assets/evidence/docker/gitlab-images.txt`](assets/evidence/docker/gitlab-images.txt)、
> [`gitlab-201`](assets/evidence/docker/gitlab-201.txt)、[`harbor-202`](assets/evidence/docker/harbor-202.txt)、
> [`k8s/worker01-runtime.txt`](assets/evidence/k8s/worker01-runtime.txt)、
> [`k8s/inspect-*.json`](assets/evidence/k8s/)。

## 1. 镜像不是“一个文件”

```text
Image
├─ manifest（平台、config digest、layer digest 列表）
├─ config（Env/Cmd/Entrypoint/WorkingDir/User/Labels）
└─ layers（tar.gz，按 digest 内容寻址）
      ↓ 解压
   snapshotter/overlayfs 的只读层
```

- **digest**：`sha256:...`，内容不可变；
- **tag**：`latest`、`v3.18.2`，只是指向 digest 的指针，**可以变**；
- **layer**：多个镜像共享同一层（内容寻址），所以“删除一个 tag”不一定释放空间。

## 2. overlayfs 的四层

```text
lowerdir  = 镜像只读层（可以多层）
upperdir  = 容器可写层
workdir   = overlay 内部工作目录
merged    = 容器看到的 /
```

```bash
findmnt -t overlay -o TARGET,SOURCE,OPTIONS
mount | grep overlay | head
```

容器里写文件：

- 新文件 → upperdir；
- 修改 lower 文件 → copy-up 到 upperdir；
- 删除 lower 文件 → whiteout；
- 删除容器 → upperdir 删除，lower 镜像层还在。

## 3. 镜像存储与统计

| 工具 | 看什么 |
|---|---|
| `docker images` | 镜像 tag/大小（去重前） |
| `docker system df` | 镜像/容器/卷/构建缓存 |
| `crictl images` | CRI 镜像列表 |
| `crictl imagefsinfo` | 镜像文件系统实际使用 |
| `ctr -n k8s.io images ls` | containerd 镜像对象 |
| `du -sh /var/lib/docker` | Docker 数据目录实际占用 |
| `du -sh /var/lib/containerd` | containerd 数据目录 |
| `du -sh /var/lib/buildkitd-cache` | BuildKit 缓存 |

## 4. 真机证据

### 4.1 GitLab 201：0 容器，33 个 tag、32 个唯一镜像、20.69GB

```text
$ docker system df
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          32        0         20.69GB   14.21GB (68%)
Containers      0         0         0B        0B
Local Volumes   0         0         0B        0B
Build Cache     12        0         1.037GB   0B
```

最大镜像：

```text
4.5GB  registry.cn-hangzhou.aliyuncs.com/go404/deeptutor:latest
4.5GB  registry.cn-hangzhou.aliyuncs.com/go404/deeptutor:870f2dbe...
4.5GB  192.168.67.202:8443/deeptutor/deeptutor:870f2dbe...
2.94GB manim-test:latest
2.23GB manim-lean2:latest
1.88GB manim-lean:latest
998MB  trivy-java-db:1
...
```

问题：

- 同一镜像 **3 个 tag**（两个 registry + 一个 Harbor），占三份“显示大小”；
- 很多镜像 `ACTIVE=0`，可回收 14.21GB；
- 0 个容器，说明这些是历史构建/测试镜像。

### 4.2 Harbor 202：10 容器，20 镜像，5.55GB

```text
Images 20 10 5.552GB 1.846GB (33%)
Containers 10 10 9.433MB
Build Cache 46 0 719.9MB
```

Harbor 的 10 个容器都是 `goharbor/*:v2.14.5`，镜像层共享较多，实际 5.55GB。

### 4.3 worker01：41 镜像，9.12GB imagefs

```text
$ crictl pods -q | wc -l         41
$ crictl ps -a -q | wc -l        56
$ crictl images -q | wc -l       41
$ crictl imagefsinfo
mountpoint: /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs
usedBytes: 9123471360            # 9.12GB
inodesUsed: 290374
```

最大镜像：

```text
289MB n8n:2.14.2
287MB grafana:12.4.3
256MB cilium:v1.20.4
233MB strimzi/operator:1.0.0
222MB alloy:v1.20.0
218MB cephcsi:v3.18.2
215MB argocd:v3.5.3
...
```

### 4.4 BuildKit 缓存

```text
$ ps -eo pid,ppid,user,comm,args | grep buildkit
2322 ... rootlesskit buildkitd --oci-worker-no-process-sandbox ...
2341 ... /proc/self/exe buildkitd ...
2359 ... buildkitd ...

$ du -sh /var/lib/buildkitd-cache
7.0G
```

BuildKit 的缓存不属于 `crictl images`，但占节点根盘；`DiskPressure` 时要一起看。

### 4.5 镜像层历史

Harbor core：

```text
$ docker history --no-trunc goharbor/harbor-core:v2.14.5
COPY make/photon/prepare/versions /harbor/            12.3kB
RUN chown -R harbor:harbor ...                        77.6MB
COPY icons                                            229kB
COPY migrations                                       225kB
COPY views                                            20.5kB
COPY harbor_core                                      76.3MB
...
```

每一行是一个 layer；修改一层只会新增一层，不会改旧层。

## 5. 镜像回收

### 5.1 Docker

```bash
# 只读看
docker system df -v
docker images --filter dangling=true

# 清理停止的容器/未使用镜像/构建缓存（会删东西，先确认）
docker container prune
docker image prune
docker builder prune
docker system prune -a
```

### 5.2 containerd / K8s

```bash
crictl images
crictl rmi --prune
crictl imagefsinfo

# 删除指定镜像
crictl rmi <image-id>

# 查看 kubelet GC 阈值
ps -ef | grep kubelet
```

kubelet 默认 `imageGCHighThresholdPercent=85`，不到阈值不 GC；本集群曾因此堆到 20GB+。

### 5.3 BuildKit

```bash
buildctl du --verbose
buildctl prune --keep-storage 5GB
```

或删 `/var/lib/buildkitd-cache`（先停 BuildKit）。

## 6. 踩坑点

### 坑 1：`latest` 不是版本

`deeptutor:latest` 和 `deeptutor:870f...` 显示都是 4.5GB，但可能是同一 digest 的不同 tag，
也可能已经漂移。生产必须用 digest 或不可变 tag。

### 坑 2：删容器不释放镜像

容器删除只删 upperdir；镜像层还在。要 `docker image prune`/`crictl rmi`。

### 坑 3：`docker system df` 与 `df` 对不上

`docker system df` 统计镜像/层/缓存，`df` 看文件系统；overlay 还会重复计算。
两者结合看，不要单看一个。

### 坑 4：镜像层共享，删除一个 tag 不一定省空间

多个 tag 指向同一 digest；只有所有引用都删除，层才会被 GC。

### 坑 5：BuildKit 缓存不在镜像列表里

`crictl images` 看不到 BuildKit 缓存；`du -sh /var/lib/buildkitd-cache` 才是实际。

### 坑 6：`crictl imagefsinfo` 的 usedBytes 是镜像文件系统

不是节点根盘全部；节点还有日志、容器可写层、emptyDir、BuildKit。

### 坑 7：镜像拉取失败先看 certs.d

Harbor 自签 CA 要放在 `/etc/containerd/certs.d/<registry>/hosts.toml`，不是只改 Docker。
K8s 节点用 containerd，Docker 的 `/etc/docker/certs.d` 不生效。

### 坑 8：pause 镜像也要能拉

`sandbox_image` 指向 `registry.aliyuncs.com/google_containers/pause:3.10`；节点不能直连
registry.k8s.io 时，必须配 mirror/pause 镜像。

## 7. 一页命令

```bash
docker images
docker history --no-trunc <image> | head
docker system df -v
crictl images
crictl imagefsinfo
crictl rmi --prune
ctr -n k8s.io images ls | head
du -sh /var/lib/docker /var/lib/containerd /var/lib/buildkitd-cache
findmnt -t overlay -o TARGET,SOURCE,OPTIONS | head
```
