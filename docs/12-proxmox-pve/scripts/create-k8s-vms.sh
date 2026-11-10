#!/bin/bash
set -e

# =============================
# CONFIG SECTION
# =============================
BASE_TEMPLATE_ID=9000
BRIDGE1="vmbr1"   # 管理网段 10.0.0.x
BRIDGE2="vmbr2"   # Pod/业务网段 10.16.x.x

ROOT_PWD_HASH='<redacted-password-hash>'

ALL_HOSTS="127.0.0.1 localhost
10.0.0.121 master01
10.0.0.122 worker01
10.0.0.123 worker02
10.0.0.124 worker03"

declare -A VM_CPU=( ["master01"]=4 ["worker01"]=6 ["worker02"]=6 ["worker03"]=4 )
declare -A VM_RAM=( ["master01"]=4096 ["worker01"]=8192 ["worker02"]=4096 ["worker03"]=4096 )
declare -A IP1=( ["master01"]="10.0.0.121" ["worker01"]="10.0.0.122" ["worker02"]="10.0.0.123" ["worker03"]="10.0.0.124" )
declare -A IP2=( ["master01"]="10.16.1.121" ["worker01"]="10.16.1.122" ["worker02"]="10.16.1.123" ["worker03"]="10.16.1.124" )

# =============================
# 生成 user-data 和 meta-data
# =============================
gen_cloud_init_files() {
  local vm=$1
  local ip1=${IP1[$vm]}

  echo "Generating cloud-init files for $vm ..."

  # --- user-data ---
  cat > "/var/lib/vz/snippets/${vm}-user.yml" <<EOF
#cloud-config
hostname: $vm
fqdn: $vm.local

users:
  - name: root
    passwd: "$ROOT_PWD_HASH"
    lock_passwd: false
    shell: /bin/bash

ssh_pwauth: true
disable_root: false

# 防止 cloud-init 覆盖我们自定义的 /etc/hosts
manage_etc_hosts: false

write_files:
  - path: /etc/hosts
    owner: root:root
    permissions: '0644'
    content: |
$(echo "$ALL_HOSTS" | sed 's/^/      /')
      $ip1 $vm $vm.local

runcmd:
  - hostnamectl set-hostname $vm  # 额外保险
  - systemctl enable --now ssh
  - systemctl restart systemd-networkd
EOF

  # --- meta-data (关键！显式指定 local-hostname) ---
  cat > "/var/lib/vz/snippets/${vm}-meta.yml" <<EOF
local-hostname: $vm
EOF
}

# =============================
# 创建 VM
# =============================
create_vm() {
  local vm=$1
  local vmid=$2
  local ip1=${IP1[$vm]}
  local ip2=${IP2[$vm]}

  echo ""
  echo "==============================="
  echo "Creating $vm (VMID=$vmid)"
  echo "==============================="

  gen_cloud_init_files "$vm"

  qm clone $BASE_TEMPLATE_ID $vmid --full 1 --name "$vm"

  qm set $vmid --cores ${VM_CPU[$vm]} --memory ${VM_RAM[$vm]}
  qm set $vmid --net0 virtio,bridge=$BRIDGE1
  qm set $vmid --net1 virtio,bridge=$BRIDGE2

  qm set $vmid --ipconfig0 "ip=$ip1/24,gw=10.0.0.1"
  qm set $vmid --ipconfig1 "ip=$ip2/16"

  qm resize $vmid scsi0 50G

  qm set $vmid --agent enabled=1
  qm set $vmid --serial0 socket --vga serial0

  # 同时绑定 user-data 和 meta-data
  qm set $vmid --cicustom "user=local:snippets/${vm}-user.yml,meta=local:snippets/${vm}-meta.yml"

  qm start $vmid

  echo "$vm 创建完成！IP: $ip1 (管理) / $ip2 (业务)"
}

# =============================
# MAIN
# =============================
mkdir -p /var/lib/vz/snippets

create_vm master01 121
create_vm worker01 122
create_vm worker02 123
create_vm worker03 124

echo ""
echo "========================================================="
echo "所有 K8s 实验节点创建完成！"
echo "等 30~60 秒 cloud-init 执行完毕后即可登录："
echo "  ssh root@10.0.0.121   (master)"
echo "  ssh root@10.0.0.122   (worker01)"
echo "密码就是你 hash 对应的明文"
echo "========================================================="
