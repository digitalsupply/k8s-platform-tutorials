# 04 · 存储 / 磁盘 / 文件系统面试题

> 详细原理与真机证据：[06 Storage 10-storage-basics](../06-storage-ceph/10-storage-basics.md)。
> 本章只保留“一句话 + 纠偏 + 追问”。

## 1. 分区与设备

**一句话**：GPT/MBR 要懂；`lsblk`/`blkid`/`parted` 是入口；`/dev/sda` 会漂移，用 UUID/LABEL/by-id 或 udev 固定。

**本环境**：PVE GPT、m01 MBR、worker GPT；`/dev/disk/by-uuid`、`by-id` 都有。

**追问**：GPT 备份头在哪？`parted` 能修吗？udev 规则怎么写？

## 2. LVM 核心

**一句话**：PV → VG → LV；扩容通常在线，缩容通常离线且看文件系统；`pvmove` 迁移数据。

**纠偏**：“在线扩缩容”不准确：XFS 不能缩，ext4 缩要离线。

**本环境**：`pve` VG 930.51G，root 96G，thin pool 794.3G，VG 空闲 16G。

## 3. LVM 故障坑（thin pool 打满）

**一句话**：thin pool 满可能导致 pool/相关 LV 不可写、I/O 挂起，极端情况影响 VG；业务会连锁故障。

**纠偏**：“整个 VG 一定只读”不是绝对；`queue_if_no_space` 更常见的是 I/O 卡住。

**本环境**：pool 66.35%，但 autoextend 需要 158.9G，VG 只剩 16G，属于“扩不动”。

## 4. RAID 选型

**一句话**：0 性能、1 镜像、5/6 校验、10 镜像+条带；看容量/故障域/重建窗口/write hole。

**纠偏**：write hole 是 RAID5/6 无 journal/BBU 的问题，RAID10 没有同样意义。

**本环境**：PVE 单 NVMe，无 md RAID；冗余靠 Ceph 副本。

## 5. 文件系统选型

**一句话**：XFS 大文件/高并发但不能缩；ext4 通用、可离线缩；ZFS/btrfs 快照/校验但运维复杂。

**纠偏**：ext4 **不支持在线缩容**；只能 umount 后缩。

**本环境**：PVE/worker/GitLab/Harbor ext4；m01 XFS。

## 6. 挂载选项与 fstab

**一句话**：`noatime` 提性能；`barrier=0`/`nobarrier` 有掉电风险；外部盘必须 `nofail`。

**纠偏**：现代 ext4 的 `nobarrier` 基本无效/被忽略；要关屏障用 `barrier=0`，但更该靠 BBU。

**追问**：`nofail` 防什么？防开机卡 emergency mode。

## 7. 安全挂载

**一句话**：数据盘加 `noexec,nosuid,nodev`，防止执行/提权/设备文件。

**本环境**：PVE/Ubuntu fstab 没有外部数据盘；K8s 卷由 runtime 挂载。

## 8. NFS

**一句话**：`hard` 无限重试可能卡住，`soft` 超时返回 EIO；`timeo/retrans` 调优；`stale handle` 要重挂。

**纠偏**：`intr` 在现代内核基本被忽略，不要把它当解决方案。

**本环境**：NFSv4.2 `hard,timeo=600,retrans=2`，server `10.0.0.1`。

## 9. Ceph 排障

**一句话**：`ceph -s` 看健康；PG 看 `active+clean/degraded/peering/undersized/stale`；OSD 看 `up/in`。

**本环境**：HEALTH_OK，6 OSD up/in，465 PG active+clean，180G 用 88G。

## 10. 云盘特性

**一句话**：看 IOPS/吞吐配额、多挂载限制、Burstable 积分、快照一致性（`fsfreeze`）。

**本环境无云盘**：PVE 本地 NVMe + Ceph RBD；以上为通用判断，未做真机验证。

## 11. 容器存储（CSI）

**一句话**：CSI 驱动 + PV/PVC/StorageClass 动态供应；`emptyDir` 是节点本地临时盘。

**本环境**：`ceph-rbd-sc` + `nfs-sc`，17 PV 全 Bound；`rbd.csi.ceph.com`。

## 12. 容器存储语义

**一句话**：`ReadWriteOnce` = 单节点读写，不是单 Pod；`local-path` 强节点绑定，Pod 漂移数据不跟随。

**本环境**：17 个 PVC 全是 RWO；没有 local-path。

## 13. 数据可靠性

**一句话**：SMART 看坏道/寿命（NVMe `Percentage Used`、SATA `Wear_Leveling_Count`）；`dmesg` 的 `medium error` 是坏道/掉盘先兆。

**本环境**：NVMe 0% used、0 media errors、7 unsafe shutdowns；所有主机无 medium error。

## 14. 一句话总表

| 题 | 一句话 |
|---|---|
| 分区/设备 | GPT/MBR 要懂；设备名会漂移，用 UUID/by-id/udev |
| LVM | PV→VG→LV；扩在线、缩离线看 FS；`pvmove` |
| thin pool 满 | 可能 I/O 挂起/不可写，业务连锁挂；不是绝对全 VG 只读 |
| RAID | 0/1/5/6/10；重建窗口 + write hole（5/6） |
| FS 选型 | XFS 不能缩；ext4 离线可缩；ZFS/btrfs 复杂 |
| fstab | `nofail` 外部盘必加；`noexec,nosuid,nodev` |
| NFS | hard/soft/timeo/retrans；`intr` 基本无效；stale handle 重挂 |
| Ceph | `ceph -s` + PG + OSD |
| 云盘 | IOPS/吞吐/突发积分/快照一致性；本环境无云盘 |
| CSI | StorageClass + PV/PVC + CSI driver |
| RWO | 单节点，不是单 Pod；local-path 节点绑定 |
| SMART | 寿命/坏道；dmesg medium error 先备份换盘 |

## 详细证据

- [06 Storage 10-storage-basics](../06-storage-ceph/10-storage-basics.md)
- [06 证据目录](../06-storage-ceph/assets/storage-basics/README.md)
- [12 Proxmox LVM/thin pool](../12-proxmox-pve/README.md)
- [14 Containers 存储章](../14-containers/05-container-storage.md)
