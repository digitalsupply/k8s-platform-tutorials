#!/bin/bash
# 一键批量配置 VM110-119
# 功能：设置 hostname + /etc/hosts + SSH 密码登录，禁止密钥

PASSWORD='<redacted-weak-password>'   # root 登录密码
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"

# VM 配置表 VMID -> "IP HOSTNAME"
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

# 生成全局 hosts 内容
GLOBAL_HOSTS=""
for VMID in "${!HOSTMAP[@]}"; do
    IP=$(echo "${HOSTMAP[$VMID]}" | awk '{print $1}')
    NAME=$(echo "${HOSTMAP[$VMID]}" | awk '{print $2}')
    GLOBAL_HOSTS+="$IP   $NAME"$'\n'
done

# 批量生成 YAML 并应用
for VMID in "${!HOSTMAP[@]}"; do
    IP=$(echo "${HOSTMAP[$VMID]}" | awk '{print $1}')
    NAME=$(echo "${HOSTMAP[$VMID]}" | awk '{print $2}')
    SNIPPET_FILE="$SNIPPET_DIR/vm${VMID}.yaml"

    echo ">>> 生成 $SNIPPET_FILE"

    cat > "$SNIPPET_FILE" <<EOF
#cloud-config
hostname: $NAME
#manage_etc_hosts: true
ssh_pwauth: true
ssh_authorized_keys: []
users:
  - name: root
    plain_text_passwd: '${PASSWORD}'
    lock_passwd: false
    shell: /bin/bash
chpasswd:
  expire: False
disable_root: false
write_files:
  - path: /etc/hosts
    owner: root:root
    permissions: '0644'
    content: |
127.0.0.1  localhost.localdomain localhost
::1  localhost.localdomain localhost
#127.0.0.1  $NAME
$GLOBAL_HOSTS
  - path: /etc/ssh/sshd_config.d/90-proxmox-password-auth.conf
    permissions: '0644'
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes
runcmd:
  - systemctl restart sshd
EOF

done

echo ">>> 全部 VM 已完成配置，root 密码为 ${PASSWORD}"
