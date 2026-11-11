# GitLab 19.4 稳定版安装过程和配置

本文档记录了在 Ubuntu 24.04 上安装 GitLab CE 19.4.2 的完整过程和配置详情。

## 1. 环境检查

### 1.1 系统信息
```bash
cat /etc/os-release
uname -m
free -h
df -h /
nproc
```

**输出结果：**
- 操作系统：Ubuntu 24.04.4 LTS (Noble Numbat)
- 架构：x86_64
- 内存：7.8 GiB (可用 6.7 GiB)
- 磁盘：/dev/sda1 48G，总空间 48G，已用 8.7G，可用 39G (19%)
- CPU 核心数：2

## 2. 获取 GitLab 19.4 版本信息

### 2.1 搜索 GitLab 19.4 稳定版本
使用 websearch 查询 GitLab 19.4 稳定版发布信息，确认最新补丁版本为 19.4.2（发布于 19.4.x 系列）。

### 2.2 检查 packages.gitlab.com 上的可用版本
```bash
curl -s --max-time 90 "https://packages.gitlab.com/gitlab/gitlab-ce/ubuntu/dists/noble/main/binary-amd64/Packages" -o /tmp/opencode/gl-pkgs.txt
grep -oE "^Version: 19\.4\.[0-9]+-ce\.0" /tmp/opencode/gl-pkgs.txt | sort -u -V
```

**可用的 19.4.x 版本：**
- 19.4.0-ce.0
- 19.4.1-ce.0
- 19.4.2-ce.0（最终安装版本）

## 3. 前置依赖安装

### 3.1 更新系统并安装依赖包
```bash
apt-get update
apt-get install -y curl ca-certificates tzdata openssh-server perl gnupg
```

依赖包包括：curl、ca-certificates、tzdata、openssh-server、perl、gnupg。

## 4. 配置 GitLab APT 源

### 4.1 导入 GitLab GPG 密钥
```bash
curl -fsSL https://packages.gitlab.com/gpg.key | gpg --no-tty --batch --yes --dearmor -o /etc/apt/keyrings/gitlab.gpg
chmod 644 /etc/apt/keyrings/gitlab.gpg
```

### 4.2 添加 GitLab CE APT 源
```bash
cat > /etc/apt/sources.list.d/gitlab_ce.list << 'EOF'
deb [signed-by=/etc/apt/keyrings/gitlab.gpg] https://packages.gitlab.com/gitlab/gitlab-ce/ubuntu noble main
EOF
```

### 4.3 更新 APT 缓存
```bash
apt-get update
```

验证可用版本：
```bash
apt-cache madison gitlab-ce | grep 19.4
```

## 5. 安装 GitLab CE 19.4.2

### 5.1 安装指定版本
```bash
apt-get install -y gitlab-ce=19.4.2-ce.0
```

安装过程中 dpkg 持续进行配置，GitLab Omnibus 将自动安装和配置所需的所有组件（PostgreSQL、Redis、NGINX、GitLab Workhorse、Puma、Sidekiq、Gitaly 等）。

## 6. GitLab 配置

### 6.1 创建配置文件
```bash
mkdir -p /etc/gitlab
cp /opt/gitlab/etc/gitlab.rb.template /etc/gitlab/gitlab.rb
```

### 6.2 配置 external_url
获取主机 IP 地址：
```bash
hostname -I | awk '{print $1}'
# 结果：192.168.67.201
```

设置 external_url：
```bash
external_url "http://192.168.67.201"
```

（使用 perl/sed 完成替换）

## 7. 初始化配置 (reconfigure)

### 7.1 执行 gitlab-ctl reconfigure
```bash
/opt/gitlab/bin/gitlab-ctl reconfigure
```

此命令执行 Chef/Cinc 配置，自动初始化数据库、创建服务、生成配置文件等。首次配置耗时较长（约数分钟）。

配置完成后，所有 GitLab 服务自动启动。

### 7.2 检查服务状态
```bash
/opt/gitlab/bin/gitlab-ctl status
```

**运行中的服务（15个核心服务）：**
- alertmanager
- gitaly
- gitlab-exporter
- gitlab-kas
- gitlab-workhorse
- logrotate
- nginx
- node-exporter
- postgres-exporter
- postgresql
- prometheus
- puma
- redis
- redis-exporter
- sidekiq

所有服务状态均为 `run: ... (pid ...) ...; run: log: ...`

## 8. 端口和网络配置

### 8.1 服务监听端口
检查端口监听状态：
```bash
ss -tlnp
```

**关键端口：**
- `0.0.0.0:80` - Nginx（GitLab HTTP）初始配置
- `0.0.0.0:8060` - Nginx 状态/metrics
- `127.0.0.1:8080` - Puma（Rails 应用）
- `127.0.0.1:8082` - GitLab KAS
- `127.0.0.1:8092` - GitLab Exporter
- PostgreSQL、Redis 等内部服务运行在 localhost

### 8.2 端口 80 访问异常处理

在当前环境中，测试发现对 `127.0.0.1:80` 和 `192.168.67.201:80` 的 TCP 连接出现超时（hang），但 `8060` 端口正常。初步判断可能是环境中的 Cilium/eBPF/Tailscale 网络策略导致本地环回端口 80 存在过滤行为。

GitLab Nginx 配置本身语法正确（`nginx -t` 通过），且 Workhorse/Puma 均正常运行。

### 8.3 调整 Nginx 监听端口

为解决端口 80 访问问题，在 `/etc/gitlab/gitlab.rb` 中添加配置：
```bash
nginx['listen_port'] = 8088   # 注意：不是 gitlab_rails['nginx'][...]，那一层不存在，写了不生效
```

重新配置应用更改：
```bash
/opt/gitlab/bin/gitlab-ctl reconfigure
```

重新配置完成后，Nginx 监听端口变更为 `8088`。

验证端口：
```bash
ss -tlnp | grep 8088
# LISTEN 0 511 0.0.0.0:8088 *:* users:(("nginx",pid=102958,fd=7),...)
```

验证可访问性：
```bash
curl -L --connect-timeout 10 http://127.0.0.1:8088/users/sign_in | grep -o "<title>[^<]*</title>"
# <title>Sign in · GitLab</title>

curl -L --connect-timeout 10 http://192.168.67.201:8088/users/sign_in | grep -o "<title>[^<]*</title>"
# <title>Sign in · GitLab</title>
```

## 9. 获取初始管理员密码

GitLab 首次安装会自动生成 root 初始密码，保存在：
```bash
/etc/gitlab/initial_root_password
```

**初始凭据：**
- 用户名：`root`
- 密码：`<redacted-initial-root-password>`

> 注意：此文件仅在首次安装后生成，并且在下次 `gitlab-ctl reconfigure` 运行后 24 小时内自动删除。请在首次登录后立即修改 root 密码。

## 10. 访问 GitLab

**访问地址：**
- 本地访问：`http://127.0.0.1:8088/`
- 网络访问：`http://192.168.67.201:8088/`

使用 `root` 用户及上述初始密码登录。

## 11. 安装总结

- **GitLab 版本**：GitLab CE 19.4.2-ce.0
- **安装方式**：Omnibus（APT 源安装）
- **运行状态**：所有核心服务正常运行
- **Web 访问端口**：8088（因环境限制，未使用默认 80 端口）
- **配置文件**：`/etc/gitlab/gitlab.rb`
- **服务管理**：使用 `gitlab-ctl` 命令（start/stop/restart/status/reconfigure）

安装过程顺利完成，GitLab 可正常访问和使用。
