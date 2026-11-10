#!/bin/bash
# 批量创建 CI 实验环境 VM - PVE 8.4 + Cloud-Init（修正版）

# ========= 基础配置 =========
TEMPLATE_ID=100
BRIDGE=vmbr1
STORAGE=local-lvm
HOSTFILE=/root/vm_ip_host.txt
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

# ========= 映射表：VMID 主机名 IP CPU MEM =========
declare -A VMS=(
  [200]="gitlab 10.0.0.200 4 8192"
  [201]="jenkins 10.0.0.201 4 6144"
  [202]="nexus 10.0.0.202 2 4096"
  [203]="sonar 10.0.0.203 4 6144"
)

# ========= 公共 hosts 内容 =========
read -r -d '' COMMON_HOSTS << 'EOF'
10.0.0.5 lb01
10.0.0.6 lb02
10.0.0.7 web01
10.0.0.8 web02
10.0.0.9 sweb01
10.0.0.10 sweb02
10.0.0.31 nfs01
10.0.0.41 backup
10.0.0.51 db01
10.0.0.61 m01
EOF

# ========= 初始化输出文件 =========
echo -n "" > "$HOSTFILE"

# ========= 循环创建虚拟机 =========
for VMID in "${!VMS[@]}"; do
  set -- ${VMS[$VMID]}
  HOSTNAME=$1
  IP=$2
  CPU=$3
  MEM=$4

  echo "🚀 创建 VM$VMID ($HOSTNAME, $IP)..."

  USERDATA_FILE="$SNIPPET_DIR/${HOSTNAME}-cloudinit.yml"
  META_FILE="$SNIPPET_DIR/${HOSTNAME}-meta.yml"

  # ========= 生成 Cloud-Init user-data =========
cat > "$USERDATA_FILE" <<EOF
#cloud-config
hostname: ${HOSTNAME}
fqdn: ${HOSTNAME}.local
manage_etc_hosts: false
disable_root: false
ssh_pwauth: true
system_info:
  default_user:
    name: root
    lock_passwd: false

users:
  - name: root
    shell: /bin/bash
    lock_passwd: false
  - name: ${HOSTNAME}
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL

chpasswd:
  list: |
    root:<redacted-weak-password>
    ${HOSTNAME}:${HOSTNAME}
  expire: false

timezone: Asia/Shanghai

write_files:
  - path: /etc/hosts
    content: |
      127.0.0.1   localhost
      ${COMMON_HOSTS}
      10.0.0.200 gitlab
      10.0.0.201 jenkins
      10.0.0.202 nexus
      10.0.0.203 sonar
    permissions: '0644'

runcmd:
  - sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - systemctl restart ssh || systemctl restart sshd
  - hostnamectl set-hostname ${HOSTNAME}
  - echo "VM ${HOSTNAME} 初始化完成"
EOF


  # ========= 克隆并配置 =========
  qm clone $TEMPLATE_ID $VMID --name $HOSTNAME --full true

  qm set $VMID --cores $CPU --memory $MEM --net0 virtio,bridge=$BRIDGE
  qm set $VMID --ipconfig0 ip=${IP}/24,gw=10.0.0.1
  qm set $VMID --nameserver 192.168.2.1
  qm set $VMID --ciuser root --cipassword '<redacted-weak-password>'
  qm set $VMID --cicustom "user=local:snippets/${HOSTNAME}-cloudinit.yml,meta=local:snippets/${HOSTNAME}-meta.yml"

  # ========= 启动虚拟机 =========
  qm start $VMID

  echo "${IP}  ${HOSTNAME}" >> "$HOSTFILE"
  echo "✅ $HOSTNAME 创建完成。"
done

echo
echo "🎯 所有虚拟机创建完成！IP与主机名已保存至：$HOSTFILE"
cat "$HOSTFILE"
