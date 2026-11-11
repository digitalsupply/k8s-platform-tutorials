# 10 · 存储 / 磁盘 / 文件系统：从分区到 CSI

> 这一章把“存储面试题”落到本环境的真机：PVE 本地 NVMe + LVM-thin、K8s Ceph RBD/NFS、
> GitLab/Harbor 的 ext4、SMART 与 dmesg。
>
> 证据：[`assets/storage-basics/`](assets/storage-basics/README.md)。

## 1. 本环境的存储地图

| 层 | 实际 | 证据 |
|---|---|---|
| PVE 物理盘 | Intel NVMe 1TB，GPT，LVM `pve` | `parted`/`lsblk`/`smartctl` |
| PVE 根 | `ext4` on `pve-root` 96G | `findmnt` |
| PVE thin pool | `pve/data` 794.3G，当前 **66.35%**，VG 空闲 **16G** | `lvs`/`pvesm` |
| K8s 块存储 | Ceph RBD `ceph-rbd-sc`，17 个 PV，全部 `ReadWriteOnce` | `kubectl get pv/pvc` |
| K8s 文件存储 | NFS `nfs-sc`，NFSv4.2 `hard` | `mount`/PV spec |
| GitLab/Harbor | ext4 根盘 77G/58G，`discard,commit=30` | `findmnt` |
| 物理健康 | NVMe `Percentage Used 0%`、`Media Errors 0`、Unsafe Shutdowns 7 | `smartctl` |
| 介质错误 | 所有主机当前 dmesg 无 `medium error`/`I/O error` | `dmesg` |

## 2. 分区与设备命名

### 2.1 GPT vs MBR

| 项 | MBR | GPT |
|---|---|---|
| 分区数 | 4 主分区 | 128+ |
| 容量 | 2TB 限制 | 很大 |
| 备份 | 无 | 分区表头/尾备份 |
| 启动 | BIOS | UEFI（也可 BIOS boot） |

本环境：

- PVE `nvme0n1`：**GPT**，有 BIOS boot + EFI + LVM 三个分区；
- m01 `sda`：**MBR（msdos）**，两个主分区；
- worker01 `sda`：**GPT**，BIOS boot + /boot + LVM。

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,UUID,MOUNTPOINTS
blkid
parted -l
```

### 2.2 设备名会漂移

`/dev/sda`、`/dev/nvme0n1` 的顺序可能因加盘/换槽变化。稳定引用：

```bash
ls -l /dev/disk/by-uuid
ls -l /dev/disk/by-id
ls -l /dev/disk/by-path
```

本机：

```text
0444de59-... -> ../../dm-1          # pve-root
nvme-INTEL_SSDPE2KX010T8_<serial>... -> ../../nvme0n1
lvm-pv-uuid-5S0dr8-... -> ../../nvme0n1p3
```

fstab 最佳实践：

- `UUID=...` / `LABEL=...` / `/dev/disk/by-uuid/...`；
- LVM 可用 `/dev/mapper/<vg>-<lv>` 或 `/dev/<vg>/<lv>`（比 `/dev/sda` 稳）；
- 不要写 `/dev/sdb1`。

> 本环境 PVE 用 `/dev/pve/root`，m01 用 `/dev/mapper/rl-root`；它们是 LVM 路径，
> 比裸设备名稳，但仍不如 UUID/LABEL 直观。

## 3. LVM：PV → VG → LV

```text
/dev/nvme0n1p3 (PV, 930.5G)
└─ VG pve (930.51G)
   ├─ LV root 96G ext4 /
   ├─ LV swap 8G
   ├─ LV data 794.3G thin pool
   │  ├─ data_tdata
   │  ├─ data_tmeta
   │  ├─ pmspare
   │  └─ thin LV vm-119-disk-0 ...
   └─ VG free 16G
```

```bash
pvs
vgs -o vg_name,vg_size,vg_free
lvs -a -o lv_name,vg_name,lv_size,segtype,pool_lv,data_percent,metadata_percent
```

### 3.1 扩缩容的边界

| 操作 | 在线 | 说明 |
|---|---|---|
| LV 扩容 | 通常可以 | `lvextend` + `resize2fs`/`xfs_growfs` |
| LV 缩容 | **一般要离线** | 先缩 FS，再 `lvreduce`；XFS 不支持缩 |
| thin pool 扩容 | 可以 | `lvextend` pool + `lvextend` metadata（按需） |
| thin pool 缩容 | 不简单 | 需先删/迁移 thin LV，风险高 |
| `pvmove` | 可以 | 迁移 PV 上的数据，前提 VG 有足够空间 |

> “LVM 支持在线扩缩容”要加限定：**扩通常在线，缩通常离线，且取决于文件系统**。

### 3.2 thin pool 的真实风险

本机：

```text
data  pve  794.30g  Data% 66.35  Meta% 2.17
VG pve 930.51g  VFree 16.00g
thin_pool_autoextend_threshold = 70
thin_pool_autoextend_percent = 20
```

- pool 到 70% 时想扩 20%（约 158.9G），但 VG 只剩 16G；
- autoextend 会失败；
- 如果 pool 写满，`queue_if_no_space` 可能让 I/O 挂起；
- LVM 可能把 thin pool/相关 LV 置为不可写，极端情况下影响 VG 元数据；
- **“整个 VG 一定只读”不是绝对，但业务被拖死是真实风险**。

本环境曾发生 **Ceph `k8s-rbd` 池 100% full** 导致 CSI/CNPG/监控连锁故障（见 04 章），
原理类似：共享存储池写满，所有依赖它的业务一起挂。

### 3.3 容量甜点

```text
root = OS + ISO/备份 + 额外服务 + 20% 余量
VG 空闲 = max(3–5% VG, 一次 autoextend 的量)
data = VG - root - swap - tmeta - pmspare - VG 空闲
```

本机 VG 空闲 16G < 一次 autoextend 158.9G，属于“配置了 autoextend 但扩不动”。

## 4. RAID 选型

| 级别 | 容量 | 容错 | 写性能 | 风险 |
|---|---|---|---|---|
| RAID0 | 100% | 0 | 高 | 一块坏全丢 |
| RAID1 | 50% | 1 块 | 读高写一般 | 重建简单 |
| RAID5 | N-1 | 1 块 | 写放大 | 重建窗口、write hole |
| RAID6 | N-2 | 2 块 | 写放大更大 | 重建更慢 |
| RAID10 | 50% | 每组 1 块 | 高 | 成本高 |

**Write Hole**：RAID5/6 断电时，数据盘和校验盘可能不一致；BBU/掉电保护或 journal
可以缓解。RAID10 没有校验盘，不存在同样意义的 write hole。

本环境：

- PVE 单 NVMe，没有 md RAID（`/proc/mdstat` 无 active array）；
- 冗余由 **Ceph 副本**提供（6 OSD，3 host，pool 默认副本）；
- VM 磁盘是 LVM-thin，不是 RAID。

> 面试可以讲 RAID，但不要把“本环境有 RAID”说死；这里是 Ceph + 单盘。

## 5. 文件系统选型

| FS | 优势 | 缩容 | 本环境 |
|---|---|---|---|
| ext4 | 通用、成熟、工具多 | **离线**可缩 | PVE 根、worker、GitLab/Harbor |
| XFS | 大文件、高并发、RHEL 默认 | **不支持缩** | m01 |
| ZFS/btrfs | 快照/校验/压缩 | 复杂 | 未用于 K8s 数据盘 |

**纠正**：ext4 **不支持在线缩容**；只能 umount 后 `e2fsck` + `resize2fs` 缩，再 `lvreduce`。
XFS 只能扩，不能缩。

## 6. 挂载选项与 fstab

### 6.1 常用选项

| 选项 | 作用 | 风险 |
|---|---|---|
| `noatime` | 不更新访问时间，减少写 | 一般安全 |
| `relatime` | 默认，兼顾性能/时间 | 安全 |
| `nofail` | 挂载失败不阻塞启动 | **外部盘必须** |
| `noexec` | 禁止执行二进制 | 数据盘推荐 |
| `nosuid` | 忽略 setuid | 数据盘推荐 |
| `nodev` | 忽略设备文件 | 数据盘推荐 |
| `barrier=0`/`nobarrier` | 关闭写屏障 | **断电丢数据风险** |
| `discard` | 在线 TRIM | 可能增加 I/O |

**纠正**：

- `nobarrier` 在现代 ext4 已不是有效选项/被忽略；要关屏障用 `barrier=0`（危险），
  更好的做法是确保有 BBU/掉电保护。
- `noatime` 提升有限，`relatime` 通常够用。

### 6.2 `nofail` 是外部盘头号救命选项

如果 `/etc/fstab` 里外部盘没有 `nofail`，盘坏/线松/云盘未挂上，systemd 会卡在
`local-fs.target`，进入 emergency mode。

```fstab
UUID=xxxx /data ext4 defaults,nofail,noexec,nosuid,nodev 0 2
```

本环境：

- PVE fstab 只有 root/efi/swap/proc，无外部盘；
- GitLab/Harbor fstab 用 `LABEL=cloudimg-rootfs`、`LABEL=BOOT`、`LABEL=UEFI`；
- K8s 节点没有额外 fstab 数据盘（RBD/NFS 由 K8s 挂载）。

### 6.3 安全挂载

数据盘建议：

```text
noexec,nosuid,nodev,nofail
```

防止在数据盘放 setuid 程序/脚本直接执行。

## 7. NFS

### 7.1 hard vs soft

| 选项 | 行为 | 场景 |
|---|---|---|
| `hard` | 无限重试，可能卡住 | 数据库/不能丢数据 |
| `soft` | 超时返回 EIO | 可容忍失败 |
| `timeo` | 超时（0.1s 单位） | 调优 |
| `retrans` | 重传次数 | 调优 |

**纠正**：`intr` 在现代内核基本被忽略，不能作为“卡住可中断”的解决方案；
用 `hard/soft`、`timeo`、`retrans`、`nofail`，并监控。

### 7.2 本环境 NFS

PV：

```yaml
nfs:
  server: 10.0.0.1
  path: /data/nfs/...
storageClassName: nfs-sc
```

worker03 挂载：

```text
10.0.0.1:/data/nfs/... on /var/lib/kubelet/pods/... type nfs4
(rw,relatime,vers=4.2,rsize=1048576,wsize=1048576,hard,proto=tcp,timeo=600,retrans=2,sec=sys)
```

### 7.3 stale handle

NFS 服务端文件被删/导出变化，客户端还持有旧 file handle：

```text
Stale file handle
```

处理：

- `umount`/重新挂载；
- 确认服务端 export/path；
- 不要在有写入时强删服务端目录。

## 8. Ceph 排障

本环境：

```text
health: HEALTH_OK
mon: 3 daemons, quorum ceph-02,ceph-03,ceph-01
osd: 6 osds: 6 up, 6 in
pools: 15, pgs: 465
pgs: 465 active+clean
usage: 88 GiB used, 92 GiB / 180 GiB avail
```

关键命令：

```bash
ceph -s
ceph pg stat
ceph osd tree
ceph df detail
ceph pg dump_stuck
```

PG 状态：

| 状态 | 含义 |
|---|---|
| `active+clean` | 正常 |
| `degraded` | 副本不足 |
| `peering` | 正在协商 |
| `undersized` | 副本数低于配置 |
| `stale` | PG 未上报 |
| `inconsistent` | 数据/校验不一致 |

OSD 状态：

- `up`：OSD 进程可达；
- `in`：参与数据分布；
- `down`/`out`：故障/被移出。

**排障顺序**：`ceph -s` → `ceph osd tree` → `ceph pg dump_stuck` → `ceph health detail` → 日志。

## 9. 云盘特性（本环境无云盘，通用）

本环境是 PVE 本地 NVMe + Ceph RBD，没有 gp2/gp3 云盘。面试通用要点：

- IOPS/吞吐有配额，块大小影响 IOPS；
- 多挂载限制（RWO/单节点）；
- **Burstable**（如 gp2）有积分桶，耗尽后掉到基线；
- 快照一致性：应用层 `fsfreeze`/数据库备份，不能只靠云快照；
- 云盘扩容后还要扩分区/文件系统。

## 10. 容器存储与 CSI

```text
PVC（命名空间） → PV（集群） → StorageClass → CSI Driver → Ceph RBD/NFS
```

本环境：

```text
StorageClass: ceph-rbd-sc (Retain, Immediate), nfs-sc (Delete, Immediate)
CSIDriver: rbd.csi.ceph.com (Persistent, attachRequired=true)
PV/PVC: 17 个，全部 Bound，accessModes=[ReadWriteOnce]
```

### 10.1 RWO 的真实语义

**ReadWriteOnce = 单节点读写**，不是“单 Pod”。

- 同一节点上的多个 Pod 可以同时挂同一个 RWO 卷；
- 跨节点不行；
- `ReadWriteMany` 才能多节点。

### 10.2 local-path / emptyDir

- `local-path`：PV 绑定到具体节点，Pod 漂移后数据不跟随；
- `emptyDir`：节点本地临时目录，Pod 删除即丢；
- `hostPath`：直接挂宿主目录，节点绑定 + 安全风险。

本环境没有 `local-path`，但有 `nfs-sc` 和 `ceph-rbd-sc`；不要把 local-path 当共享存储。

## 11. SMART 与介质错误

### 11.1 本机 SMART

```text
Model: INTEL SSDPE2KX010T8
Percentage Used: 0%
Available Spare: 100%
Media and Data Integrity Errors: 0
Error Information Log Entries: 0
Unsafe Shutdowns: 7
Data Units Written: 43,556,650 [22.3 TB]
Power On Hours: 2,374
```

### 11.2 看什么

- NVMe：`Percentage Used`、`Available Spare`、`Media Errors`、`Unsafe Shutdowns`；
- SATA SSD：`Wear_Leveling_Count`、`Media_Wearout_Indicator`、`Reallocated_Sector_Ct`；
- HDD：`Reallocated_Sector_Ct`、`Pending_Sector_Ct`、`Offline_Uncorrectable`；
- `smartctl -a /dev/sdX` / `nvme smart-log /dev/nvmeX`。

### 11.3 dmesg 关键字

```bash
dmesg -T | grep -iE 'medium error|i/o error|blk_update_request|nvme.*error|ata.*error'
```

本环境所有主机当前没有命中。

> `medium error` 是磁盘物理坏道/掉盘先兆；不要只重启，先备份/换盘。

## 12. 一页命令

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTTYPENAME,UUID,MOUNTPOINTS
blkid
parted -l
ls -l /dev/disk/by-uuid /dev/disk/by-id
pvs; vgs -o vg_name,vg_size,vg_free
lvs -a -o lv_name,vg_name,lv_size,segtype,pool_lv,data_percent,metadata_percent
cat /etc/fstab; findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS
lsmod | grep -E 'raid|md'; cat /proc/mdstat
xfs_info /; tune2fs -l $(findmnt -n -o SOURCE /) | head
ceph -s; ceph pg stat; ceph osd tree; ceph df detail
kubectl get sc,pv,pvc -A
smartctl -a /dev/nvme0n1
dmesg -T | grep -iE 'medium error|i/o error|blk_update_request'
```
