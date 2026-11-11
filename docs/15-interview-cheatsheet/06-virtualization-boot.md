# 06 · 虚拟化 / 云主机 / 引导面试题

> 详细证据：[12 Proxmox 10-kvm-qemu-virtio-cloud-boot](../12-proxmox-pve/10-kvm-qemu-virtio-cloud-boot.md)。

## 1. KVM/QEMU 与 virtio

**一句话**：KVM 提供 CPU 硬件虚拟化，QEMU 模拟设备/内存/磁盘；virtio 是半虚拟化驱动，减少全模拟开销。

**本环境**：PVE QEMU `9.2.0`、`/dev/kvm` 存在；K8s Guest `systemd-detect-virt=kvm`，`virtio_net`/`virtio_scsi`/`virtio_balloon`；Hyper-V Guest `microsoft`，`hv_netvsc`/`hv_storvsc`。

**追问**：`qm showcmd` 看真实 QEMU 参数；`iothread` 提升 virtio-scsi 并发。

## 2. virsh 是什么

**一句话**：`virsh` 是 **libvirt** 的 CLI，不是 KVM/QEMU 本身；PVE 用 `qm`，Hyper-V 用 PowerShell。

**本环境**：`virsh/libvirtd` 未安装、`libvirtd` inactive。

**追问**：`virsh list/dominfo/domblklist/domiflist/dumpxml/console`；PVE 对应 `qm list/config/terminal`。

## 3. 云主机 vs 物理机

**一句话**：云主机看不到真实 SMART、CPU/网卡是虚拟的、DMI 是虚拟的、可能有 steal time，硬件故障被宿主屏蔽。

**本环境**：KVM Guest `QEMU HARDDISK`/`virtio_net`；Hyper-V Guest `Virtual Disk`/`hv_netvsc`；`dmidecode` 显示 `QEMU`/`Microsoft Virtual Machine`；`smartctl` 未安装，虚拟盘通常无真实 SMART。

**追问**：`vmstat` 的 `st` 是 steal time；当前 0，但宿主超卖会升高。

## 4. IMDS 169.254.169.254 与 IMDSv2

**一句话**：云厂商元数据服务；IMDSv1 易被 SSRF 利用，IMDSv2 强制 PUT token + TTL + hop limit。

**本环境**：无 IMDS，所有 Guest `curl 169.254.169.254` 超时；`ip route get` 走网关。

**追问**：`HttpTokens=required`、`HttpPutResponseHopLimit=1`、限制 Pod 出站到 link-local。

## 5. cloud-init 调试

**一句话**：`cloud-init status --long` 看结果，`analyze show/blame` 看阶段耗时，`/var/log/cloud-init-output.log` 看命令输出。

**本环境**：201/202/worker `status: done`，datasource `NoCloud /dev/sr0`；201 首启 `package_update_upgrade_install` **121s**；m01 `degraded` + schema warning。

## 6. Packer 金镜像 → 不可变基础设施

**一句话**：Packer 构建一次镜像，运行期只注入 user-data，不再 SSH 改配置；变更 = 新镜像/新版本，回滚 = 换旧镜像。

**本环境**：未安装 Packer；金镜像由 `virt-customize` + PVE 模板 9010 手工构建。

**追问**：Packer + cloud-init + Terraform 的分工：镜像/首启/编排。

## 7. UEFI、Secure Boot、PXE、initramfs

**一句话**：UEFI+Secure Boot 校验引导链；PXE 走网络引导；initramfs 必须包含存储/文件系统驱动，否则换硬件后找不到 root。

**本环境**：K8s VM Legacy BIOS；openEuler 9010 UEFI 但 Secure Boot 关闭；Hyper-V Gen2 Secure Boot Off；KVM initramfs 有 `virtio_scsi`，Hyper-V 有 `hv_storvsc`，m01 有 `virtio_blk/scsi`；Hyper-V UEFI 有 EFI Network 启动项但本地盘优先。

**追问**：跨 KVM/Hyper-V 迁移要重建 initramfs；`lsinitramfs`/`lsinitrd` 检查驱动。

## 一句话总表

| 题 | 一句话 |
|---|---|
| KVM/QEMU | KVM 虚拟化 CPU，QEMU 模拟设备；virtio 半虚拟化 |
| virsh | libvirt CLI，不是 KVM 本身 |
| 云 vs 物理 | 无真实 SMART、虚拟网卡/CPU/DMI、可能有 steal |
| IMDSv2 | PUT token + TTL + hop limit，防 SSRF |
| cloud-init | status/analyze/log 三件套 |
| Packer | 不可变镜像，变更走新镜像 |
| 引导 | UEFI/Secure Boot/PXE/initramfs 驱动缺一不可 |
