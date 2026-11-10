#!/bin/bash
# 批量清理 VM110-119 的旧 cloud-init ISO

# VMID 范围
VM_START=110
VM_END=119

# ISO 存放目录（根据你的 PVE 存储路径调整）
ISO_DIR="/var/lib/vz/images"

echo ">>> 开始清理 VM $VM_START - $VM_END 的旧 cloud-init ISO"

for VMID in $(seq $VM_START $VM_END); do
    # 查找 VM 的 ISO 文件（一般命名为 vm-<VMID>-cloudinit.iso）
    ISO_FILE=$(find $ISO_DIR -type f -name "vm-${VMID}-cloudinit.iso")

    if [ -n "$ISO_FILE" ]; then
        echo ">>> 删除 VM $VMID 的旧 cloud-init ISO: $ISO_FILE"
        rm -f "$ISO_FILE"
    else
        echo ">>> VM $VMID 没有找到旧 cloud-init ISO，跳过"
    fi
done

echo ">>> 清理完成"

