#!/bin/bash
# 一键批量创建 Rocky9 虚拟机实验环境
# 模板 ID
TEMPLATE=100

# VM 参数表 (VMID|NAME|IP0|GW0|IP1|CPU|MEM|DISK)
# 基于运维实验环境经验重新分配资源：
# - 总宿主机资源：80核CPU、64GB内存、1TB SSD。
# - 考虑宿主机开销（约4-8GB内存、几核CPU），VM总分配控制在安全范围内（总CPU超配可达~200%，总内存<60GB，总磁盘<800GB以留缓冲）。
# - 分配原则：
#   - LB (负载均衡)：低负载，2核、2GB内存、20G磁盘（处理网络流量为主）。
#   - Web/SWeb (Web服务器)：中等负载，4核、4GB内存、50G磁盘（运行应用服务）。
#   - NFS (存储)：中等CPU/内存，但需更大磁盘100G（文件共享）。
#   - Backup (备份)：中等CPU/内存，最大磁盘200G（存储备份数据）。
#   - DB (数据库)：较高负载，6核、8GB内存、100G磁盘（查询/存储密集）。
#   - M (管理/监控)：中等，4核、4GB内存、50G磁盘。
# 总计：CPU 38核（超配安全）、内存 40GB、磁盘 690G。
VM_LIST=(
  "110|lb01|10.0.0.5/24|10.0.0.1|172.16.1.5/16|2|2048|20G"
  "111|lb02|10.0.0.6/24|10.0.0.1|172.16.1.6/16|2|2048|20G"
  "112|web01|10.0.0.7/24|10.0.0.1|172.16.1.7/16|4|4096|50G"
  "113|web02|10.0.0.8/24|10.0.0.1|172.16.1.8/16|4|4096|50G"
  "114|sweb01|10.0.0.9/24|10.0.0.1|172.16.1.9/16|4|4096|50G"
  "115|sweb02|10.0.0.10/24|10.0.0.1|172.16.1.10/16|4|4096|50G"
  "116|nfs01|10.0.0.31/24|10.0.0.1|172.16.1.31/16|4|4096|80G"
  "117|backup|10.0.0.41/24|10.0.0.1|172.16.1.41/16|4|4096|80G"
  "118|db01|10.0.0.51/24|10.0.0.1|172.16.1.51/16|6|8192|80G"
  "119|m01|10.0.0.61/24|10.0.0.1|172.16.1.61/16|4|4096|50G"
)

for entry in "${VM_LIST[@]}"; do
    IFS="|" read -r VMID NAME IP0 GW0 IP1 CPU MEM DISK <<< "$entry"

    echo ">>> 正在创建 VM $VMID ($NAME)"

    # 克隆虚拟机
    qm clone $TEMPLATE $VMID --name $NAME --full

    # 配置资源
    qm set $VMID --cores $CPU --memory $MEM
    qm resize $VMID scsi0 $DISK

    # 添加网卡
    qm set $VMID --net0 virtio,bridge=vmbr1
    qm set $VMID --net1 virtio,bridge=vmbr2

    # 分配 IP（cloud-init 下发）
    qm set $VMID --ipconfig0 ip=$IP0,gw=$GW0
    qm set $VMID --ipconfig1 ip=$IP1

    # 设置 DNS 和密码
    qm set $VMID --nameserver 192.168.2.1 --searchdomain local
    qm set $VMID --ciuser root --cipassword '<redacted-weak-password>'

    # 禁止 cloud-init 写入 ssh 公钥
    qm set $VMID --sshkeys /dev/null
    echo ">>> VM $VMID ($NAME) 已配置完成"
    echo
done

echo ">>> 所有实验环境虚拟机已创建完成，可以启动。"
