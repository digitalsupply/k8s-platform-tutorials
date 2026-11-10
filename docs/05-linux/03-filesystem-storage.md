# 03 · 文件系统与存储：VFS、inode、LVM、overlayfs 与 RBD

> 本章证据：[`assets/evidence/pve-host/collect.txt`](assets/evidence/pve-host/collect.txt) 第 3 节、
> [`k8s-m01/collect.txt`](assets/evidence/k8s-m01/collect.txt) 第 3 节、
> [`k8s-worker01/collect.txt`](assets/evidence/k8s-worker01/collect.txt) 第 3 节、
> [`gitlab-201`](assets/evidence/gitlab-201/collect.txt) / [`harbor-202`](assets/evidence/harbor-202/collect.txt)。
>
> 这一章回答：**为什么 `df` 和 `du` 对不上、为什么删了文件空间不回来、为什么容器里看到 47G
> 但宿主机 thin pool 只剩 19G、为什么 `lsblk` 里多出 `rbd4`/`rbd6`。**

## 1. 当时的情况

这套环境的存储层次比“一块盘 + 一个 ext4”复杂得多：

| 主机 | 根文件系统 | 特殊存储 |
|---|---|---|
| PVE 宿主 | `ext4` on `pve-root` 96G | LVM-thin `data` 794G、Docker overlay2 |
| m01 | `xfs` on `rl-root` 47G | containerd overlayfs、etcd 数据 |
| worker01/02/03 | `ext4` on `ubuntu--vg-ubuntu--lv` 57G | containerd overlayfs、Ceph RBD `rbd4/rbd6` |
| GitLab 201 | `ext4` on `/dev/sda1` 77G | Docker/containerd overlayfs |
| Harbor 202 | `ext4` on `/dev/sda1` 58G | Docker overlayfs |

真实问题：

- PVE `df -h /` 只显示 96G，看不到 794G thin pool；
- `du -sh /` 看不到 VM 磁盘；
- worker01 根盘 57G 用了 28G，但 `containerd` 目录很大；
- Ceph RBD 以 `rbd4`/`rbd6` 块设备出现在 `lsblk`，不是普通文件；
- Harbor 的 `overlay` 挂载与根盘同大小，`df` 会重复计算；
- 删除日志后 `df` 不降，可能是被进程占用的 deleted 文件，或 thin pool 没 trim。

## 2. 主要概念

### 2.1 VFS：所有文件系统的统一接口

```text
用户态 open/read/write
  ▼
VFS（虚拟文件系统）
  ├─ dentry（目录项缓存）
  ├─ inode（文件元数据：权限、大小、块、时间）
  ├─ page cache（文件页缓存）
  └─ superblock（文件系统实例）
  ▼
具体文件系统：ext4 / xfs / overlayfs / nfs / rbd
  ▼
块层：页缓存 → bio → 调度器 → 设备驱动 → 磁盘/网络
```

`stat` 看 inode，`df` 看 superblock，`du` 遍历目录项。

### 2.2 inode、硬链接、符号链接

- **inode** 存元数据，不存文件名；
- 目录项把“名字”映射到 inode；
- **硬链接**：多个名字指向同一个 inode，`links` 增加；
- **符号链接**：单独 inode，内容是目标路径；
- 删除文件 = 删目录项 + inode 链接数减 1；链接数为 0 且无进程打开才真正释放块。

### 2.3 稀疏文件与“表观大小”

```bash
truncate -s 1G sparse
ls -lh sparse     # 1.0G
du -h sparse      # 0
stat -c 'size=%s blocks=%b' sparse
```

`ls` 看 `size`，`du` 看实际分配的块。数据库、镜像、日志预分配经常出现“大小 1G、实际 0”。

### 2.4 ext4 vs xfs

| 特性 | ext4 | xfs |
|---|---|---|
| 在线缩容 | 不支持 | 不支持 |
| 在线扩容 | 支持 | 支持 |
| inode 数量 | 格式化时固定（可动态增长有限） | 动态分配 |
| 典型场景 | 系统盘、通用 | 大文件、高并发、RHEL 默认 |

本环境：

- PVE 根、worker、GitLab/Harbor 用 ext4；
- m01 用 xfs。

### 2.5 LVM 与 thin pool

```text
PV /dev/nvme0n1p3
└─ VG pve
   ├─ LV root 96G → ext4 → /
   ├─ LV swap 8G
   ├─ LV data 794G → thin pool
   │  ├─ data_tdata 794G
   │  ├─ data_tmeta 8.1G
   │  ├─ pmspare 8.1G
   │  └─ thin LV vm-119-disk-0 ...
   └─ VG free 16G
```

- thin LV 的“虚拟大小”不等于实际占用；
- `lvs` 的 `Data%` 才是 pool 实际使用率；
- `df` 看不到 pool；
- `discard`/`fstrim` 才能把 guest 删除的块还给 pool。

### 2.6 overlayfs：容器镜像分层

```text
lowerdir（只读镜像层）
  + upperdir（容器可写层）
  + workdir
  = merged（容器看到的 /）
```

`mount`/`findmnt` 里能看到：

```text
overlay on /run/containerd/.../rootfs type overlay
```

容器里的 `df` 通常显示宿主机根盘大小，不是容器配额；容器配额由 cgroup/文件系统 quota 决定。

### 2.7 Ceph RBD：网络块设备

worker 上：

```text
rbd4  10G disk  /var/lib/kubelet/pods/.../mount
rbd6   5G disk  /var/lib/kubelet/pods/.../mount
```

RBD 是 Ceph 的块设备，通过 `rbd map` 映射为 `/dev/rbdX`，再由 CSI 挂载。
它不是 NFS，不是本地盘；`df` 看到的是文件系统，底层是网络存储。

## 3. 真机证据

### 3.1 PVE 宿主

```text
$ lsblk
nvme0n1 931.5G disk
├─nvme0n1p1 1007K part
├─nvme0n1p2 1G part vfat /boot/efi
└─nvme0n1p3 930.5G part LVM2_member
  ├─pve-swap 8G lvm swap [SWAP]
  ├─pve-root 96G lvm ext4 /
  ├─pve-data_tmeta 8.1G lvm
  │ └─pve-data-tpool 794.3G lvm
  │   ├─pve-data 794.3G lvm
  │   ├─pve-vm--119--disk--0 50G lvm
  │   └─...
  └─pve-data_tdata 794.3G lvm
```

`df -hT /` 只显示 `pve-root` 96G；thin pool 的 794G 不在里面。

### 3.2 m01（xfs）

```text
$ lsblk
sda 50G disk
├─sda1 1G part xfs /boot
└─sda2 49G part LVM2_member
  ├─rl-root 47G lvm xfs /
  └─rl-swap 2G lvm swap

$ df -hT /
/dev/mapper/rl-root xfs 47G 29G 19G 62% /
```

### 3.3 worker01（ext4 + RBD + overlay）

```text
$ lsblk
sda 60G disk
├─sda1 1M part
├─sda2 2G part ext4 /boot
└─sda3 58G part LVM2_member
  └─ubuntu--vg-ubuntu--lv 58G lvm ext4 /

rbd4 10G disk /var/lib/kubelet/pods/.../mount
rbd6  5G disk /var/lib/kubelet/pods/.../mount

$ df -hT /
/dev/mapper/ubuntu--vg-ubuntu--lv ext4 57G 28G 28G 50% /
```

### 3.4 GitLab 201 / Harbor 202

```text
# GitLab
/dev/sda1 ext4 77G 50G 27G 66% /
/boot 881M 117M 703M 15%

# Harbor
/dev/sda1 ext4 58G 33G 25G 57% /
overlay 58G 33G 25G 57% /var/lib/docker/rootfs/overlayfs/...
```

Harbor 的 `df` 会为每个 overlay 挂载重复显示同一块盘，**不要把这些行相加**。

### 3.5 Ceph 池

从 m01 的 Ceph 客户端看：

```text
$ ceph df detail
POOL        ID  PGS  STORED  USED  %USED
k8s-rbd     44   32  21 GiB  64 GiB  49.71
my-zone.rgw.buckets.data 42 32 4.9 GiB 15 GiB 18.43
```

`k8s-rbd` 是 K8s PVC 的池；`STORED` 是逻辑数据，`USED` 含副本/EC 开销。
**RBD 也是 thin provisioning，PVC 声明 10Gi 不代表实际占 10Gi。**

## 4. 实验：inode、稀疏文件、页缓存

```bash
TMP=$(mktemp -d); chmod 755 "$TMP"

# 硬链接/符号链接
echo data > "$TMP/file"
ln "$TMP/file" "$TMP/hard"
ln -s "$TMP/file" "$TMP/sym"
ls -li "$TMP/file" "$TMP/hard" "$TMP/sym"

# 稀疏文件
truncate -s 1G "$TMP/sparse"
ls -lh "$TMP/sparse"
du -h "$TMP/sparse"
stat -c 'size=%s blocks=%b' "$TMP/sparse"

# inode 使用
df -i /

rm -rf "$TMP"
```

真实结果（见 `assets/evidence/experiments/linux-lab.txt`）：

```text
1070350 -rw-r--r-- 2 root root 5 ... file
1070350 -rw-r--r-- 2 root root 5 ... hard
1070351 lrwxrwxrwx 1 root root 26 ... sym -> file

-rw-r--r-- 1 root root 1.0G ... sparse
0       /tmp/.../sparse
size=1073741824 blocks=0
```

## 5. 踩坑点

### 坑 1：`df` 看不到 thin pool

`df -h /` 只反映 `pve-root`。看 pool：

```bash
lvs -o lv_name,lv_size,data_percent,metadata_percent pve/data
pvesm status
python3 docs/12-proxmox-pve/scripts/pve_storage_report.py
```

### 坑 2：`du` 和 `df` 对不上

- 被进程打开但已删除的文件：`lsof +L1` / `ls -l /proc/<pid>/fd`；
- 稀疏文件：`du` 按块，`ls` 按 size；
- overlay/挂载重复计算：`df -x overlay`；
- NFS/RBD 延迟或配额。

### 坑 3：inode 用完但空间还有

`df -h` 有空间，`df -i` 100%。大量小文件（session、缓存、邮件队列）会耗尽 inode。
ext4 的 inode 数量格式化时基本固定；xfs 动态分配。

### 坑 4：删了文件空间不回来

- 进程仍打开文件：重启/清空进程；
- thin pool 没 trim：`fstrim -av`；
- 快照/克隆仍引用旧块：删快照；
- Ceph RBD 有快照/克隆：`rbd snap ls`。

### 坑 5：容器里 `df` 是宿主机的

容器默认没有文件系统 quota，`df` 显示宿主机根盘。要看容器实际写入：

```bash
du -sh /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/
crictl ps -a
```

K8s 可以用 `emptyDir.sizeLimit`、PVC 配额、`ephemeral-storage` limits。

### 坑 6：RBD 不是 NFS

RBD 是块设备，通常 RWO；不能多节点同时读写同一个 ext4。
多副本共享文件要用 CephFS/NFS。`Multi-Attach error` 时先查旧节点是否还 map。

### 坑 7：overlay 的 `df` 重复计算

Harbor 的每个 overlay 都显示 58G，这是同一块盘的不同视图。做容量统计用 `df -hT /`，
不要把所有 overlay 行相加。

### 坑 8：`ro` 根文件系统

启动参数 `ro` 是正常的，systemd 会 remount rw。如果看到 `Read-only file system`，
查 `dmesg` 是否有 I/O error、ext4/xfs 是否 remount-ro。

## 6. 一页命令

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,ROTA,SCHED
df -hT; df -i
findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS
cat /etc/fstab
stat -f /
du -xhd1 / | sort -h | tail
lvs -a -o lv_name,vg_name,lv_size,segtype,pool_lv,data_percent,metadata_percent
pvs; vgs
rbd -p k8s-rbd ls | head
ceph df detail
```

> PVE/LVM 的容量“甜点”和 thin pool 风险见 [12 章](../12-proxmox-pve/README.md)；
> Ceph/PV 回收见 [06 章](../06-storage-ceph/README.md)。
