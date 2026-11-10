# 05 · Linux 权限：su、sudo 与 root shell

## 当时的情况

排查“如何在不暴露 root 密码的情况下切换到 root”“为什么 `sudo` 和 `su`
行为不同”“无密码 SSH 登录后为什么可以直接进 root”等问题。

这类问题看似基础，但涉及：

- setuid / 文件 capability；
- PAM（pam_unix、pam_env、pam_limits 等）；
- 登录 shell 与交互式非登录 shell 的区别；
- SSH 公钥认证与 `authorized_keys` 的 command/环境限制；
- `sudoers` 的最小权限设计。

## 主要概念与原理

### 1. su 与 sudo 的区别

| 命令 | 认证 | 环境 | 典型用途 |
|---|---|---|---|
| `su -` | 目标用户密码 | 登录 shell，完整环境 | 切换到 root/其他用户 |
| `su` | 目标用户密码 | 保留部分当前环境 | 临时切换 |
| `sudo` | 当前用户密码（或 NOPASSWD） | 默认保留环境，可 `-i` 模拟登录 | 以 root 执行单条命令 |
| `sudo -i` | 当前用户密码 | 登录 shell | 获得 root 交互环境 |
| `sudo -s` | 当前用户密码 | 非登录 shell | 快速 root shell |

### 2. setuid 与 PAM

- `su` 二进制带 setuid root，所以普通用户可以启动它；
- `sudo` 同理；
- 真正的认证由 PAM 完成；
- `sudoers` 决定谁能以谁的身份执行什么命令。

### 3. root shell 的几种方式

- `su -`：需要 root 密码；
- `sudo -i`：需要当前用户在 sudoers 中；
- `ssh root@host`：需要 root 登录权限（通常禁用）；
- 无密码 SSH：基于公钥，不是“没有密码就能 root”，而是密钥认证。

## 踩坑点

### 坑 1：`su` 和 `sudo` 环境变量不同

`su -` 会加载目标用户的登录环境；`sudo` 默认保留当前环境。
脚本里依赖 `PATH`、`HOME` 时容易出问题。

### 坑 2：无密码 SSH ≠ 无认证

无密码 SSH 是公钥认证。私钥泄露等于身份泄露。
要限制 `authorized_keys` 的 `command=`、`from=`、`no-pty` 等选项。

### 坑 3：直接允许 root SSH

`PermitRootLogin yes` 风险高；建议普通用户 + sudo，或仅密钥 + 限制来源。

### 坑 4：`sudo passwd` 与 `passwd`

`sudo passwd` 是“以 root 身份执行 passwd”，可以改 root 密码；
`passwd` 是改当前用户密码。两者权限和影响不同。

### 坑 5：TTY 与 sudo 的 `requiretty`

某些发行版/配置要求 sudo 必须在 TTY 中执行；自动化脚本会失败。
需要看 `Defaults requiretty` 和 `sudo -n` 的行为。

## 修复关键 / 安全建议

1. 优先使用 `sudo`，按最小权限配置 `sudoers`；
2. 禁止 root 密码登录和 root SSH，使用普通用户 + sudo；
3. 无密码 SSH 只用于自动化，限制来源和命令；
4. 不共享 root 密码；用 `visudo` 修改 sudoers；
5. 审计 `sudo` 日志（`/var/log/auth.log` 或 journald）。

## 配套脚本

[`scripts/sudo_audit.py`](scripts/sudo_audit.py)

```bash
sudo python3 scripts/sudo_audit.py
```

只读检查：

- UID 0 账户；
- `sudoers` / `sudoers.d` 的 `NOPASSWD`；
- `sshd_config` 的 `PermitRootLogin` / `PasswordAuthentication`；
- `authorized_keys` 的 `command=` / `from=` / `restrict` 限制。

## 文档列表

| 文档 | 内容 |
|---|---|
| [sudo-su-详解.md](sudo-su-详解.md) | su/sudo、PAM、setuid、无密码 SSH、直接进 root 的原理与实验 |
| [worker-disk-expansion-20261028.md](notes/worker-disk-expansion-20261028.md) | PVE 虚拟盘在线扩容：分区/LVM/ext4 全链路，不停机 |
| [memory-analysis-m01.md](notes/memory-analysis-m01.md) | m01 节点内存构成、进程 TOP、Pod/容器内存拆解 |
| [app-removal-record.md](notes/app-removal-record.md) | 宿主机 Zabbix/MariaDB/nginx/php-fpm 下线记录 |

## 补充：主机层运维（磁盘 / 内存 / 旧服务下线）

### 1. 在线扩容不是“加盘再重启”

本集群 worker 的系统盘是 PVE 的 virtio-scsi 虚拟盘，扩容分两层：

```text
PVE:   qm resize <vmid> scsi0 +10G
Guest: rescan → growpart → pvresize → lvextend → resize2fs
```

关键点：

- `qm resize` 对运行中的 virtio-scsi 磁盘生效，**不需要关机**；
- `growpart` 对已挂载分区安全，会自动搬移 GPT 备份头；
- LVM 和 ext4 都支持在线扩容；
- 扩容后要验证 `df -hT /`、`dmesg` 无 I/O 错误、节点 `uptime` 未变。

### 2. 内存分析要看 cgroup，不只看 `free`

节点内存由这些部分组成：

- 内核/页缓存/ slab；
- kubelet、containerd、Cilium、监控 agent 等系统进程；
- Pod 的 cgroup 内存（`container_memory_working_set_bytes`）；
- 未计入 cgroup 的 host 进程。

`memory-analysis-m01.md` 里把 RSS、cgroup、Pod 内存逐层拆开，避免把“页缓存”误判成泄漏。

### 3. 旧服务下线要先证明“没人用”

Zabbix/MariaDB/nginx/php-fpm 下线前做了 4 项确认：

1. 端口/进程是否仍被监控或业务引用；
2. Prometheus exporter 是否依赖该服务；
3. 是否有 systemd 依赖/定时任务；
4. 备份配置和数据，保留回滚路径。

**踩坑**：`mysqld_exporter` 依赖已停止的 MariaDB，直接删服务会让 exporter 持续报错；
要先改/停 exporter，再删数据库。

## 配套资产

| 资产 | 说明 |
|---|---|
| [scripts/grow-lvm.sh](scripts/grow-lvm.sh) | LVM 在线扩容辅助脚本（按实际设备名调整） |
| [scripts/sudo_audit.py](scripts/sudo_audit.py) | 只读 sudo/SSH 权限审计 |
| [scripts/change_repo.sh](scripts/change_repo.sh) | Rocky Linux 仓库切换 |
| [scripts/change_epel.sh](scripts/change_epel.sh) | EPEL 仓库配置 |
| [scripts/dnf.sh](scripts/dnf.sh) | 常用包安装（ipvsadm/cowsay/sl） |
| [scripts/kata-manager.sh](scripts/kata-manager.sh) | Kata Containers 安装/管理工具 |

```bash
# 只读审计
sudo python3 docs/05-linux/scripts/sudo_audit.py

# 扩容前先确认布局（不要直接跑脚本）
lsblk -f
vgs; lvs; df -hT /
```

> 生产环境请遵循组织的权限管理制度；本文只用于原理学习和排障。
