# 09 · 跨层案例：把 PVE、Ceph、K8s、GitLab/Harbor 串起来

> 这一章用 8 个真实案例，把前面 8 章的概念串起来。
> 每个案例都按“现象 → 证据 → 原理 → 修复 → 预防”展开。
>
> 证据目录：[`assets/evidence/`](assets/evidence/README.md)。

## 案例 1：PVE 宿主 64GB 内存“只剩 622Mi”，为什么没 OOM

### 现象

```text
$ free -h
               total        used        free      shared  buff/cache   available
Mem:            62Gi        59Gi       622Mi        26Mi       3.1Gi       3.0Gi
Swap:          8.0Gi       3.7Gi       4.3Gi
```

9 个 KVM 进程 RSS 5–10GB，`Committed_AS` 75.7GB > `CommitLimit` 41.2GB，但 `oom_kill 0`。

### 证据

```text
AnonPages:      55105400 kB
Slab:            3078080 kB
KReclaimable:    1037072 kB
Committed_AS:   75685328 kB
CommitLimit:    41171296 kB

pgscan_kswapd 19563933
pgsteal_kswapd 17680694
compact_stall 7858
oom_kill 0
```

### 原理

- KVM 的 RSS 是 guest 物理内存的宿主映射，不是“泄漏”；
- `Committed_AS` 是虚拟内存承诺，`overcommit=0` 允许超过 `CommitLimit`；
- 真正决定是否 OOM 的是 anon 内存能否回收 + `MemAvailable`；
- swap 已用 3.7GB，kswapd 在回收，但还没到 OOM；
- `compact_stall` 高说明内存碎片化，THP/大页分配可能变慢。

### 修复/建议

1. 不要用 `free` 的 `free` 判断，盯 `MemAvailable` 和 `pgsteal_direct`；
2. 给 PVE 宿主留 10–15% 内存余量，或限制 VM 总内存；
3. 监控 `oom_kill`、`pgscan_direct`、`compact_stall`；
4. 关键 VM 用 `balloon`/`MemoryMax`，不要无限超分；
5. 生产数据库 VM 不建议和 6 个 K8s 节点共享同一宿主内存。

## 案例 2：m01 控制面 5.5GB，apiserver 1.7GB，没有 swap

### 现象

```text
MemTotal: 5801092 kB
MemAvailable: 1394804 kB
SwapTotal: 0
Committed_AS: 5683564 kB
CommitLimit: 2900544 kB
overcommit_memory = 1
```

`kube-apiserver` RSS 1.7GB，`etcd` 190MB，`cilium-agent` 176MB。

### 原理

- 控制面没有 swap，anon 内存压力直接 OOM；
- `overcommit=1` 允许分配超过物理内存，风险在“真正写入”时爆发；
- apiserver 内存与 **watch 数、对象数、CRD 数量、审计日志** 相关，不是固定值；
- `kubectl top` 的 working set 通常低于 RSS。

### 修复/建议

1. 控制面单独节点/预留资源，不和业务 Pod 混部；
2. 限制 apiserver 的 watch/请求，开启 `--max-requests-inflight`；
3. 监控 `process_resident_memory_bytes`、`go_memstats_heap_inuse_bytes`、watch 数；
4. 给 kubelet 配 `systemReserved`/`kubeReserved`（本集群已配）；
5. 不要把 `overcommit_memory=1` 当成“万能开关”。

## 案例 3：worker01 根盘 28G/57G，为什么还 DiskPressure

### 现象

```text
/dev/mapper/ubuntu--vg-ubuntu--lv ext4 57G 28G 28G 50% /
```

但 kubelet 曾报 `DiskPressure`，CSI nodeplugin 被驱逐。

### 证据

- `containerd` 目录大、镜像层多；
- `df -h` 只看文件系统，`du` 看目录；
- `crictl images` 有很多旧 tag；
- 删除文件后 `df` 不降，可能有 deleted open file。

### 原理

- kubelet 的 `imageGCHighThresholdPercent` 默认 85%，不到阈值不 GC；
- `DiskPressure` 还看 inode、可分配空间、`evictionHard`；
- 容器镜像层在 `/var/lib/containerd`，删除容器不等于删除镜像；
- `du` 与 `df` 差异来自稀疏文件、deleted open file、overlay。

### 修复

```bash
crictl rmi --prune
kubectl delete pod --field-selector=status.phase=Succeeded -A
du -xhd1 /var/lib/containerd | sort -h | tail
lsof +L1 2>/dev/null | head
systemctl restart kubelet   # 让 DiskPressure 重新计算
```

### 预防

- Harbor tag 保留策略；
- kubelet GC 阈值/`imageMinimumGCAge`；
- 节点磁盘水位告警；
- 不要把 CI 缓存和镜像长期堆在根盘。

## 案例 4：Ceph RBD 在 worker 上是 `rbd4/rbd6`，`df` 却看不到池

### 现象

```text
rbd4 10G disk /var/lib/kubelet/pods/.../mount
rbd6  5G disk /var/lib/kubelet/pods/.../mount

k8s-rbd 44 32 21 GiB 64 GiB 49.71%
```

### 原理

- RBD 是网络块设备，`rbd map` 后是 `/dev/rbdX`；
- Kubernetes 通过 CSI 把 RBD attach/mount 到 Pod；
- `df` 看文件系统，`ceph df` 看池；
- RBD 是 thin provisioning，PVC 声明 ≠ 实际占用；
- RWO 卷不能多节点同时写，`Multi-Attach` 时查旧节点 map/watcher。

### 修复/建议

- PV 回收：先确认 `Released` + claimRef UID + `watchers=none`，再删 PV/RBD；
- 池容量告警：`ceph df detail`、`k8s-rbd %USED`；
- 迁移/重启节点前先 drain，确认 RBD unmap；
- 数据库 PVC 用 `Retain`，不要用 `Delete`。

## 案例 5：GitLab 201 的 8GB 内存与 36% IO PSI

### 现象

```text
MemTotal 7.8Gi, MemAvailable 2.2Gi, AnonPages 5.0Gi
Committed_AS 11.1GB > CommitLimit 4.07GB
PSI io some avg10=36.67 full avg10=35.95
```

Ruby 进程 RSS 1.2GB × 4，PostgreSQL 多个 backend。

### 原理

- GitLab 是“Ruby on Rails + Puma + Sidekiq + Gitaly + PostgreSQL + Redis”一体机；
- Anon 内存大，没有 swap；
- IO PSI 高说明磁盘是瓶颈，不是 CPU；
- `apt-daily-upgrade` 可能在后台跑，进一步抢 IO。

### 修复/建议

1. GitLab 主机单独磁盘/SSD，避免和 K8s 共享 thin pool；
2. 限制 Puma/Sidekiq 并发；
3. 关闭/错峰 `apt-daily`；
4. 监控 `node_pressure_io_waiting_seconds_total`；
5. 备份/升级放在低峰。

## 案例 6：Harbor 202 的 `df` 看起来 58G，实际 anon 只有 284Mi

### 现象

```text
MemTotal 5.8Gi, MemAvailable 5.0Gi, Cached 4.5Gi, AnonPages 284Mi
/dev/sda1 ext4 58G 33G 25G 57%
overlay 58G 33G 25G 57% ...（多个）
```

### 原理

- Harbor 主要是 Docker/containerd 镜像层，page cache 大；
- `overlay` 挂载与根盘同一块设备，`df` 重复显示；
- `AnonPages` 小，说明没有真实内存压力；
- 镜像层占磁盘，不占 anon 内存。

### 修复/建议

- 容量看 `df -hT /`，不要累加 overlay；
- 镜像 GC/保留策略；
- 不要把 page cache 当内存泄漏；
- Harbor 与 GitLab 分盘，避免 CI 构建把盘写满。

## 案例 7：CSI 与构建器是 privileged；Cilium 靠 capability，不是 privileged

### 现象

```text
summary: pods=138 hostNetwork=35 privileged=10 capAdd=19
```

Cilium agent 是 `drop: ALL` + 13 个 capability（`NET_ADMIN,NET_RAW,SYS_ADMIN,SYS_MODULE,SYS_RESOURCE,CHOWN,KILL,DAC_OVERRIDE,FOWNER,SETGID,SETUID,IPC_LOCK,SYSLOG`，实测），不是 privileged；
Ceph-CSI nodeplugin 加 `SYS_ADMIN`；`deeptutor` 加 `CHOWN,DAC_OVERRIDE,FOWNER,SETGID,SETUID`。

### 原理

- CNI 只需要改网络命名空间/BPF，给 capability 就够；privileged 是 CSI（挂载宿主设备）与构建器（mount/chroot）这类组件的“必要之恶”；
- 业务 Pod 加 `SYS_ADMIN` 基本等于放弃隔离；
- `hostNetwork` 让 Pod 共享节点网络命名空间；
- `allowPrivilegeEscalation`/seccomp/readOnlyRootFilesystem 是最后防线。

### 修复/建议

1. 平台组件单独 namespace + 准入策略；
2. 业务 Pod 默认 `drop: ["ALL"]`、`allowPrivilegeEscalation: false`、`seccompProfile: RuntimeDefault`；
3. 定期审计 `privileged`/`hostNetwork`/`capabilities.add`；
4. 不要给业务 Pod `SYS_ADMIN`，除非有明确需求 + 评审；
5. 用 `pod-security.kubernetes.io/enforce` 限制 namespace。

## 案例 8：PVE 启动 3 分 55 秒，worker 启动 23 秒

### 现象

```text
PVE: 3min 4.240s firmware + 8.5s loader + 12.866s kernel + 29.424s userspace
worker01: 4.085s kernel + 18.978s userspace，其中 networkd-wait-online 13.648s
```

### 原理

- PVE 的时间花在 **firmware**（硬件初始化），不是 Linux；
- worker 的时间花在 `systemd-networkd-wait-online`（等网络 online）；
- `apt-daily`/`dnf-makecache` 是启动后异步任务，不一定阻塞 target；
- `systemd-analyze blame` 的时间要结合 `critical-chain` 看是否在关键路径。

### 修复/建议

1. PVE：检查 BIOS/阵列卡/网卡启动项、固件版本；不要改 systemd；
2. worker：确认是否真的需要 `network-online`，调整 `RequiredForOnline`；
3. 关闭/错峰 `apt-daily`/`dnf-makecache`；
4. 用 `systemd-analyze critical-chain` 找关键路径，不要只看 blame 第一名。

## 跨层排障顺序

```text
1. 物理/虚拟化：PVE 电源、firmware、KVM、thin pool、网络
2. 内核：dmesg、OOM、磁盘 I/O、rp_filter、conntrack
3. 资源：free/available、cgroup、ulimit、PSI
4. 文件系统：df/du/inode、LVM、overlay、RBD
5. 进程：ps、/proc、zombie、D 状态、线程
6. systemd：unit 状态、journal、启动链
7. 权限：UGO/ACL/setuid/capability/seccomp/LSM
8. K8s：Node/Pod/Event/cgroup/Cilium
9. 应用：日志、配置、依赖
```

> 90% 的“K8s 问题”最终能落到 PVE 存储、内核参数、内存压力或权限之一。
> 先分层，再谈根因。
