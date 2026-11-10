# PVE 存储概念与运维手册：PV / VG / LV、local 与 local-lvm

> 主机：`teacher`（Proxmox VE，1TB NVMe）
> 日期：2026-11-07
> 说明：你写的 `pg` 我按 **PV（物理卷）** 理解；如果指 Ceph 的 PG（Placement Group），那是另一个概念，见文末备注。

---

## 0. 一句话结论

- **PV**：物理卷，这里是 NVMe 分区 `/dev/nvme0n1p3`，约 930.51 GiB。
- **VG**：卷组 `pve`，把 PV 切成 4MiB 的 PE 统一管理，总大小 930.51 GiB。
- **LV**：逻辑卷，VG 里切出来的“虚拟分区”，如 `root`、`swap`、`data`。
- **`local` 100.86G**：不是独立 LV，而是 **根文件系统 `pve-root`（96 GiB）的可用容量**，PVE GUI 用十进制 GB 显示；`/var/lib/vz` 只是它上面的一个目录。
- **`local-lvm` 852.88G**：是 **thin pool `data`（794.3 GiB）** 的容量，PVE GUI 用十进制 GB 显示；VM 磁盘是它里面的 thin LV。
- **VG 16G**：VG 中**未分配的物理空间**（16 GiB），可用于扩展 root/swap/data/metadata 或创建新 LV；它不等于 `local-lvm` 的 319G 空闲。

---

## 1. LVM 的层次：PV → VG → LV

```text
物理磁盘 /dev/nvme0n1
└─ 分区 /dev/nvme0n1p3                 ← PV（物理卷）930.51 GiB
   └─ VG pve                           ← 卷组，统一管理 PE
      ├─ LV root        96 GiB         ← 线性 LV，ext4，挂载 /
      ├─ LV swap         8 GiB         ← 线性 LV，swap
      ├─ LV data_tmeta   8.1 GiB       ┐
      ├─ LV data_tdata 794.3 GiB       ├─ thin pool "data"（794.3 GiB）
      ├─ LV pmspare      8.1 GiB       ┘
      │  ├─ thin LV vm-120-disk-0 40 GiB（虚拟大小）
      │  ├─ thin LV vm-122-disk-0 60 GiB（虚拟大小）
      │  └─ ...
      └─ VG 空闲 16 GiB                ← 未分配的 PE
```

### 1.1 PV（Physical Volume，物理卷）

- 这里是 `/dev/nvme0n1p3`；
- LVM 把物理磁盘/分区标记为 PV，切成固定大小的 **PE（Physical Extent）**；
- 当前 PE 大小 4 MiB，VG 共 238,210 个 PE，其中 4,096 个空闲（4,096 × 4MiB = 16 GiB）。

### 1.2 VG（Volume Group，卷组）

- VG `pve` 是 PV 上的“存储池”；
- 所有 LV 都从 VG 的 PE 中分配；
- `vgs` 里的 `VFree` 就是未分配的 PE 总量。

### 1.3 LV（Logical Volume，逻辑卷）

- LV 是 VG 里切出来的“逻辑分区”；
- 可以是 linear（线性，如 root/swap）；
- 也可以是 thin（精简，如 VM 磁盘）；
- `data` 是一个特殊的 **thin pool LV**，内部再放很多 thin LV。

### 1.4 PE / LE

- PE：PV 上的物理块（4MiB）；
- LE：LV 上的逻辑块，通常与 PE 一一对应；
- `vgdisplay -v` 可以看到 PE/LE 的映射。

> 备注：如果你说的 `pg` 是 Ceph 的 PG（Placement Group），那是 Ceph 的概念，和 LVM 的 PV 无关。当前 Ceph 有 465 个 PG。

---

## 2. 当前实际布局

### 2.1 LVM 视角（GiB，1024 进制）

```text
PV             PSize    PFree  Used
/dev/nvme0n1p3 <930.51g 16.00g <914.51g

VG  VSize    VFree  Ext   #Ext   Free
pve <930.51g 16.00g 4.00m 238210 4096

LV           LSize   Type      Pool  Data%  Meta%
root          96.00g linear
swap           8.00g linear
data         794.30g thin-pool       59.77  1.99
data_tdata   794.30g linear
data_tmeta     8.10g linear
pmspare        8.10g linear
```

### 2.2 PVE 视角（GB，1000 进制，GUI 显示）

```text
local       dir      100.86G 总
local-lvm   lvmthin  852.88G 总
```

### 2.3 单位差异（关键）

- `lvs` / `vgs` / `lsblk` 默认用 **GiB（1024 进制）**；
- PVE GUI / `pvesm` 显示常用 **GB（1000 进制）**；
- 所以：

```text
96 GiB root      ≈ 103.08 GB（LV 原始大小）
94 GiB ext4      ≈ 100.86 GB（PVE local 显示，扣掉 ext4 元数据/保留块）
794.3 GiB data   ≈ 852.88 GB（PVE local-lvm 显示）
16 GiB VG free   ≈ 17.18 GB
8 GiB swap       ≈ 8.59 GB
8.1 GiB tmeta    ≈ 8.70 GB
8.1 GiB pmspare  ≈ 8.70 GB
```

把这些加在一起：

```text
root(LV) 103.08 + data 852.88 + swap 8.59 + tmeta 8.70 + spare 8.70 + VG free 17.18
≈ 999.13 GB
```

而磁盘是 1TB 十进制（约 1000.2 GB / 931.5 GiB），差额是分区表/对齐/取整。

所以 **`local` 100.86G + `local-lvm` 852.88G 看起来接近磁盘上限，但并没有超过物理盘**；中间还有 swap、tmeta、pmspare、VG free 等。

---

## 3. `local` 的 100.86G 是什么

### 3.1 它不是一个独立 LV

`local` 是 PVE 的 **dir 类型存储**：

```ini
dir: local
    path /var/lib/vz
    content vztmpl,iso,backup
```

- 路径：`/var/lib/vz`；
- 内容：容器模板、ISO、备份；
- 它位于 **`pve-root` 的 ext4 文件系统**上；
- PVE GUI 显示的 100.86G 是 **整个根文件系统的容量**，不是 `/var/lib/vz` 单独的大小。

### 3.2 为什么 `local` 的 used 看起来很大

`pvesm status` 的 `local` used 是根文件系统的 used，包含：

```text
/var/lib/vz      8.4G   （ISO 8.3G）
/data            23G    （NFS + Prometheus 21G）
/var/lib/docker  3.1G
/var/log         0.6G
PVE OS 等        约 10G
```

所以：

- `local` 显示 100.86G 总 / 约 47G used；
- 但 `/var/lib/vz` 本身只有 8.4G；
- **`local` 的容量与根分区共享**，不是 100.86G 都归 ISO/备份用。

### 3.3 关联

```text
VG pve
└─ LV root 96 GiB
   └─ ext4 (/)
      ├─ /var/lib/vz  ← PVE "local" 存储
      ├─ /data        ← NFS/Prometheus
      ├─ /var/lib/docker
      └─ PVE OS/日志
```

---

## 4. `local-lvm` 的 852.88G 是什么

### 4.1 它是 thin pool 的容量

`local-lvm` 是 PVE 的 **lvmthin 类型存储**：

```ini
lvmthin: local-lvm
    thinpool data
    vgname pve
    content images,rootdir
```

- 使用 VG `pve`；
- 使用 thin pool `data`；
- 内容：VM 磁盘、容器 rootdir；
- GUI 显示的 852.88G = thin pool `data` 的 794.3 GiB（十进制换算）。

### 4.2 VM 磁盘在哪里

VM 磁盘是 `data` thin pool 里的 thin LV：

```text
data (thin pool)
├─ vm-120-disk-0   40 GiB 虚拟，实际约 14.4 GiB
├─ vm-122-disk-0   60 GiB 虚拟，实际约 36.6 GiB
├─ vm-116-disk-1   30 GiB 虚拟，实际 30 GiB（Ceph OSD）
└─ ...
```

- `lvs` 里的 VM 磁盘大小是 **虚拟大小**；
- `data%` 是 **实际分配**；
- 虚拟总量可以大于 794.3G（thin 超分），但实际写入不能超过 pool 容量。

### 4.3 关联

```text
VG pve
└─ LV data 794.3 GiB (thin pool)
   ├─ data_tdata 794.3 GiB  ← 数据
   ├─ data_tmeta   8.1 GiB  ← 元数据
   ├─ pmspare      8.1 GiB  ← 元数据备用
   └─ 很多 thin LV（VM 磁盘）
```

---

## 5. `local` 与 `local-lvm` 的关系

| 项目 | `local` | `local-lvm` |
|---|---|---|
| PVE 类型 | dir | lvmthin |
| 底层对象 | LV `root` 上的 ext4 | thin pool `data` |
| 路径/卷组 | `/var/lib/vz` | VG `pve` / pool `data` |
| 内容 | ISO、模板、备份 | VM 磁盘、容器 rootdir |
| GUI 容量 | 根文件系统容量 100.86G | thin pool 容量 852.88G |
| 单位 | 1000 进制 GB | 1000 进制 GB |
| 是否独立 LV | 否，属于 `pve-root` | 是，`data` 是 thin pool LV |
| 空闲含义 | 根分区可用空间 | thin pool 未分配 chunk |

**它们不是父子关系，而是 VG `pve` 下的两个兄弟：**

```text
VG pve
├─ LV root 96 GiB → ext4 → local (/var/lib/vz)
└─ LV data 794.3 GiB → thin pool → local-lvm (VM 磁盘)
```

---

## 6. VG 的 16G 是什么

`vgs` 里的：

```text
VG  VSize    VFree
pve <930.51g 16.00g
```

- `VFree 16.00 GiB` = VG 中**完全没有分配给任何 LV 的 PE**；
- 它是 4,096 个 4MiB 的 free extent；
- 可以用于：
  - 扩展 `root`；
  - 扩展 `swap`；
  - 扩展 `data` thin pool；
  - 扩展 `data_tmeta` 元数据；
  - 创建新的 LV；
- **不是** `local-lvm` 的剩余空间。

### 6.1 与 `local-lvm` 空闲的区别

| 指标 | 当前值 | 含义 |
|---|---:|---|
| `VG VFree` | 16 GiB | 未分配给任何 LV 的物理空间 |
| `thin pool 空闲` | 约 319 GiB | `data` 内部尚未分配的 chunk，可供 VM 磁盘增长 |
| `local` 空闲 | 约 45 GiB | 根文件系统可用空间 |

所以：

- VM 磁盘继续增长，先消耗 **thin pool 空闲**（319G）；
- 当 pool 需要“变大”时，才需要 **VG 空闲**（16G）；
- `lvm.conf` 配了 `thin_pool_autoextend_threshold=70`、`percent=20`，到 70% 想扩 159G，但 VG 只有 16G，**autoextend 会失败**——这是当前布局的最大隐患。

---

## 7. 常用查看命令

### 7.1 LVM 总览

```bash
# PV
pvs
pvs -o pv_name,pv_size,pv_free,pv_used
pvdisplay

# VG
vgs
vgs -o vg_name,vg_size,vg_free,vg_extent_size,vg_extent_count,vg_free_count
vgdisplay -v

# LV
lvs
lvs -a -o lv_name,vg_name,lv_size,segtype,pool_lv,data_percent,metadata_percent,seg_monitor,devices
lvdisplay
```

### 7.2 thin pool 专项

```bash
# thin pool 使用率
lvs -o lv_name,lv_size,data_percent,metadata_percent,chunk_size pve/data

# 所有 thin LV 的 Data%
lvs -a -o lv_name,lv_size,pool_lv,data_percent pve

# dm 层状态
dmsetup status pve-data-tpool
dmsetup table pve-data-tpool
```

`dmsetup status` 关键字段：

```text
thin-pool 386 42207/2123776 7778885/13013888 - rw discard_passdown queue_if_no_space - 1024
           │   │              │
           │   │              └─ 数据块 used/total（59.77%）
           │   └─ 元数据块 used/total（1.99%）
           └─ transaction id
```

- `discard_passdown`：TRIM 会传给底层；
- `queue_if_no_space`：pool 满时 IO 排队（VM 可能卡死）。

### 7.3 PVE 存储

```bash
# 存储总览
pvesm status

# 查看 local / local-lvm 内容
pvesm list local
pvesm list local-lvm

# 查看某个卷的实际路径
pvesm path local:iso/ubuntu.iso
pvesm path local-lvm:vm-120-disk-0

# 存储配置
cat /etc/pve/storage.cfg

# VM 磁盘配置
qm config 120 | grep -E '^(scsi|virtio|ide|sata)'
```

### 7.4 文件系统与盘

```bash
df -hT /
df -hT /var/lib/vz
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
du -sh /var/lib/vz /data /var/lib/docker /var/log
```

### 7.5 查看 autoextend 配置

```bash
lvmconfig --type default activation/thin_pool_autoextend_threshold
lvmconfig --type default activation/thin_pool_autoextend_percent
grep -nE 'thin_pool_autoextend' /etc/lvm/lvm.conf
```

---

## 8. 常用运维命令

> 以下命令有风险，执行前先备份 VG 元数据和重要数据；生产环境先在测试环境验证。

### 8.1 备份/恢复 VG 元数据

```bash
# 备份
vgcfgbackup -f /root/vg-pve-$(date +%F-%H%M).vg pve

# 查看备份
vgcfgrestore --list pve

# 恢复（谨慎，通常用于灾难恢复）
# vgcfgrestore -f /root/vg-pve-xxxx.vg pve
```

### 8.2 扩展根分区（在线，ext4）

前提：VG 有空闲。

```bash
lvextend -L +10G /dev/pve/root
resize2fs /dev/pve/root
df -h /
```

### 8.3 扩展 thin pool

前提：VG 有空闲。

```bash
lvextend -L +10G /dev/pve/data
pvesm status
lvs -o lv_name,lv_size,data_percent,metadata_percent pve/data
```

> 扩展 pool 只是增加 `data` 的大小，不会自动增加 `tmeta`。

### 8.4 扩展 thin pool 元数据

```bash
lvextend --poolmetadatasize +1G /dev/pve/data
lvs -o lv_name,lv_size,metadata_percent pve/data
```

> 元数据扩展通常需要 VG 空闲；先确认 `vgs`。

### 8.5 增加一块盘到 VG

```bash
# 假设新盘 /dev/sdb
pvcreate /dev/sdb
vgextend pve /dev/sdb
vgs
```

之后可以扩展 `data` 或 `root`，或者保留为 VG 空闲。

### 8.6 从 VG 移除一块盘

```bash
# 先把数据迁走
pvmove /dev/sdb
vgreduce pve /dev/sdb
pvremove /dev/sdb
```

> 需要确保目标盘容量足够，操作前备份。

### 8.7 创建/删除 LV

```bash
# 创建普通 LV
lvcreate -n mylv -L 10G pve

# 创建 thin LV（一般由 PVE 自动做，手工需谨慎）
lvcreate -V 20G -T pve/data -n mythin

# 删除 LV（确认没有 VM/数据使用）
lvremove /dev/pve/mylv
```

### 8.8 PVE 卷分配/释放

```bash
# 在 local-lvm 分配一个卷（谨慎，通常由 PVE/qm 调用）
pvesm alloc local-lvm 120 vm-120-disk-1 10G

# 释放卷（谨慎，确认 VM 已不再使用）
pvesm free local-lvm:vm-120-disk-1
```

### 8.9 查看 VM 磁盘实际占用

```bash
# thin LV 的分配率
lvs -o lv_name,lv_size,data_percent pve | grep vm-120

# qemu-img 查看虚拟大小/实际大小（只读）
qemu-img info /dev/pve/vm-120-disk-0

# PVE 快照
qm listsnapshot 120
```

### 8.10 快照相关

```bash
qm snapshot 120 before-upgrade --description "upgrade"
qm listsnapshot 120
qm delsnapshot 120 before-upgrade
```

> 快照会占用 thin pool 空间；删除快照后才能释放其独占 chunk。

---

## 9. 推荐监控指标

```bash
# 一条命令看关键指标
lvs -o lv_name,lv_size,data_percent,metadata_percent pve/data
vgs -o vg_name,vg_size,vg_free
pvesm status
df -h /
```

告警建议：

| 指标 | 预警 | 严重 |
|---|---|---|
| thin pool `data%` | ≥ 65% | ≥ 70% |
| thin pool `meta%` | ≥ 70% | ≥ 85% |
| VG `VFree` | < 5% | < 2% |
| 根分区使用率 | ≥ 75% | ≥ 85% |
| `dmsetup` 出现 `queue_if_no_space` | 立即关注 | pool 接近满 |

---

## 10. 当前关键数据（实测）

```text
PV:            /dev/nvme0n1p3  930.51 GiB  PFree 16 GiB
VG:            pve             930.51 GiB  VFree 16 GiB
root:          96 GiB linear ext4  45G used / 94G total (51%)
swap:          8 GiB linear        0B used
data:          794.3 GiB thin-pool 59.77% used
tmeta:         8.1 GiB             1.99% used
pmspare:       8.1 GiB
chunk:         64K
autoextend:    70% / 20%
thin pool:     discard_passdown, queue_if_no_space
local:         100.86 GB（≈93.9 GiB，根文件系统）
local-lvm:     852.88 GB（≈794.3 GiB，thin pool）
```

---

## 11. 备注：如果 `pg` 指 Ceph PG

如果你说的 `pg` 是 Ceph 的 Placement Group，而不是 LVM 的 PV：

- Ceph 当前 15 个 pool、465 个 PG，全部 `active+clean`；
- PG 是 Ceph 数据分布/复制的基本单位；
- 与 PVE 的 PV/VG/LV 没有直接关系；
- 查看命令：
  ```bash
  ceph -s
  ceph osd pool ls detail
  ceph pg stat
  ceph osd df tree
  ```

---

## 12. 一句话总结

**`local` 100.86G 是根文件系统 `pve-root` 的容量（PVE 用十进制 GB 显示），`local-lvm` 852.88G 是 thin pool `data` 的容量；两者都是 VG `pve` 下的兄弟 LV，不是父子关系。VG 的 16G 是未分配的物理空间，不是 thin pool 的 319G 空闲。日常看 `pvs/vgs/lvs/pvesm status/dmsetup status` 就够了。**
