#!/bin/bash
# PVE 批量克隆虚拟机脚本 (Rocky9 模板优化版)
# 模板 VMID
TEMPLATE=100

# 创建函数
create_vm () {
  VMID=$1
  NAME=$2
  ETH0_IP=$3
  ETH1_IP=$4
  MEM=$5
  CORES=$6
  DISK=$7

  echo "===> 创建 $NAME (VMID=$VMID, CPU=$CORES, MEM=${MEM}M, DISK=${DISK}G)..."

  # 克隆
  qm clone $TEMPLATE $VMID --name $NAME --full

  # 配置 CPU / 内存
  qm set $VMID --cores $CORES --memory $MEM

  # 添加网卡
  qm set $VMID --net0 virtio,bridge=vmbr0
  qm set $VMID --net1 virtio,bridge=vmbr1

  # 调整磁盘大小（scsi0 默认磁盘）
  qm resize $VMID scsi0 ${DISK}G

  # 如果模板支持 cloud-init，就设置 IP
  qm set $VMID --ipconfig0 ip=$ETH0_IP,gw=10.0.0.1
  qm set $VMID --ipconfig1 ip=$ETH1_IP

  echo "完成 $NAME"
}

# 批量创建，从 110 开始
create_vm 110 lb01   "10.0.0.5/24"   "172.16.1.5/16"   2048 2 50
create_vm 111 lb02   "10.0.0.6/24"   "172.16.1.6/16"   2048 2 50
create_vm 112 web01  "10.0.0.7/24"   "172.16.1.7/16"   2048 2 50
create_vm 113 web02  "10.0.0.8/24"   "172.16.1.8/16"   2048 2 50
create_vm 114 sweb01 "10.0.0.9/24"   "172.16.1.9/16"   2048 2 50
create_vm 115 sweb02 "10.0.0.10/24"  "172.16.1.10/16"  2048 2 50
create_vm 116 nfs01  "10.0.0.31/24"  "172.16.1.31/16"  8192 8 100
create_vm 117 backup "10.0.0.41/24"  "172.16.1.41/16"  2048 2 50
create_vm 118 db01   "10.0.0.51/24"  "172.16.1.51/16"  8192 8 100
create_vm 119 m01    "10.0.0.61/24"  "172.16.1.61/16"  2048 2 50
