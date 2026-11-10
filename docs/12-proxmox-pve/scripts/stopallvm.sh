#!/bin/bash
# 批量关闭 VM 110-119

for VMID in {110..119}; do
    echo "正在关闭 VM $VMID ..."
    qm shutdown $VMID
done

echo "所有虚拟机关闭命令已发送。"

