#!/bin/bash
# VM 配置表
declare -A HOSTMAP=(
  [110]="172.16.1.5 lb01"
  [111]="172.16.1.6 lb02"
  [112]="172.16.1.7 web01"
  [113]="172.16.1.8 web02"
  [114]="172.16.1.9 sweb01"
  [115]="172.16.1.10 sweb02"
  [116]="172.16.1.31 nfs01"
  [117]="172.16.1.41 backup"
  [118]="172.16.1.51 db01"
  [119]="172.16.1.61 m01"
)

# 全局 hosts（集群共享部分）
GLOBAL_HOSTS=$(cat <<EOF
172.16.1.5   lb01
172.16.1.6   lb02
172.16.1.7   web01
172.16.1.8   web02
172.16.1.9   sweb01
172.16.1.10  sweb02
172.16.1.31  nfs01
172.16.1.41  backup
172.16.1.51  db01
172.16.1.61  m01
EOF
)

# snippets 目录
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

for VMID in "${!HOSTMAP[@]}"; do
    IP=$(echo "${HOSTMAP[$VMID]}" | awk '{print $1}')
    HOSTNAME=$(echo "${HOSTMAP[$VMID]}" | awk '{print $2}')

    FILE="$SNIPPET_DIR/vm${VMID}.yaml"

    cat > "$FILE" <<EOF
#cloud-config
hostname: $HOSTNAME
manage_etc_hosts: false
write_files:
  - path: /etc/hosts
    permissions: '0644'
    owner: root:root
    content: |
::1  localhost.localdomain localhost
127.0.0.1  localhost.localdomain localhost
127.0.0.1  $HOSTNAME
$GLOBAL_HOSTS
EOF

    echo "[OK] 生成 $FILE"

    # 绑定到 VM
#    qm set $VMID --cicustom "user=local:snippets/vm${VMID}.yaml"
done

