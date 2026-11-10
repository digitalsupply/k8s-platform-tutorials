# PVE 中 LVM / thin pool / 虚拟机磁盘到底在哪里？

> 主机：`teacher`（Proxmox VE，1TB NVMe）
> 日期：2026-11-07
> 结论先说：**虚拟机磁盘不是 `/` 下的文件，而是 `/dev/pve/vm-*` 块设备；QEMU 直接打开这些块设备运行 VM。**

---

## 0. 一句话结论

- `/` 根目录只有 **96G 的 `pve-root`**，放 PVE 系统、ISO、模板、备份、NFS 等；
- 虚拟机磁盘在 **`local-lvm` 的 thin pool `data`** 里，是 **块设备**：
  ```
  /dev/pve/vm-120-disk-0  →  /dev/dm-26
  ```
- QEMU 进程用 `-drive file=/dev/pve/vm-120-disk-0,...` 直接打开它；
- 所以 `du -sh /`、`df -h /` **看不到** VM 磁盘，这是正常的；
- 查看 VM 磁盘要用 `lvs`、`pvesm`、`lsblk`、`dmsetup`、`qm showcmd`，不是 `du`。

---

## 1. 三个视角看同一块磁盘

### 1.1 PVE 存储视角

```text
local       dir       /var/lib/vz       ISO、模板、备份
local-lvm   lvmthin   thin pool data    VM 磁盘、容器 rootdir
```

`/etc/pve/storage.cfg`：

```ini
dir: local
    path /var/lib/vz
    content vztmpl,iso,backup

lvmthin: local-lvm
    thinpool data
    vgname pve
    content images,rootdir
```

- `local` 是 **目录型存储**，位于根文件系统；
- `local-lvm` 是 **块设备型存储**，位于 VG `pve` 的 thin pool `data`；
- VM 磁盘属于 `local-lvm`，不属于 `local`。

### 1.2 LVM 视角

```text
PV /dev/nvme0n1p3  930.51 GiB
└─ VG pve
   ├─ LV root        96 GiB  → ext4 → /
   ├─ LV swap         8 GiB
   ├─ LV data       794.3 GiB → thin pool
   │  ├─ data_tdata 794.3 GiB（数据）
   │  ├─ data_tmeta   8.1 GiB（元数据）
   │  ├─ pmspare      8.1 GiB（元数据备用）
   │  ├─ thin LV vm-120-disk-0  40 GiB
   │  ├─ thin LV vm-122-disk-0  60 GiB
   │  └─ ...
   └─ VG 空闲 16 GiB
```

### 1.3 QEMU / KVM 视角

`qm showcmd 120 --pretty` 会看到：

```text
-drive 'file=/dev/pve/vm-120-disk-0,if=none,id=drive-scsi0,
        discard=on,format=raw,cache=none,aio=io_uring,
        detect-zeroes=unmap'
-device 'scsi-hd,bus=virtioscsi0.0,channel=0,scsi-id=0,
         lun=0,drive=drive-scsi0,id=scsi0,rotation_rate=1,bootindex=100'
```

QEMU 把 `/dev/pve/vm-120-disk-0` 当作 **raw 块设备**打开，不是文件。

---

## 2. 这台机器上的实际证据

### 2.1 `lsblk` 树

```text
nvme0n1                         931.5G disk
├─nvme0n1p1                      1007K part
├─nvme0n1p2                         1G part vfat  /boot/efi
└─nvme0n1p3                     930.5G part LVM2_member
  ├─pve-swap                        8G lvm  swap  [SWAP]
  ├─pve-root                       96G lvm  ext4  /
  ├─pve-data_tmeta                8.1G lvm
  │ └─pve-data-tpool            794.3G lvm
  │   ├─pve-data                794.3G lvm
  │   ├─pve-vm--120--disk--0      40G lvm
  │   ├─pve-vm--122--disk--0      60G lvm
  │   ├─pve-vm--116--disk--0      80G lvm
  │   └─ ...
  └─pve-data_tdata              794.3G lvm
```

关键：

- `pve-vm--120--disk--0` 是 **块设备**，`TYPE=lvm`，没有 `MOUNTPOINT`；
- 它不在 `/` 的目录树里；
- 它是 `pve-data-tpool` 上的 thin LV。

### 2.2 `/dev/pve/` 是块设备符号链接

```text
# ls -l /dev/pve
root              -> ../dm-1
swap              -> ../dm-0
vm-120-disk-0     -> ../dm-26
vm-122-disk-0     -> ../dm-...
...
```

- `/dev/pve/vm-120-disk-0` 只是一个符号链接；
- 真正的设备节点是 `/dev/dm-26`；
- `/dev/mapper/pve-vm--120--disk--0` 也是同一个设备。

### 2.3 `pvesm path` 直接给出块设备路径

```bash
pvesm path local-lvm:vm-120-disk-0
# /dev/pve/vm-120-disk-0

pvesm path local-lvm:vm-122-disk-0
# /dev/pve/vm-122-disk-0
```

### 2.4 `qm showcmd` 证明 QEMU 直接打开块设备

```text
-drive 'file=/dev/pve/vm-120-disk-0,...'
```

没有 `/var/lib/vz/images/vm-120-disk-0.qcow2` 这种文件。

### 2.5 `qemu-img info` 的“disk size: 0 B”是正常的

```text
# qemu-img info /dev/pve/vm-120-disk-0
image: /dev/pve/vm-120-disk-0
file format: raw
virtual size: 40 GiB (42949672960 bytes)
disk size: 0 B
Child node '/file':
    filename: /dev/pve/vm-120-disk-0
    protocol type: host_device
    file length: 40 GiB
    disk size: 0 B
```

- 对块设备，`qemu-img` 不能像文件那样统计“已分配磁盘大小”；
- `disk size: 0 B` 不代表空盘；
- 实际占用要看 thin pool 的 `data%` 或 `lvs`。

### 2.6 `lsof` 证明 KVM 进程正在使用它

```text
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
kvm     37336 root   41u   BLK 252,26      0t0  593 /dev/pve/../dm-26
```

- `kvm` 进程以块设备方式打开 `/dev/dm-26`；
- 这就是 VM 正在运行的证据。

### 2.7 `/var/lib/vz/images` 是空的

```text
# ls -la /var/lib/vz/images
total 8
drwxr-xr-x 2 root root 4096 ...
drwxr-xr-x 6 root root 4096 ...
```

因为 VM 磁盘不在 `dir` 存储里，而在 `lvmthin` 存储里。

> `/var/lib/vz/images` 只在使用 `dir` 存储放 VM 磁盘（qcow2/raw 文件）时才用；当前 `local` 的 content 只有 `vztmpl,iso,backup`。

---

## 3. 为什么 `df` / `du` 看不到 VM 磁盘？

### 3.1 `df -h /`

```text
/dev/mapper/pve-root   94G   45G   45G   51%   /
```

`/` 只是 `pve-root` 的文件系统，96 GiB；VM 磁盘不在里面。

### 3.2 `du -sh /`

`du` 只统计**文件**；`/dev/pve/vm-*` 是**块设备**，不是文件，所以不会被统计。

### 3.3 正确查看方式

```bash
# 看 thin pool 实际使用
lvs -o lv_name,lv_size,data_percent,metadata_percent pve/data

# 看所有 VM 磁盘的分配率
lvs -a -o lv_name,lv_size,pool_lv,data_percent pve

# PVE 存储用量
pvesm status

# 块设备树
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT

# 具体 VM 的磁盘
qm config 120 | grep scsi
pvesm path local-lvm:vm-120-disk-0
lvs -o lv_name,lv_size,data_percent pve/vm-120-disk-0
```

---

## 4. LVM 元数据在哪里？

LVM 的元数据有两份：

### 4.1 磁盘上的元数据区

- 位于 PV `/dev/nvme0n1p3` 开头（第一个 PE 之前）；
- LVM 自动维护；
- 不需要手工编辑。

### 4.2 `/etc/lvm/backup` 和 `/etc/lvm/archive`

```bash
# 当前 VG 元数据文本备份
ls -l /etc/lvm/backup/pve

# 历史归档
ls -l /etc/lvm/archive/pve_*.vg
```

- `/etc/lvm/backup/pve`：当前 VG 配置的文本备份；
- `/etc/lvm/archive/pve_*.vg`：每次 VG 变更的历史版本；
- 可以用 `vgcfgbackup` / `vgcfgrestore` 管理。

### 4.3 thin pool 元数据

- `data_tmeta`：thin pool 元数据；
- `pmspare` / `lvol0_pmspare`：元数据备用，用于修复；
- 元数据损坏会影响整个 thin pool，所以不要随意删除/修改。

---

## 5. VM 配置在哪里？

```text
/etc/pve/qemu-server/<vmid>.conf
```

例如：

```bash
cat /etc/pve/qemu-server/120.conf
```

其中：

```ini
scsi0: local-lvm:vm-120-disk-0,discard=on,iothread=1,size=40G,ssd=1
```

- `local-lvm`：存储 ID；
- `vm-120-disk-0`：卷名；
- `size=40G`：虚拟大小；
- `discard=on,ssd=1`：本次优化加的参数。

> `/etc/pve` 是 Proxmox 的 FUSE 文件系统（pmxcfs），不是普通磁盘目录；配置会在集群内同步。

---

## 6. 如何定位任意一台 VM 的磁盘

以 VM 120 为例：

```bash
# 1) 看配置
qm config 120 | grep -E '^(scsi|virtio|ide|sata)'
# scsi0: local-lvm:vm-120-disk-0,discard=on,iothread=1,size=40G,ssd=1

# 2) 卷 ID → 块设备路径
pvesm path local-lvm:vm-120-disk-0
# /dev/pve/vm-120-disk-0

# 3) 符号链接 → 真实 dm 设备
ls -l /dev/pve/vm-120-disk-0
# -> ../dm-26

# 4) 实际分配率
lvs -o lv_name,lv_size,data_percent pve/vm-120-disk-0

# 5) 谁在用
lsof /dev/pve/vm-120-disk-0
# 或
fuser -v /dev/pve/vm-120-disk-0

# 6) QEMU 命令行
qm showcmd 120 --pretty | grep -E 'file=|blockdev'

# 7) 设备树
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -A2 -B2 vm--120

# 8) 所有 VM 卷
pvesm list local-lvm
```

---

## 7. VM 磁盘的命名规则

| 名称 | 含义 |
|---|---|
| `vm-120-disk-0` | VM 120 的第 0 块磁盘 |
| `vm-120-disk-1` | VM 120 的第 1 块磁盘 |
| `vm-120-cloudinit` | VM 120 的 cloud-init ISO（4M） |
| `base-9010-disk-1` | 模板/基础卷 |
| `snap_vm-119-disk-0_before_resize` | VM 119 的快照卷 |

在 `local-lvm` 中，它们都是块设备：

```text
/dev/pve/vm-120-disk-0
/dev/pve/vm-120-cloudinit
/dev/pve/base-9010-disk-1
/dev/pve/snap_vm-119-disk-0_before_resize
```

---

## 8. thin pool 的设备关系

```text
pve-data-tpool（thin-pool 设备）
├─ pve-data（pool 自身的 data 设备，不是 VM 磁盘）
├─ pve-vm--120--disk--0
├─ pve-vm--122--disk--0
├─ pve-vm--116--disk--0
└─ ...

底层：
pve-data_tdata（数据）
pve-data_tmeta（元数据）
```

- `pve-data-tpool` 是 thin pool 的顶层设备；
- `pve-vm--*` 是 thin LV；
- `pve-data` 是 pool 的 data 设备，不是 VM 磁盘；
- `pve-data_tdata` / `pve-data_tmeta` 是 pool 的底层数据/元数据。

查看：

```bash
dmsetup ls --tree
dmsetup status pve-data-tpool
lvs -a -o lv_name,lv_size,segtype,pool_lv,devices pve
```

---

## 9. 常见误区

### 9.1 “VM 磁盘应该在 /var/lib/vz/images”

- 只有 `dir` 存储的 VM 磁盘才是文件（qcow2/raw）；
- `lvmthin` 存储的 VM 磁盘是块设备，不在 `/var/lib/vz/images`；
- 当前 `local` 的 content 只有 `vztmpl,iso,backup`，所以 `images` 目录为空。

### 9.2 “df / 应该能看到 VM 磁盘”

- `df /` 只看 `pve-root`；
- VM 磁盘在 `data` thin pool，是块设备；
- 用 `pvesm status`、`lvs` 看。

### 9.3 “du -sh / 应该很大”

- `du` 只统计文件；
- 块设备不计入 `du`；
- VM 磁盘的实际占用看 `lvs data%`。

### 9.4 “qemu-img info 显示 disk size: 0 B，是不是盘空了？”

- 不是；
- 对块设备，`qemu-img` 无法像文件那样统计分配；
- 看 `lvs -o data_percent` 或 `dmsetup status pve-data-tpool`。

### 9.5 “可以直接 rm /dev/pve/vm-120-disk-0 吗？”

**不可以。**

- 它是块设备，不是普通文件；
- 删除应通过 PVE：
  ```bash
  qm stop 120
  qm destroy 120 --destroy-unreferenced-disks 1
  # 或
  pvesm free local-lvm:vm-120-disk-0
  ```
- 直接 `rm` 不会正确释放 LVM 卷，可能留下元数据/设备映射。

### 9.6 “可以在宿主机 mount /dev/pve/vm-120-disk-0 吗？”

- 它是 guest 的文件系统（ext4/xfs/LVM），宿主机直接 mount 有风险；
- 只读排查也要非常谨慎；
- 一般通过 `qm`、`qemu-nbd`、备份工具处理。

---

## 10. 常用命令速查

### 10.1 查看存储与块设备

```bash
pvesm status
pvesm list local-lvm
cat /etc/pve/storage.cfg

lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
ls -l /dev/pve
dmsetup ls --tree
```

### 10.2 查看 VM 磁盘

```bash
qm config <vmid> | grep -E '^(scsi|virtio|ide|sata)'
pvesm path local-lvm:vm-<vmid>-disk-0
ls -l /dev/pve/vm-<vmid>-disk-0
lvs -o lv_name,lv_size,data_percent pve/vm-<vmid>-disk-0
qm showcmd <vmid> --pretty | grep -E 'file=|blockdev'
lsof /dev/pve/vm-<vmid>-disk-0
fuser -v /dev/pve/vm-<vmid>-disk-0
```

### 10.3 查看 thin pool

```bash
lvs -o lv_name,lv_size,data_percent,metadata_percent,chunk_size pve/data
dmsetup status pve-data-tpool
dmsetup table pve-data-tpool
```

### 10.4 查看 LVM 元数据

```bash
pvs
vgs
lvs
lvs -a -o lv_name,vg_name,lv_size,segtype,pool_lv,devices
vgcfgbackup -f /root/vg-pve-$(date +%F).vg pve
ls -l /etc/lvm/backup/pve /etc/lvm/archive/
```

### 10.5 查看 VM 运行进程

```bash
ps -ef | grep 'kvm -id <vmid>'
qm status <vmid>
qm showcmd <vmid> --pretty
```

---

## 11. 一句话总结

**PVE 的 `/` 只包含 96G 的 `pve-root`；虚拟机磁盘不在 `/` 里，而是 `local-lvm` 的 thin pool `data` 中的块设备 `/dev/pve/vm-<vmid>-disk-<n>`（真实节点 `/dev/dm-N`）。QEMU 用 `-drive file=/dev/pve/vm-...` 直接打开这些块设备运行 VM，所以 `df`/`du` 看不到它们，要用 `lvs`、`pvesm`、`lsblk`、`dmsetup`、`qm showcmd` 查看。**
