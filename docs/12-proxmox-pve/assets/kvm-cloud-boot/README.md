# KVM / virtio / 云主机 / cloud-init / 引导证据

对应教程：[`../../10-kvm-qemu-virtio-cloud-boot.md`](../../10-kvm-qemu-virtio-cloud-boot.md)。

| 文件 | 内容 |
|---|---|
| `pve-kvm.txt` | QEMU 9.2.0、/dev/kvm、virsh/libvirtd 缺失、qm config/showcmd、UEFI/Legacy |
| `guest-m01.txt`、`guest-worker01.txt` | KVM Guest：virtio_net/scsi/balloon、QEMU HARDDISK、steal |
| `guest-gitlab-201.txt`、`guest-harbor-202.txt` | Hyper-V Guest：hv_netvsc、Virtual Disk、UEFI |
| `initramfs-*.txt` | KVM virtio_scsi、Hyper-V hv_storvsc、m01 virtio_blk/scsi |
| `boot-efi.txt` | KVM 无 EFI、Ubuntu Hyper-V UEFI、SecureBoot disabled、EFI 启动项 |
| `cloud-init-*.txt` | status/analyze/blame/datasource/output log |
| `imds-*.txt` | 169.254.169.254 超时、路由走网关（无 IMDS） |
| `packer-boot.txt` | Packer 未安装、Terraform 1.16.4、各 VM boot order |

## 关键结论

- PVE 用 QEMU 9.2.0 + KVM，`qm showcmd` 可见 virtio-scsi/balloon/serial；
- `virsh` 是 libvirt CLI，本环境未安装，PVE 用 `qm`；
- K8s Guest `kvm` + virtio；GitLab/Harbor Guest `microsoft` + hv_netvsc；
- Guest `smartctl` 未安装，虚拟盘通常无真实 SMART；
- `vmstat` steal 当前 0，但机制存在；
- 所有 Guest 访问 169.254.169.254 超时 → 无 IMDS；
- cloud-init：201 done、首启 apt 121s；m01 degraded schema warning；
- Packer 未安装，金镜像用 virt-customize + 模板 9010；
- K8s VM Legacy BIOS；9010 UEFI 但 Secure Boot 关闭；Hyper-V Gen2 Secure Boot Off；
- KVM initramfs 有 virtio_scsi，Hyper-V 有 hv_storvsc，换平台不重建 initramfs 会起不来。
