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

> 生产环境请遵循组织的权限管理制度；本文只用于原理学习和排障。
