#!/bin/bash
# PVE批量扩展Rocky9虚拟机磁盘空间 (自动识别LVM版)
# 适用：VMID 110-119

START=110
END=119

for VMID in $(seq $START $END); do
    echo "=== 扩展 VM $VMID 磁盘空间 ==="
    
    # 检查VM是否开机
    STATUS=$(qm status $VMID | awk '{print $2}')
    if [[ "$STATUS" != "running" ]]; then
        echo "VM $VMID 未运行，跳过"
        continue
    fi

    # 确保必要工具已安装
    qm guest exec $VMID -- \
        "bash -c 'dnf install -y lvm2 cloud-utils-growpart >/dev/null 2>&1'"

    # 扩展分区2（LVM PV）
    qm guest exec $VMID -- growpart /dev/sda 2

    # 调整物理卷
    qm guest exec $VMID -- pvresize /dev/sda2

    # 自动检测根逻辑卷路径
    ROOT_LV=$(qm guest exec $VMID -- \
        "bash -c \"lsblk -o MOUNTPOINT,NAME | grep ' /$' | awk '{print \\$2}'\"" \
        | grep -oE '[a-zA-Z0-9_-]+')

    if [[ -z "$ROOT_LV" ]]; then
        echo "未能检测到 VM $VMID 的根逻辑卷，跳过"
        continue
    fi

    # 拼接为 /dev/mapper/<卷组>-<卷名>
    LV_PATH=$(qm guest exec $VMID -- \
        "bash -c \"lvdisplay --colon | grep ':$ROOT_LV:' | cut -d: -f1\"")

    if [[ -z "$LV_PATH" ]]; then
        echo "未能找到 VM $VMID 的逻辑卷路径，跳过"
        continue
    fi

    # 扩展逻辑卷并自动扩展文件系统
    qm guest exec $VMID -- lvextend -r -l +100%FREE "$LV_PATH"

    echo "VM $VMID 扩容完成 (逻辑卷: $LV_PATH)"
done

