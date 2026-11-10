# K8s Worker 节点磁盘在线扩容记录（+10G × 3）

- 执行时间：2026-10-28
- 执行人：OpenCode（root@m01）
- 目标：worker01 / worker02 / worker03 系统盘各增加 10G
- 结果：**已完成，全程在线操作，节点未关机、未重启、未 drain，Pod 无中断**

---

## 一、结论

| 节点 | PVE VMID | 虚拟盘 | 扩容前 / | 扩容后 / | 可用空间变化 | 节点状态 |
|---|---|---|---|---|---|---|
| worker01 | 122 | scsi0 | 50G | **60G** | 12G → 22G | Ready，uptime 未变 |
| worker02 | 123 | scsi0 | 50G | **60G** | 8.2G → 17.6G | Ready，uptime 未变 |
| worker03 | 124 | scsi0 | 50G | **60G** | 19G → 28.4G | Ready，uptime 未变 |

- 虚拟磁盘精确增加 **10 GiB**；LVM LV 由 12287 extents → 14847 extents（+10240 MiB，正好 10 GiB）。
- 文件系统总容量约 46.9 GiB → 56.9 GiB（`df -h` 显示 48G → 57G，属四舍五入显示差异）。
- 三个 worker 的 `uptime` 仍为 4 周 2 天，`kubelet` 均 active，说明**没有重启**。
- 节点上无 I/O 错误（`dmesg` 无 error/fail）。

> 说明：worker 的系统盘是 PVE 上的虚拟盘（virtio-scsi），不是物理直通盘，因此扩容分为两层：
> ① PVE 侧扩大虚拟块设备（在线）；② Guest 内扩大分区 → PV → LV → ext4（全部支持在线）。

---

## 二、环境事实

- PVE 宿主机：`10.0.0.1:8006`（node `teacher`，PVE 8.4.13）
- 存储：`local-lvm`（thin pool），执行前已用 72.5%，剩余约 229 GiB；本次共新增 30 GiB，充足
- Guest OS：Ubuntu 22.04.5 LTS
- 磁盘布局（三台一致，GPT）：
  - `sda1` 1M：BIOS boot
  - `sda2` 2G：ext4 `/boot`
  - `sda3` 48G：LVM PV → `ubuntu-vg/ubuntu-lv` → ext4 `/`
- 三台 VM 均**无快照**（`qm listsnapshot` 只有 current），排除了“带快照扩容后回滚不一致”的风险。

---

## 三、执行步骤（可复用）

对每台 worker 依次执行，单台耗时约 10 秒：

### 1) PVE 侧在线扩大虚拟磁盘

```bash
# 在 PVE 宿主机 10.0.0.1 上
qm resize 122 scsi0 +10G   # worker01
qm resize 123 scsi0 +10G   # worker02
qm resize 124 scsi0 +10G   # worker03
```

`qm resize` 对运行中的 virtio-scsi 磁盘生效，无需关机。

### 2) Guest 内重扫设备并逐层扩容

```bash
# 在对应 worker 上
echo 1 > /sys/class/block/sda/device/rescan    # 让内核识别新容量
sleep 2

growpart /dev/sda 3        # 扩大 sda3 到磁盘末尾（在线，自动搬移 GPT 备份头）
partprobe /dev/sda

pvresize /dev/sda3         # 扩大 PV
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
resize2fs /dev/ubuntu-vg/ubuntu-lv              # ext4 在线扩容

df -hT /
```

关键点：ext4 和 LVM 都支持挂载状态下扩容；`growpart` 对已挂载分区同样安全，因此**不需要重启或停机**。

---

## 四、验证结果

```
worker01  57G  34G  22G  61%  /
worker02  57G  37G  18G  68%  /
worker03  57G  26G  29G  48%  /
```

```bash
kubectl get nodes          # 3 个 worker 全部 Ready
systemctl is-active kubelet # active
uptime -p                  # 4 weeks, 2 days ...（未重启）
```

Pod 方面仅存在历史 `Completed` 的 Job Pod，无新增异常。

---

## 五、注意事项

1. **PVE thin pool 超配警告**：`qm resize` 时提示 “Sum of all thin volume sizes exceeds the size of thin pool”。这是该环境**扩容前就存在**的 thin 超配（1.20 TiB 逻辑卷 vs 930 GiB 池），本次只是各增加 10 GiB。当前池实际使用 72.5%，仍有余量；但后续继续扩容前应先确认 `pvesm status` 的 Available。
2. **不要用快照回滚**来“撤销”本次扩容：LV 已变大，回滚旧快照会与当前磁盘尺寸不一致。如需回退，只能 Guest 内缩容（ext4 不支持在线缩小，必须离线），因此本次按只增不减处理。
3. `/boot`（sda2）保持 2G 未动，符合预期；本次扩的是根分区。
4. 该环境为单台 PVE 上的实验集群，所有 VM 共享同一物理机，扩容不改变单点风险。

---

## 六、回滚说明（一般不需要）

文件系统扩容是单向的。若确需回退 10G：需停机，用 Live ISO 先 `resize2fs` 缩小 ext4，再 `lvreduce`、`pvresize --setphysicalvolumesize`、`growpart` 反向调整，最后 `qm resize scsi0 -10G`。**不建议执行**，且必须离线。
