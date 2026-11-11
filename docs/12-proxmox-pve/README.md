# 12 · Proxmox VE 宿主机：LVM-thin、VM 磁盘与批量部署

这套 K8s/Ceph 全部跑在一台 Proxmox VE 宿主机上。**很多“K8s 存储问题”其实在宿主机层**：
thin pool 快满、VM 没开 discard、根分区被 NFS/ISO 占满、autoextend 空间不够。
这一章把 PVE 的存储概念、VM 磁盘位置、容量“甜点”和批量建机流程讲清楚。

> **IaC 实践子章节**：Terraform + cloud-init + Ansible 创建虚拟机、批量管理、接入现有 K8s 集群，
> 见 [iac/README.md](iac/README.md)。
>
> 更完整的存储基础（分区/LVM/RAID/文件系统/fstab/NFS/CSI/SMART）见
> [06 Storage 10-storage-basics](../06-storage-ceph/10-storage-basics.md)。

## 当时的情况

宿主机 `teacher`：

| 项 | 值 |
|---|---|
| Proxmox VE | `8.4.13`，内核 `6.8.12-15-pve` |
| 硬件 | Intel Xeon Gold 6138 ×2、64GB、931.5G NVMe |
| 网络 | `vmbr0` 192.168.67.156/24（管理/NAT）、`vmbr1` 10.0.0.1/24、`vmbr2` 172.16.1.1/16 |
| 存储 | `local`（dir，根分区）、`local-lvm`（lvmthin，thin pool `data`） |
| K8s | VM 119–124（3 control-plane + 3 worker） |
| Ceph | VM 116–118（ceph-01/02/03） |
| 其他 | VM 117 backup、VM 118 db01、VM 125–127 openEuler、模板 9000/9010 |

当时的问题：

- `df -h /` 看不到 VM 磁盘，误以为“磁盘没被占”；
- `local` 显示 100.86G、`local-lvm` 852.88G，单位/口径混乱；
- VG 只剩 16G，但 autoextend 配置是“到 70% 扩 20%”（约 159G），**根本扩不动**；
- VM 110–115 是旧 LB/Web 架构，无 vzdump 备份，删除前只留了一份 `qm config` 归档；
- 根分区上还放着 `/data/nfs`（Prometheus 21G），把 PVE OS 盘撑到 45G+；
- 新建 openEuler VM 时遇到 cloud-init、模板只读、Terraform provider 下载被墙等问题。

当前快照（2026-11-10）：thin pool 使用率 **65.62%**，VG 空闲 **16GiB**，`local` 使用率 **29.54%**。
完整命令输出见 [assets/pve-state/](assets/pve-state/)。

## 主要概念与原理

### 1. PV → VG → LV → PE

```text
/dev/nvme0n1p3                 PV（物理卷，930.51 GiB）
└─ VG pve                     卷组，统一管理 PE（4MiB）
   ├─ LV root        96 GiB   ext4 → /
   ├─ LV swap         8 GiB
   ├─ LV data       794.3 GiB thin pool
   │  ├─ data_tdata 794.3 GiB（数据）
   │  ├─ data_tmeta   8.1 GiB（元数据）
   │  ├─ pmspare      8.1 GiB（元数据备用）
   │  ├─ thin LV vm-119-disk-0
   │  └─ ...
   └─ VG 空闲 16 GiB
```

- **PV**：被 LVM 接管的磁盘/分区；
- **VG**：PV 组成的存储池；
- **LV**：从 VG 切出来的逻辑卷，可以是 linear 或 thin；
- **PE/LE**：PV/LV 上的固定大小块（本机 4MiB）。

### 2. PVE 的两种存储

| 存储 | 类型 | 路径 | 放什么 |
|---|---|---|---|
| `local` | dir | `/var/lib/vz` | ISO、模板、备份、snippets |
| `local-lvm` | lvmthin | thin pool `data` | VM 磁盘、容器 rootdir |

所以：

- VM 磁盘**不是** `/var/lib/vz/images` 下的文件，而是 `/dev/pve/vm-<id>-disk-0` 块设备；
- QEMU 用 `-drive file=/dev/pve/vm-...` 直接打开块设备；
- `du -sh /`、`df -h /` 看不到 VM 磁盘，这是正常的；
- 查看要用 `lvs`、`pvesm`、`lsblk`、`dmsetup`、`qm showcmd`。

### 3. Thin provisioning 与 discard/TRIM

- thin LV 的“虚拟大小”是声明值，`data%` 才是实际占用；
- 删除 VM 内文件，guest 文件系统不会自动把块还给 thin pool；
- 需要 VM 磁盘 `discard=on` + guest 周期性 `fstrim`（或 mount `discard`）；
- PVE 的 `local-lvm` 支持 discard，但默认新建磁盘不一定开。

### 4. autoextend 的陷阱

`/etc/lvm/lvm.conf`：

```conf
thin_pool_autoextend_threshold = 70
thin_pool_autoextend_percent = 20
```

含义：pool 到 70% 时，自动扩 20%（794.3G × 20% ≈ 159G）。
但 **VG 只剩 16G**，扩容必然失败；如果 pool 还带 `queue_if_no_space`，
写满后 VM 可能表现为 I/O 卡死，而不是立刻报 ENOSPC。

### 5. 容量“甜点”公式

```text
root = OS + 本地 ISO/备份 + 额外服务 + 20% 余量
VG 空闲 = max(3–5% VG, 一次 autoextend 的量)
data = VG - root - swap - tmeta - pmspare - VG 空闲
```

不是“root 越小越好”，也不是“VM 磁盘越多越好”，而是**给 autoextend 和快照留出真实可用的 VG 空间**。

### 6. cloud-init + 黄金模板 + Terraform + Ansible

openEuler 批量部署的链路：

```text
云镜像 qcow2
  → 注入 cloud-init（用户、SSH key、hostname）
  → 创建模板 VM（9010）
  → Terraform（bpg/proxmox）克隆 + 配置 CPU/内存/网络
  → cloud-init 首启
  → Ansible 统一配置
```

关键点：

- 模板基盘是只读的，注入前要临时改为可写，完成后再恢复；
- `virt-customize` 在 libguestfs 应用里的网关是 `169.254.2.2`，不是 `10.0.2.2`；
- `virt-customize` 会随机化 machine-id，之后要重新清空；
- Terraform provider 下载被墙时，可以用代理下载 zip 放进文件系统镜像目录。

## 踩坑点

### 坑 1：把 GB 和 GiB 混着算

PVE GUI 用十进制 GB，LVM 用 GiB。`local` 显示 100.86G ≈ 96GiB；
`local-lvm` 852.88G ≈ 794.3GiB。差 7% 左右，容量规划时不能直接相减。

### 坑 2：`df`/`du` 看不到 VM 磁盘

VM 磁盘是块设备，不在根文件系统里。`df -h /` 只反映 `pve-root` 的使用，
不能用来判断 thin pool 还剩多少。正确命令：

```bash
lvs -o lv_name,vg_name,lv_size,data_percent,metadata_percent pve/data
pvesm status
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
qm showcmd <vmid> --pretty | grep file=
```

### 坑 3：thin pool 是共享故障域

所有 VM 磁盘在同一个 `data` pool 里。一个 VM 写满，所有 VM 都可能 I/O 卡死；
这不是“某个 K8s Pod 的问题”，而是宿主机存储层故障。

**修复**：监控 `data_percent`/`metadata_percent`，在 70% 前处理；给关键 VM 单独池或限制。

### 坑 4：autoextend 空间不够，配了等于没配

threshold 70% + percent 20% 需要约 159G，但 VG 只剩 16G。
到阈值时 LVM 报错，pool 继续逼近 100%。

**修复**：扩 VG（加盘/扩分区）、调小 `thin_pool_autoextend_percent`（2–5%），
或把 autoextend 关掉改为人工扩容 + 告警。

### 坑 5：`queue_if_no_space` 让故障表现为“卡死”

thin pool 写满时，启用了 `queue_if_no_space` 的 DM 设备会挂起 I/O，而不是返回错误。
VM 内表现为文件系统卡住、K8s 节点 NotReady，很容易误判为网络/内核问题。

**修复**：保留一定余量；必要时用 `dmsetup suspend/resume` 或扩容恢复；
不要等到 100% 才处理。

### 坑 6：没开 discard，删了文件空间也不回来

VM 内删了 20G 日志，PVE thin pool 的 `data%` 不降。因为 guest 没有把块标记为 free。

**修复**：

```bash
qm set <vmid> --scsi0 <disk>,discard=on,ssd=1
# guest 内
fstrim -av
```

然后 `lvs` 观察 `data%` 是否下降。注意：discard 会增加 I/O，低负载时执行。

### 坑 7：模板基盘只读，cloud-init 注入失败

直接对模板的 base 卷执行 `virt-customize` 会失败。要先临时改为可写，完成后再恢复只读；
否则模板被改坏，所有克隆都受影响。

### 坑 8：`virt-customize` 的 libguestfs 网关不是 10.0.2.2

在 libguestfs 应用环境里访问宿主机 HTTP 服务，网关是 `169.254.2.2`。
写成 `10.0.2.2` 会连接超时，误以为 HTTP 服务没起。

### 坑 9：删除 VM 前没有备份

VM 110–115 删除前没有 vzdump，只留了 `qm config` 和磁盘布局记录。
配置可以重建，但磁盘里的数据无法恢复。

**修复**：删除前至少 `vzdump` 或 `qm disk export`；没有备份时，先归档 `qm config`、
MAC、UUID、磁盘大小、网络拓扑，并明确“数据不可恢复”。

## 修复关键

### 1. 先建立容量基线

```bash
pvs; vgs; lvs -a -o +data_percent,metadata_percent
pvesm status
df -hT
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,DISC-GRAN,DISC-MAX
grep -E 'thin_pool_autoextend' /etc/lvm/lvm.conf
```

本仓库脚本：

```bash
python3 docs/12-proxmox-pve/scripts/pve_storage_report.py
```

它会给出 VG 余量、thin pool 使用率，以及“autoextend 是否会失败”的判断。

### 2. 把非 OS 数据从根分区迁走

`/data/nfs`（Prometheus 21G）这类数据不应放在 `pve-root`。
迁到独立 LV/磁盘，或迁进 Ceph/NFS 专用 VM；根分区只留 PVE OS、ISO、备份。

### 3. 给 VG 留出真实余量

- 加盘/扩 PV，或缩容不用的 LV；
- 把 autoextend 调到 2–5%，并设置 70%/80% 告警；
- 关键 VM 磁盘不要超过 pool 的 80% 虚拟分配。

### 4. 开启 discard + 定期 fstrim

```bash
# 逐台（会 drain/关机）
bash docs/12-proxmox-pve/scripts/apply_discard.sh <vmid> <node> <ip>
```

脚本会备份 `qm config`、加 `discard=on,ssd=1`、drain、关机、开机、`fstrim`、uncordon。

### 5. 批量建机的可复现流程

- 云镜像校验（sha256）；
- 黄金模板只做一次，注入 cloud-init + qemu-guest-agent；
- Terraform 管 VM 规格/网络，Ansible 管 guest 内配置；
- 所有 VM 配置、MAC、UUID 归档到 Git；
- 删除前先备份，再删。

## 本目录文档

| 文档 | 内容 |
|---|---|
| [pve-lvm-storage-guide-2026-11-07.md](notes/pve-lvm-storage-guide-2026-11-07.md) | PV/VG/LV、local vs local-lvm、GB/GiB、常用命令 |
| [pve-vg-thinpool-analysis-2026-11-06.md](notes/pve-vg-thinpool-analysis-2026-11-06.md) | VG/thin pool 布局、容量甜点、autoextend 风险 |
| [pve-vm-disk-location-2026-11-07.md](notes/pve-vm-disk-location-2026-11-07.md) | VM 磁盘到底在哪：块设备、QEMU、lsof、dmsetup |
| [vm-110-115-archive.md](notes/vm-110-115-archive.md) | 旧 6 台 LB/Web VM 删除前的完整配置归档 |
| [openeuler-batch-deploy-2026-11.md](notes/openeuler-batch-deploy-2026-11.md) | Proxmox + cloud-init + Terraform + Ansible 批量部署 openEuler |
| [xceuler-repo-readme.md](notes/xceuler-repo-readme.md) | openEuler VM 仓库的目录、模板、用法与 gotchas |

## IaC 子教程

| 章节 | 内容 |
|---|---|
| [iac/README.md](iac/README.md) | 总览、边界、最短路径 |
| [01 Terraform](iac/01-terraform-proxmox.md) | API token、provider、state、克隆、plan/apply/destroy |
| [02 cloud-init](iac/02-cloudinit-golden-template.md) | 黄金模板、NoCloud、snippet、sysprep、guest-agent |
| [03 Ansible 基线](iac/03-ansible-baseline.md) | inventory、playbook、混合 OS、check/diff、灰度 |
| [04 K8s 节点](iac/04-k8s-node-baseline.md) | 内核、containerd、kubelet、join、Cilium |
| [05 批量管理](iac/05-batch-ops.md) | 安全重启、扩容、discard、巡检、销毁 |
| [06 故障排查](iac/06-troubleshooting.md) | 现象→根因→修复→验证 |
| [labs/](iac/labs/README.md) | 5 个可动手实验（含清理） |

## 配套资产

| 资产 | 说明 |
|---|---|
| [assets/pve-state/](assets/pve-state/) | 2026-11-10 的 pvesm/lvs/qm list/storage.cfg/lvm.conf 快照 |
| [assets/vm-configs/](assets/vm-configs/) | VM 110–115 归档配置、119–124 当前配置、discard 前备份 |
| [assets/xceuler/terraform/](assets/xceuler/terraform/) | openEuler 批量创建的 Terraform 配置（token 已脱敏） |
| [assets/xceuler/ansible/](assets/xceuler/ansible/) | inventory、playbook、ansible.cfg |
| [assets/iac/cloud-init/](assets/iac/cloud-init/) | K8s 节点 NoCloud user-data/meta-data 示例 |
| [assets/iac/ansible/](assets/iac/ansible/) | baseline / k8s-node / k8s-join playbook 与模板 |
| [assets/iac/reference/m01/](assets/iac/reference/m01/README.md) | 从 m01 采集的 sysctl/containerd/kubeadm/kubelet 实际配置 |
| [assets/xceuler/terraform/terraform.tfvars.k8s.example](assets/xceuler/terraform/terraform.tfvars.k8s.example) | 3 台 K8s 节点候选 VM 的 Terraform 变量示例 |
| [scripts/pve_storage_report.py](scripts/pve_storage_report.py) | 只读容量/风险报告 |
| [scripts/apply_discard.sh](scripts/apply_discard.sh) | 给 VM 加 discard 并 fstrim（会 drain/重启） |
| [scripts/create-k8s-vms.sh](scripts/create-k8s-vms.sh) | 早期 K8s 节点批量创建（cloud-init） |
| [scripts/create-lab-vms.sh](scripts/create-lab-vms.sh) | 实验 VM 批量创建（110–119） |
| [scripts/finish_worker01.sh](scripts/finish_worker01.sh) | worker01 discard + drain 的收尾脚本 |

```bash
# 容量报告（只读）
python3 docs/12-proxmox-pve/scripts/pve_storage_report.py

# VM 磁盘实际位置
qm showcmd 119 --pretty | grep -E 'file=|blockdev'
lvs -o lv_name,lv_size,data_percent,pool_lv pve | sort -k3 -nr

# discard（会中断节点，先确认已 drain）
bash docs/12-proxmox-pve/scripts/apply_discard.sh 122 worker01 10.0.0.122
```

> 本目录脚本含当时的 VMID、IP、节点名，执行前必须按你的环境修改。
> PVE 层操作不可逆，删除 VM/磁盘前先备份 `qm config` 和 `vzdump`。
