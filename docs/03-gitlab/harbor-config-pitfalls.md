# Harbor 实际配置、端口/证书与 Trivy 修复

## 当时的情况

Harbor 用离线安装包部署在 `192.168.67.202`，Docker Compose 方式运行：

- 版本 **v2.14.5**；
- 安装目录 `/root/harbor`；
- HTTP 8080、HTTPS 8443；
- 自签证书；
- 认证方式 OIDC（GitLab）；
- Trivy 漏洞扫描曾因 `mirror.gcr.io` 不可达而失败，后来通过
  `docker-compose.override.yml` 修复。

## 主要概念与原理

### 1. Harbor 组件

| 容器 | 作用 |
|---|---|
| `nginx` | 入口，8080/8443 |
| `harbor-core` | 核心 API/业务 |
| `harbor-portal` | Web UI |
| `harbor-jobservice` | 异步任务（复制/扫描/GC） |
| `registry` | Docker Registry |
| `registryctl` | Registry 控制面 |
| `harbor-db` | PostgreSQL |
| `redis` | 缓存/队列 |
| `trivy-adapter` | 漏洞扫描 |
| `harbor-log` | 日志收集 |

### 2. 配置层次

```text
/root/harbor/harbor.yml
  -> ./prepare
  -> /root/harbor/common/config/<component>/env
  -> docker-compose.yml + docker-compose.override.yml
  -> 容器环境变量
```

注意：

- 直接改 `common/config/*/env` 可能在下次 `prepare` 被覆盖；
- 持久化覆盖应放 `docker-compose.override.yml`；
- OIDC 配置存在 Harbor DB/API 中，不一定在 `harbor.yml` 里。

### 3. 端口与证书

- `http.port: 8080`：只做 HTTP→HTTPS 跳转；
- `https.port: 8443`：实际服务；
- `external_url: https://192.168.67.202:8443`；
- 证书：`/root/harbor/certs/harbor.crt`，私钥不展示；
- `has_ca_root=false`：客户端需要导入 CA 或使用 `-k`/insecure。

## 实际配置

### 1. harbor.yml 关键项（已脱敏）

```yaml
hostname: 192.168.67.202
http:
  port: 8080
https:
  port: 8443
  certificate: /root/harbor/certs/harbor.crt
  private_key: ***REDACTED***
external_url: https://192.168.67.202:8443
harbor_admin_password: ***REDACTED***
database:
  password: ***REDACTED***
data_volume: /data
trivy:
  ignore_unfixed: false
  security_check: vuln
jobservice:
  max_job_workers: 10
log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200M
_version: 2.14.0
```

### 2. 运行中的容器

```text
goharbor/nginx-photon:v2.14.5
goharbor/harbor-core:v2.14.5
goharbor/harbor-portal:v2.14.5
goharbor/harbor-jobservice:v2.14.5
goharbor/registry-photon:v2.14.5
goharbor/harbor-registryctl:v2.14.5
goharbor/harbor-db:v2.14.5
goharbor/redis-photon:v2.14.5
goharbor/trivy-adapter-photon:v2.14.5
goharbor/harbor-log:v2.14.5
```

### 3. Trivy 修复

问题现象：

```text
failed to download Java DB:
... mirror.gcr.io/aquasec/trivy-java-db:1
```

原因：

- `mirror.gcr.io` 在本机不可达；
- 早期配的是 `TRIVY_DB_REPOSITORY`，但 trivy-adapter 只读
  `SCANNER_TRIVY_*` 前缀，配置从未生效；
- 没有覆盖 Java DB，首次扫描仍会失败。

修复文件：`/root/harbor/docker-compose.override.yml`

```yaml
services:
  trivy-adapter:
    environment:
      SCANNER_TRIVY_DB_REPOSITORY: public.ecr.aws/aquasecurity/trivy-db:2
      SCANNER_TRIVY_JAVA_DB_REPOSITORY: public.ecr.aws/aquasecurity/trivy-java-db:1
```

为什么用 override：

- `common/config/trivy-adapter/env` 会被 `./prepare` 覆盖；
- Compose 会自动合并 override，`prepare` 不碰它；
- 如果 ECR 也不可达，可改用内网 Harbor 的 trivy-db 副本，并设置
  `SCANNER_TRIVY_INSECURE: "True"`。

## 踩坑点

### 坑 1：按 80/443 访问

Harbor 实际是 8080/8443。部署文档第 6 节记录了端口排查过程。
`curl 192.168.67.202:80` 或 `:443` 不通是正常的。

### 坑 2：自签证书导致客户端失败

`has_ca_root=false`。Docker/containerd/K8s 节点需要：

- 把 `harbor.crt` 放到 `/etc/docker/certs.d/192.168.67.202:8443/ca.crt`；
- 或 containerd 配置 CA；
- 或临时 insecure registry（不推荐生产）。

### 坑 3：直接改生成的 env

`common/config/*/env` 是 `prepare` 生成的，下次 install/upgrade 会覆盖。
要持久化就改 `harbor.yml` 或 `docker-compose.override.yml`。

### 坑 4：OIDC 配置不在 harbor.yml

Harbor 的 OIDC 配置存在 DB/API 中；只改 `harbor.yml` 的 `auth_mode`
不一定能切换认证。要用 Harbor API/UI 修改并确认 `systeminfo.auth_mode`。

### 坑 5：Trivy 变量前缀写错

`TRIVY_DB_REPOSITORY` 不会生效；必须是 `SCANNER_TRIVY_DB_REPOSITORY`。
Java DB 也要单独配 `SCANNER_TRIVY_JAVA_DB_REPOSITORY`。

### 坑 6：admin 凭据到处复用

Harbor 的 admin 密码、DB 密码、OIDC client secret 都在 Harbor 主机上；
imagePullSecret 又用了 admin，导致凭据扩散。应使用 Robot。

### 坑 7：重启后 nginx 缓存旧 core IP，OIDC 按钮消失

2026-11-26 主机重启 + `docker compose up -d` 后，登录页没有
`Login with GitLab`，本地 admin 也 401，但容器全部 healthy、
DB 里 `auth_mode=oidc_auth` 仍在。

原因：Harbor 的 nginx 只在启动时解析一次 `upstream core` 并缓存 IP。
主机重启后容器 IP 重新分配，旧 `core` IP 可能分给 `harbor-jobservice`，
于是 `/api/`、`/c/` 全打到 jobservice。公开接口
`GET /api/v2.0/systeminfo` 返回 401，前端因此不渲染 OIDC 按钮。

恢复（执行机器 `ubuntu02`）：

```bash
docker exec nginx nginx -s reload
```

持久化：用 `harbor-nginx-reload.service` 开机等 core/portal 健康后自动
reload。完整排查过程、systemd 单元与验证命令见
[notes/harbor-oidc-login-missing-after-reboot-2026-11-26.md](notes/harbor-oidc-login-missing-after-reboot-2026-11-26.md)。

## 修复关键 / 建议

1. **端口固定为 8080/8443**，文档和客户端都按此配置；
2. **分发 CA**，不要长期用 `-k`/insecure；
3. **Trivy 用 override 持久化**，升级后重新验证扫描；
4. **OIDC 用 API/UI 配置**，并打开证书校验；
5. **凭据最小化**：Robot 账号替代 admin；
6. **升级前备份**：
   - `/root/harbor/harbor.yml`
   - `/root/harbor/certs/`
   - `/data`（Harbor 数据）
   - Harbor DB 备份
7. **不要把 `harbor.yml` / 部署文档中的密码提交 Git**。
8. **重启后先看公开接口**：`/api/v2.0/systeminfo` 若 401，先 reload nginx，
   不要误改 OIDC 配置（见坑 7）。

## 验证命令

```bash
# 容器
sudo docker ps --format '{{.Names}}\t{{.Image}}\t{{.Ports}}'

# 系统信息（公开接口，不需要认证；返回 401 说明 nginx 转发错了，见坑 7）
curl -k https://192.168.67.202:8443/api/v2.0/systeminfo | jq

# 项目
curl -k -u admin:<password> \
  'https://192.168.67.202:8443/api/v2.0/projects?page_size=100' | jq

# 手动触发扫描（示例）
curl -k -u admin:<password> -X POST \
  'https://192.168.67.202:8443/api/v2.0/projects/openwebui/repositories/open-webui/artifacts/<tag>/scan'

# 看 Trivy adapter 日志
sudo docker logs --tail 100 trivy-adapter
```

> Harbor 主机的 `/root/harbor/HARBOR-部署文档.md` 记录了完整部署/端口/Trivy
> 过程，但其中包含密码，未纳入公开仓库。
