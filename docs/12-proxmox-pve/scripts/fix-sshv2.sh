#!/bin/bash
# 批量修复 110-119 虚拟机 SSH 登录问题（允许密码登录，禁止密钥）

PASSWORD='<redacted-weak-password>'   # 登录密码，可自行修改
SNIPPET_DIR="/var/lib/vz/snippets"
SNIPPET_FILE="${SNIPPET_DIR}/force-password-login.yaml"

# 确保 snippets 目录存在
mkdir -p "$SNIPPET_DIR"

# 生成 cloud-init 配置文件（仅生成一次）
if [ ! -f "$SNIPPET_FILE" ]; then
    echo ">>> 生成 $SNIPPET_FILE"
    cat > "$SNIPPET_FILE" <<EOF
#cloud-config
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
  - path: /etc/ssh/sshd_config.d/90-proxmox-password-auth.conf
    permissions: '0644'
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes
runcmd:
  - systemctl restart sshd
EOF
else
    echo ">>> 已存在 $SNIPPET_FILE，跳过生成"
fi

# 批量修复 VM
for VMID in {110..119}; do
    echo ">>> 修复 VM $VMID"

    # 删除错误的 sshkeys
    qm set $VMID --delete sshkeys || true

    # 下发新的 cloud-init user-data
    qm set $VMID --cicustom "user=local:snippets/force-password-login.yaml"

    qm reboot $VMID
    echo ">>> VM $VMID 已更新并启动"
    echo
done

echo "全部 VM 修复完成，请用 root/${PASSWORD} 密码登录测试。"

