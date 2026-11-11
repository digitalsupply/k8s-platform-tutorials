# 存储基础证据（2026-11-11）

对应教程：[`../../10-storage-basics.md`](../../10-storage-basics.md)。

| 文件 | 内容 |
|---|---|
| `pve-host.txt` | PVE `lsblk`/`blkid`/`parted`/fstab/findmnt/mdstat/LVM/dmesg/SMART |
| `m01.txt` | m01 MBR、XFS、fstab、mdstat、NFS、dmesg |
| `worker01.txt` | worker GPT、ext4、RBD、fstab、mdstat、dmesg |
| `gitlab-201.txt`、`harbor-202.txt` | Ubuntu 24.04 ext4、LABEL/UUID fstab、overlay |
| `device-links.txt` | `/dev/disk/by-uuid`、`by-id`、udev 属性 |
| `lvm-thin.txt` | thin pool `Data%`、VG 空闲、autoextend |
| `nfs.txt` | NFS PV spec、worker03 NFSv4.2 挂载参数 |
| `ceph-status.txt` | `ceph -s`、`ceph pg stat`、`ceph osd tree`、`ceph df detail` |
| `csi-pv-pvc.txt` | StorageClass、PV/PVC accessModes、CSIDriver |
| `dmesg-medium-errors.txt` | 所有主机 medium/I/O error 扫描（当前为空） |

## 关键结论

- PVE：GPT、NVMe、LVM-thin 66.35%、VG 空闲 16G、autoextend 需要 158.9G；
- m01：MBR、XFS；
- worker：GPT、ext4、Ceph RBD `rbd4/rbd6`；
- NFS：NFSv4.2 `hard,timeo=600,retrans=2`；
- Ceph：HEALTH_OK，6 OSD up/in，465 PG active+clean；
- CSI：17 个 PV 全部 `ReadWriteOnce`；
- SMART：0% used、0 media errors、7 unsafe shutdowns；
- dmesg：当前无 medium error。

> 云盘（gp2/gp3）本环境没有，相关结论只讲通用原理，未做真机验证。
