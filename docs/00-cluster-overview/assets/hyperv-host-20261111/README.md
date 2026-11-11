# Hyper-V 宿主 SYZX-HY2-TX（192.168.67.110）

> 用户口中的“全息服务器”；实际是 Windows 10 Pro + Hyper-V 宿主。
>
> 采集时间：2026-11-11 10:13 CST  
> 采集方式：`ssh tfadmin@192.168.67.110` + PowerShell 只读命令。  
> 密码不入库；只记录管理账号和主机信息。

## 1. 这是什么

之前文档把 `192.168.67.201/202` 写成“宿主机”，实际它们是 **Windows Hyper-V 上的 Ubuntu 虚拟机**：

```text
Windows 10 Pro 宿主 SYZX-HY2-TX  192.168.67.110
├─ ubuntu01  Running  192.168.67.201  GitLab CE 19.4
├─ ubuntu02  Running  192.168.67.202  Harbor 2.14.5
├─ ubuntu03  Off
└─ kali-linux-2026.2  Off
```

管理入口：`tfadmin@192.168.67.110`（Windows，默认 shell 是 PowerShell）。

## 2. 宿主硬件

| 项 | 值 |
|---|---|
| 主机名 | `SYZX-HY2-TX` |
| OS | Windows 10 专业版 `10.0.19045`（不是 Windows Server） |
| 主板 | MSI `MS-7E06`（Z790 GAMING PLUS WIFI） |
| CPU | Intel Core i7-14700KF，20C/28T，3.4GHz |
| 内存 | 32GB（2×16GB Micron DDR5-5600） |
| 系统盘 | ZHITAI TiPlus7100 1TB NVMe，**MBR** |
| GPU | NVIDIA RTX 5070（另有 Parsec/Todesk 虚拟显示） |
| 启动时间 | 2026-11-05 14:04:44 |
| C: | 137GB，剩 51GB |
| D: | 886GB，剩 296GB |
| Hyper-V 路径 | `D:\HyperV\VMs`、`D:\HyperV\VirtualHardDisks` |

## 3. Hyper-V 虚拟机

| VM | 状态 | vCPU | 内存 | VHDX | 实际文件 | Guest 根盘 | 备注 |
|---|---|---:|---:|---|---:|---|---|
| ubuntu01 | Running | 2 | 8GB | `ubuntu01-fresh.vhdx` | 62.7GB / 85GB | 77G 用 50G（66%） | GitLab 201 |
| ubuntu02 | Running | 2 | 6GB | `ubuntu02-fresh.vhdx` | 39.4GB / 64GB | 58G 用 33G（57%） | Harbor 202 |
| ubuntu03 | Off | 2 | 4GB | `ubuntu03-fresh.vhdx` | 8.2GB / 53.7GB | - | 未使用 |
| kali-linux-2026.2 | Off | 4 | 4GB | `.avhdx` | - | - | 有 2 个检查点 |

> ubuntu01/02 是 **Ubuntu 24.04 cloud image**（`/etc/cloud/build.info` = `server/20260826`，
> 根文件系统 `LABEL=cloudimg-rootfs`，无 `/var/log/installer`），不是 ISO 安装。
> 对比见 [12 KVM/云镜像](../../../12-proxmox-pve/assets/kvm-cloud-boot/cloud-image/README.md)。

- 全部 Generation 2；
- Secure Boot：**Off**；
- `DynamicMemoryEnabled`：ubuntu01/02 为 **False**（固定内存），kali 为 True；
- ubuntu01/02 **没有检查点**（只有 kali 有 2 个）；
- 集成服务：心跳/时间同步/VSS 为 True，Guest Service Interface 为 False，
  Key-Value Pair Exchange 显示“无连接”。

## 4. 网络

```text
Host: vEthernet (Terraform-Lab-External) 192.168.67.110/24
      WLAN 192.168.67.10/24
      Tailscale 100.74.67.100/32
Switch: Terraform-Lab-External (External, Intel I226-V)
VMs: ubuntu01 00155D436E1A, ubuntu02 00155D436E19 (same switch)
```

注意：

- 宿主同时有 **有线 192.168.67.110** 和 **Wi-Fi 192.168.67.10**；
- 默认路由走 **WLAN（metric 0）**，有线是 metric 256；
- 这意味着宿主出站可能走 Wi-Fi，VM 走有线，存在**非对称路径/单点**风险。

## 5. 服务与健康

```text
vmms        Running Automatic
vmcompute   Running Manual
sshd        Running Automatic
TermService Running Manual
Microsoft-Hyper-V-All Enabled
OpenSSH.Server capability NotPresent（但 sshd 服务在跑，属于 Win32-OpenSSH）
```

最近 7 天系统错误：

- `Microsoft-Windows-TPM-WMI 1796`：安全启动变量更新失败（反复出现）；
- `Service Control Manager 7000/7031`：OpenSSH SSH Server 启动/意外终止；
- `Server 2505`：NetBT 名称冲突；
- `RustDesk Service` 启动超时。

这些不是当前业务故障，但属于宿主层噪声/风险。

## 6. 风险与建议

1. **单台 Windows 10 Pro 宿主**：未安装 Failover Clustering 管理工具（`Get-Cluster` 不存在），
   按单机 Hyper-V 管理；没有证据表明配置了 Live Migration/集群。宿主重启 = GitLab/Harbor 同时不可用。
2. **201/202 是 VM，不是物理机**：容量、快照、备份、网络都要按 Hyper-V 层管理。
3. **ubuntu01/02 没有检查点**：升级 GitLab/Harbor 前应先做 Hyper-V Checkpoint 或应用级备份。
4. **默认路由走 WLAN**：建议把有线设为更低 metric，或至少确认 192.168.67.0/24 的路由稳定。
5. **Hyper-V 宿主也是 Windows 10 客户端**：不适合作为长期生产宿主；建议 Windows Server + 集群/备份。
6. **TPM/Secure Boot 更新错误**：不影响当前运行，但应修掉，避免后续安全启动更新失败。

## 7. 证据

| 文件 | 内容 |
|---|---|
| [`collect.txt`](collect.txt) | 宿主硬件、磁盘、网络、VM、检查点、集成服务、服务、最近错误 |
| [`vhd.txt`](vhd.txt) | ubuntu01/02/03 的 VHDX 路径、类型、文件大小、虚拟大小 |
| [`../../scripts/collect_hyperv_evidence.ps1`](../../scripts/collect_hyperv_evidence.ps1) | 只读采集脚本 |

> Windows PowerShell 的 `Get-VHD` 不支持 `-VMName`，所以 VHDX 明细用
> `Get-VMHardDiskDrive` + `Get-VHD -Path` 单独采集，见 `vhd.txt`。

## 8. 对旧文档的修正

- `192.168.67.201/202` 应描述为 **Hyper-V VM `ubuntu01`/`ubuntu02`**；
- 宿主是 `SYZX-HY2-TX 192.168.67.110`，不是 201/202；
- GitLab/Harbor 的故障排查要同时看：
  - Guest：Ubuntu 24.04 内的 systemd/Docker/应用；
  - Hyper-V：VM 状态、VHDX、虚拟交换机、宿主磁盘/内存/网络。
