# 10 · KVM/QEMU、virtio、云主机差异、IMDS、cloud-init 与引导

> 这一章把“虚拟机底层”讲清楚：KVM/QEMU、virtio、virsh、云主机 vs 物理机、
> 169.254.169.254、cloud-init、Packer 金镜像、UEFI/Secure Boot/PXE/initramfs。
>
> 证据：[`assets/kvm-cloud-boot/`](assets/kvm-cloud-boot/README.md)。
> 一句话版本：[15 面试速查 06-virtualization-boot](../15-interview-cheatsheet/06-virtualization-boot.md)。

## 1. 本环境的两套虚拟化

| 平台 | 地址 | 虚拟化 | 典型 Guest |
|---|---|---|---|
| Proxmox VE `teacher` | 192.168.67.156 | KVM + QEMU 9.2.0 | K8s 6 节点、Ceph 3 节点 |
| Windows 10 Pro `SYZX-HY2-TX` | 192.168.67.110 | Hyper-V | ubuntu01/02（GitLab/Harbor） |

```text
PVE:      qm / pvesh  → QEMU/KVM → virtio 设备
Hyper-V:  PowerShell  → Hyper-V → hv_netvsc / hv_storvsc
libvirt:  virsh       → libvirt → QEMU/KVM（本环境未安装）
```

## 2. KVM/QEMU

### 2.1 本机版本

```text
$ qemu-system-x86_64 --version
QEMU emulator version 9.2.0 (pve-qemu-kvm_9.2.0-7)

$ ls -l /dev/kvm
crw-rw---- 1 root kvm 10, 232 ... /dev/kvm
```

- `/dev/kvm` 存在 = 硬件虚拟化可用；
- QEMU 进程负责模拟设备、内存、CPU；KVM 负责 CPU 硬件虚拟化；
- PVE 的 `qm` 只是 QEMU 的封装，不是另一种虚拟化。

### 2.2 `qm showcmd` 看真实 QEMU 参数

```bash
qm showcmd 119 --pretty | head -40
```

关键片段：

```text
/usr/bin/kvm -id 119 -name 'm01,debug-threads=on'
-cpu qemu64,+abm,+aes,+avx,+avx2,+bmi1,+bmi2,enforce,+f16c,+fma,...
-m 6144
-object 'iothread,id=iothread-virtioscsi0'
-device 'virtio-scsi-pci,id=virtioscsi0,bus=pci.3,addr=0x1,iothread=iothread-virtioscsi0'
-device 'virtio-balloon-pci,...free-page-reporting=on'
-device 'virtio-serial,...'
```

说明：

- `-cpu qemu64,+avx2...` 是 PVE 对 `x86-64-v3` 的展开；
- `virtio-scsi-pci` + `iothread` 是磁盘高性能路径；
- `virtio-balloon` 用于内存气球；
- `virtio-serial` 通常给 qemu-guest-agent。

### 2.3 virsh 是什么，本环境为什么没有

`virsh` 是 **libvirt** 的 CLI，不是 KVM/QEMU 本身：

```text
$ which virsh libvirtd
virsh not found
libvirtd not found
$ systemctl is-active libvirtd
inactive
```

Proxmox 不用 libvirt，所以没有 `virsh`；Hyper-V 也不用。
通用 libvirt 主机才用：

```bash
virsh list --all
virsh dominfo <domain>
virsh domblklist <domain>
virsh domiflist <domain>
virsh dumpxml <domain>
virsh console <domain>
virsh start/shutdown/reboot <domain>
```

对应关系：

| 操作 | PVE | Hyper-V | libvirt |
|---|---|---|---|
| 列表 | `qm list` | `Get-VM` | `virsh list --all` |
| 配置 | `qm config <id>` | `Get-VM`/`Get-VMProcessor` | `virsh dumpxml` |
| 开关机 | `qm start/shutdown` | `Start-VM/Stop-VM` | `virsh start/shutdown` |
| 控制台 | `qm terminal` | `VMConnect` | `virsh console` |
| 磁盘 | `qm config`/`lvs` | `Get-VMHardDiskDrive` | `virsh domblklist` |

> 面试里说“用 virsh 管 KVM”没错，但要说清它是 libvirt 的工具；PVE/Hyper-V 不用它。

## 3. virtio 驱动

### 3.1 KVM Guest

worker01：

```text
$ systemd-detect-virt
kvm

$ lspci | grep -i virtio
00:03.0 Virtio memory balloon
00:08.0 Virtio console
00:12.0 Virtio network device
00:13.0 Virtio network device
01:01.0 Virtio SCSI

$ ethtool -i eth0
driver: virtio_net
version: 1.0.0
bus-info: 0000:00:12.0

$ lsblk -o NAME,MODEL
sda QEMU HARDDISK
```

### 3.2 Hyper-V Guest

201：

```text
$ systemd-detect-virt
microsoft

$ ethtool -i eth0
driver: hv_netvsc

$ lsblk -o NAME,MODEL
sda Virtual Disk

$ dmidecode -s system-product-name
Virtual Machine
$ dmidecode -s system-manufacturer
Microsoft Corporation
```

### 3.3 virtio 为什么快

- **virtio-net**：半虚拟化网卡，Guest 和 Host 共享 ring，减少全模拟设备开销；
- **virtio-scsi**：半虚拟化 SCSI，配合 `iothread` 提升磁盘并发；
- **virtio-balloon**：动态内存回收；
- **virtio-serial**：guest-agent 通道；
- 对比全模拟 `e1000`/`ide`，virtio 的 CPU 开销更低、吞吐更高。

### 3.4 驱动必须在 initramfs 里

worker01 initramfs：

```text
virtio_blk.ko
virtio_net.ko
virtio_scsi.ko
hv_vmbus.ko
hv_netvsc.ko
hv_storvsc.ko
xfs.ko
```

201（Hyper-V）initramfs：

```text
hv_vmbus.ko.zst
hv_netvsc.ko.zst
hv_storvsc.ko.zst
xfs.ko.zst
fsck.ext4
```

m01（Rocky/KVM）：

```text
virtio_blk.ko.xz
virtio_net.ko.xz
virtio_scsi.ko.xz
xfs.ko.xz
```

> 如果把磁盘从 KVM 挪到 Hyper-V（或反过来），initramfs 里没有对应
> `virtio_scsi`/`hv_storvsc`，内核在挂载 root 前就找不到磁盘，表现为
> `Unable to mount root fs` / emergency shell。

## 4. 云主机 vs 物理机：你能看到/改到什么

| 维度 | 物理机 | 云主机/VM |
|---|---|---|
| 磁盘 SMART | `smartctl` 可读 | 通常看不到真实 SMART，虚拟盘不直通 |
| CPU | 真实型号/频率 | QEMU/Hyper-V 虚拟 CPU 型号，可能屏蔽 flag |
| 网卡 | `ethtool -i` 真实驱动 | `virtio_net`/`hv_netvsc`，不能改物理链路 |
| DMI | 真实厂商/序列号 | `QEMU`/`Microsoft Virtual Machine` |
| steal time | 无 | `vmstat` 的 `st` 可能 >0（宿主超卖/争抢） |
| 硬件故障 | 直接可见 | 由宿主/云平台屏蔽，Guest 只看到 I/O 错误 |

本环境：

```text
KVM guest:      systemd-detect-virt=kvm, QEMU HARDDISK, virtio_net
Hyper-V guest:  systemd-detect-virt=microsoft, Virtual Disk, hv_netvsc
```

`vmstat` 的 `st` 当前为 0；但在 CPU 超卖/宿主繁忙时会升高。
Guest 里 `smartctl` 未安装，即使安装也通常读不到虚拟盘的真实 SMART。

> 云主机上“磁盘坏了”往往只能看到 `dmesg` 的 `medium error`/`I/O error`，
> 真正的 SMART 要在宿主机/云厂商侧看。

## 5. 实例元数据 169.254.169.254 与 IMDSv2

### 5.1 它是什么

云厂商在 Guest 内提供 `169.254.169.254` 的元数据服务，返回实例 ID、IAM 凭据、user-data 等。

```bash
# IMDSv1（不安全，容易被 SSRF 利用）
curl http://169.254.169.254/latest/meta-data/
curl http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

### 5.2 IMDSv2：强制 token

```bash
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")

curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id
```

防护点：

- 强制 `HttpTokens=required`（禁用 IMDSv1）；
- `HttpPutResponseHopLimit=1`（容器内拿不到宿主 token）；
- 限制 Pod/容器出站到 `169.254.169.254`；
- 不要把 IMDS 凭据写进日志/环境变量。

### 5.3 本环境有没有 IMDS

没有。所有 Guest 访问都超时：

```text
$ curl -m 2 http://169.254.169.254/latest/meta-data/
curl: (28) Connection timed out after 2002 milliseconds

$ ip route get 169.254.169.254
169.254.169.254 via 192.168.67.1 dev eth0 ...
```

说明这是 PVE/Hyper-V 自建环境，不是公有云；IMDS 相关内容只用于云上/面试。

## 6. cloud-init 调试与 Packer 金镜像

### 6.1 cloud-init 状态

201：

```text
$ cloud-init status --long
status: done
detail: DataSourceNoCloud [seed=/dev/sr0]
errors: []
```

m01：

```text
status: done
extended_status: degraded done
WARNING: cloud-config failed schema validation!
```

worker01 / harbor202：`status: done`。

### 6.2 `cloud-init analyze`

201：

```text
$ cloud-init analyze blame
121.29200s (modules-final/config-package_update_upgrade_install)
  0.38700s (init-network/config-growpart)
  0.19300s (init-network/config-resizefs)
```

说明首启慢主要是 **apt 包更新/安装**，不是 cloud-init 本身。

### 6.3 调试命令

```bash
cloud-init status --long
cloud-init analyze show
cloud-init analyze blame
cloud-init query --all
cloud-init schema --system
tail -100 /var/log/cloud-init-output.log
journalctl -u cloud-init --no-pager
```

### 6.4 Packer 金镜像 → 不可变基础设施

本环境最初没有 Packer；现已安装 **Packer 1.16.2 + packer-plugin-proxmox 1.2.4**。
历史金镜像由 `virt-customize` + PVE 模板 9010 手工构建（见 [02 cloud-init](iac/02-cloudinit-golden-template.md)），
Packer 示例已通过 `packer fmt/validate`，但尚未执行完整 build。

Packer 化的目标：

```text
Packer 构建一次镜像
  → 注入 cloud-init/qemu-guest-agent
  → 固化 OS/驱动/安全基线
  → 产出不可变镜像/模板
  → 运行期只注入 user-data，不再 SSH 改配置
```

对比：

| 方式 | 变更方式 | 可复现 | 回滚 |
|---|---|---|---|
| 手工/Ansible 长期改 | SSH 进去改 | 差 | 靠备份 |
| Packer 金镜像 | 改 Packer 模板重新构建 | 强 | 换回旧镜像 |
| 容器 | 改镜像 | 强 | 换回旧 tag |

> 不可变基础设施的核心不是“Packer”这三个字，而是**运行实例不再被手工修改**，
> 所有变更都通过新镜像/新版本发布。

## 7. 云镜像 vs 普通 ISO 做模板

### 7.1 结论：本环境两者都是云镜像

| 对象 | 来源 | 证据 |
|---|---|---|
| PVE openEuler 模板 9010 | openEuler 24.03 LTS SP4 **qcow2 云镜像** | 40GiB qcow2、ext4 rootfs、`/etc/cloud/cloud.cfg`、`citype: nocloud`、cloud-init 盘 `scsi1` |
| Hyper-V ubuntu01/02 | Ubuntu 24.04 **cloud image** | `/etc/cloud/build.info` = `server/20260826`、`LABEL=cloudimg-rootfs`、无 `/var/log/installer`、NoCloud seed `/dev/sr0` |

PVE 模板 9010：

```text
$ qemu-img info openEuler-...qcow2
virtual size: 40 GiB
disk size: 2.86 GiB

$ virt-filesystems ...
/dev/sda1 vfat 2.0G
/dev/sda2 ext4 rootfs 37G

$ virt-cat ... /etc/cloud/cloud.cfg
disable_root: true
ssh_pwauth: false
resize_rootfs_tmp: /dev
```

Hyper-V ubuntu01：

```text
$ cat /etc/cloud/build.info
build_name: server
serial: 20260826

$ cat /etc/fstab
LABEL=cloudimg-rootfs / ext4 discard,commit=30,errors=remount-ro 0 1

$ ls /var/log/installer
No such file or directory

$ cloud-init query platform
nocloud
```

> `/var/log/installer` 不存在 + `cloudimg-rootfs` + `build.info`，是“云镜像”而不是 ISO 安装的强证据。
> ISO 安装通常会留下 installer/anaconda 日志、安装器生成的分区/用户/主机密钥。
>
> 完整证据与对比：[`assets/kvm-cloud-boot/cloud-image/README.md`](assets/kvm-cloud-boot/cloud-image/README.md)。

### 7.2 云镜像和 ISO 模板的区别

| 维度 | 云镜像（qcow2/vhdx） | 普通 ISO 安装成模板 |
|---|---|---|
| 本质 | 已装好的磁盘镜像 | 安装介质，需要跑安装器 |
| 首次启动 | cloud-init 注入用户/网络/SSH | 安装器交互/自动应答（preseed/kickstart） |
| 默认用户 | 镜像内置（如 `ubuntu`/`cloud-user`），通常禁 root | 安装时创建 |
| 分区 | 镜像预定义（GPT/BIOS boot/EFI/root） | 安装器按配置生成（LVM/xfs/ext4 可选） |
| 速度 | 克隆即用，秒级 | 安装 10–30 分钟 |
| 可复现 | 强（镜像 digest/版本） | 依赖安装器/网络/应答文件 |
| 定制 | cloud-init + 首次启动 | 安装时选包、分区、驱动 |
| 不可变 | 天然适合（Packer 构建后不改） | 需要额外 sysprep/清理 |
| 诊断 | `build.info`、`cloudimg-rootfs`、无 installer log | `/var/log/installer`、anaconda、安装器日志 |
| 适用 | 云/虚拟化批量、弹性扩缩 | 需要特殊分区/包/硬件的模板 |

### 7.3 本环境安装/验证工具

已在 PVE 宿主安装并测试：

```text
qemu-img 9.2.0
libguestfs 1.48.2（virt-customize/virt-filesystems/guestfish）
cloud-localds（cloud-image-utils 0.33）
Packer 1.16.2 + packer-plugin-proxmox 1.2.4
```

测试：

```bash
# 读云镜像
qemu-img info openEuler-...qcow2
virt-filesystems -a openEuler-...qcow2 --all --long -h
virt-cat -a openEuler-...qcow2 /etc/cloud/cloud.cfg

# 生成 NoCloud seed（user-data/meta-data → cidata ISO）
cloud-localds seed.iso user-data.yaml meta-data.yaml
file seed.iso        # ISO 9660 'cidata'
isoinfo -l -i seed.iso

# Packer 模板语法
packer fmt -check packer-proxmox.pkr.hcl
packer validate packer-proxmox.pkr.hcl
```

Packer 示例：[`assets/kvm-cloud-boot/cloud-image/packer-proxmox.pkr.hcl`](assets/kvm-cloud-boot/cloud-image/packer-proxmox.pkr.hcl)
（`proxmox-clone` 从模板克隆，`packer validate` 已通过）。

### 7.4 为什么“云镜像 ≠ 普通 ISO”

- 云镜像已经包含分区表、bootloader、内核、initramfs、cloud-init；
- ISO 只是安装介质，必须经过 installer 才变成磁盘；
- 云镜像首启靠 **metadata/user-data**，ISO 模板靠 **安装器应答文件**；
- 云镜像默认用户/SSH key 由 cloud-init 注入，ISO 模板用户由安装器创建；
- 把 ISO 安装的机器当“云镜像”用，必须手动装 cloud-init、清 machine-id/SSH key、配 NoCloud。

## 8. 引导细节：UEFI、Secure Boot、PXE、initramfs

### 7.1 本环境的引导方式

| 对象 | 引导 | Secure Boot |
|---|---|---|
| K8s 节点 119–124 | Legacy BIOS（无 `/sys/firmware/efi`） | 不适用 |
| openEuler 模板 9010 | UEFI（`bios: ovmf`） | **关闭**（`pre-enrolled-keys=0`） |
| Hyper-V ubuntu01/02 | UEFI Gen2 | **Off** |
| PVE 宿主 | UEFI（`/boot/efi`） | 未验证 |

```text
$ qm config 119
boot: order=scsi0;ide2
# 无 bios/efidisk0 → 默认 SeaBIOS

$ qm config 9010
bios: ovmf
efidisk0: ...,pre-enrolled-keys=0
```

Hyper-V：

```text
SecureBoot Off
BootOrder: 0004,0000,0001,0002
Boot0000* EFI Network
Boot0001* EFI SCSI Device
...
```

### 7.2 PXE/网络引导

- K8s VM `boot: order=scsi0;ide2`，没有 `net0`，不走 PXE；
- Hyper-V 的 UEFI 启动项里有 `EFI Network`，但 BootOrder 第一是本地磁盘；
- PXE 需要 DHCP/TFTP/HTTP boot server + 网卡 PXE ROM；本环境没有专门 PXE 服务。

### 7.3 initramfs 缺驱动的真实风险

- KVM initramfs 有 `virtio_scsi`；
- Hyper-V initramfs 有 `hv_storvsc`；
- 如果把 KVM 磁盘直接挂到 Hyper-V，而 initramfs 没有 `hv_storvsc`，
  内核在启动早期找不到 root 磁盘，进入 emergency shell；
- 解决：重建 initramfs（`update-initramfs -u`/`dracut -f`），或保留通用驱动。

```bash
# Ubuntu
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'virtio|hv_|xfs|ext4'
# Rocky
lsinitrd /boot/initramfs-$(uname -r).img | grep -E 'virtio|hv_|xfs|ext4'
```

## 9. 一页命令

```bash
# KVM/QEMU
qemu-system-x86_64 --version
ls -l /dev/kvm
qm showcmd 119 --pretty
qm config 119 | grep -E 'bios|boot|scsi|efidisk'

# Guest 虚拟化识别
systemd-detect-virt
lscpu | grep -E 'Hypervisor|Virtualization'
lspci | grep -i virtio
ethtool -i eth0
lsblk -o NAME,MODEL
dmidecode -s system-product-name
vmstat 1 3

# IMDS
curl -m 2 -D- http://169.254.169.254/latest/meta-data/
ip route get 169.254.169.254

# cloud-init
cloud-init status --long
cloud-init analyze show
cloud-init analyze blame
tail -100 /var/log/cloud-init-output.log

# 引导/initramfs
ls -d /sys/firmware/efi
bootctl status
efibootmgr -v
mokutil --sb-state
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'virtio|hv_|xfs|ext4'
```
