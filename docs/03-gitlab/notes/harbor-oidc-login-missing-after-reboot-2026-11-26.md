# Harbor 重启后登录页没有 “Login with GitLab”：nginx 缓存了旧 core IP

> 2026-11-26，`ubuntu02`（`192.168.67.202`）主机重启后执行 `docker compose up -d`，
> Harbor 登录页只剩本地登录，`Login with GitLab` 入口消失，本地 admin 也登不进去。
>
> 结论：**OIDC 配置没有丢**。Harbor 的 nginx 在启动时缓存了 `upstream core` 的 IP，
> 重启后容器 IP 重新分配，`/api/`、`/c/` 被转发到了 `harbor-jobservice`，
> 公开接口 `GET /api/v2.0/systeminfo` 返回 401，前端因此不渲染 OIDC 按钮。

## 1. 现象

- `https://192.168.67.202:8443/` 能打开登录页；
- 页面上没有 `Login with GitLab`；
- 本地 admin 登录也失败，`POST /c/login` 返回 401；
- `docker ps` 里 Harbor 容器全部 `Up (healthy)`；
- Harbor DB 里 `auth_mode=oidc_auth`，`oidc_*` 配置都在。

先确认配置没丢（执行机器：`ubuntu02`）：

```bash
docker exec harbor-db psql -U postgres -d registry -At -c \
  "select k, case when k like '%secret%' then '***' else v end
     from properties
    where k like 'oidc%' or k like '%auth%'
    order by k;"
```

关键输出：

```text
auth_mode|oidc_auth
oidc_admin_group|digitalsupply
oidc_auto_onboard|true
oidc_client_id|c7924430...（与 GitLab OAuth 应用 harbor 的 uid 一致）
oidc_endpoint|http://192.168.67.201
oidc_groups_claim|groups
oidc_name|GitLab
oidc_scope|openid,profile,email
oidc_user_claim|preferred_username
oidc_verify_cert|false
```

所以不要急着重写 `harbor.yml` 或重配 OIDC。

## 2. 为什么 OIDC 按钮会消失

Harbor 前端登录页通过公开接口 `GET /api/v2.0/systeminfo` 判断认证方式。

正常返回（修复后实测）：

```bash
curl -ksS https://192.168.67.202:8443/api/v2.0/systeminfo | jq
```

```json
{
  "auth_mode": "oidc_auth",
  "banner_message": "",
  "oidc_provider_name": "GitLab",
  "primary_auth_mode": false,
  "self_registration": false
}
```

故障时同一接口返回：

```json
{"code":10011,"message":"unauthorized","details":"header 'Authorization' missing"}
```

前端拿不到 `oidc_provider_name`，就只渲染本地登录；而本地登录的
`POST /c/login` 同样被打到错误后端，所以也 401。

## 3. 定位：`/api` 被打到了 jobservice

`header 'Authorization' missing` 是 **harbor-jobservice** 的报错，
它只认 `Authorization: Harbor-Secret <JOBSERVICE_SECRET>`。

执行机器：`ubuntu02`。

```bash
# 1) 容器内直连 core 正常
docker exec harbor-core curl -s -o /dev/null -w 'core   %{http_code}\n' \
  http://127.0.0.1:8080/api/v2.0/ping          # core   200
docker exec nginx curl -s -o /dev/null -w 'nginx->core %{http_code}\n' \
  http://core:8080/api/v2.0/ping               # nginx->core 200

# 2) 走 nginx 入口异常
curl -ksS -o /dev/null -w 'entry  %{http_code}\n' \
  https://192.168.67.202:8443/api/v2.0/ping    # entry  401
```

再看容器 IP，并直接打 jobservice：

```bash
for c in nginx harbor-core harbor-jobservice harbor-portal; do
  printf '%-18s %s\n' "$c" \
    "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $c)"
done

docker exec nginx curl -s http://172.18.0.11:8080/api/v2.0/ping
# {"code":10011,"message":"unauthorized","details":"header 'Authorization' missing"}
```

`172.18.0.11` 是 `harbor-jobservice`，返回内容与故障时完全一致。

根因链条：

1. Harbor nginx 配置是 `upstream core { server core:8080; }`，
   **upstream 域名只在 nginx 启动时解析一次**，之后一直用缓存的 IP；
2. 主机重启后，Docker 按自己的顺序拉起 `restart: always` 容器，
   容器 IP 可能被重新分配（旧 `core` 的 IP 可能分给了 `jobservice`）；
3. nginx 先启动，解析到的是旧 `core` 的 IP；等 core 真正起来时，
   nginx 仍把 `/api/`、`/c/` 发往旧 IP，也就是现在的 jobservice；
4. 于是 `systeminfo` 401 → 前端隐藏 OIDC 按钮，`/c/login` 也 401。

`docker compose up -d` 修不好：容器已经在跑，compose 不会重建 nginx，
缓存依旧是错的。

## 4. 修复

### 4.1 立即恢复

执行机器：`ubuntu02`。

```bash
docker exec nginx nginx -s reload
# 等价写法：
# cd /root/harbor && docker compose restart nginx
```

验证：

```bash
curl -ksS https://192.168.67.202:8443/api/v2.0/ping
# Pong

curl -ksS https://192.168.67.202:8443/api/v2.0/systeminfo | jq
# auth_mode=oidc_auth，oidc_provider_name=GitLab

curl -ksS -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  https://192.168.67.202:8443/c/oidc/login
# 302 http://192.168.67.201/oauth/authorize?client_id=...&redirect_uri=https%3A%2F%2F192.168.67.202%3A8443%2Fc%2Foidc%2Fcallback
```

浏览器如果还是旧页面，`Ctrl+F5` 强刷，或清一次站点缓存。

### 4.2 持久化：开机后自动 reload nginx

只做一次 reload 只能救当前这次。为了让下次重启也自动恢复，
在 `ubuntu02` 上放一个 systemd oneshot：等 `harbor-core`、`harbor-portal`
健康后执行 `nginx -s reload`。

执行机器：`ubuntu02`。下面命令可直接整段粘贴执行：

```bash
sudo tee /usr/local/sbin/harbor-nginx-reload.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# 主机重启后 Docker 会按自身顺序拉起 restart:always 的容器，
# 容器 IP 可能被重新分配，而 Harbor 的 nginx 只在启动时解析一次 upstream，
# 于是 /api、/c 会被转发到旧 IP（通常是 jobservice），表现为登录页 OIDC 入口消失。
# 本脚本等 core/portal 健康后 reload nginx，让它重新解析 upstream。
set -uo pipefail
for _ in $(seq 1 90); do
  if docker inspect -f "{{.State.Running}}" nginx >/dev/null 2>&1; then
    core=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" harbor-core 2>/dev/null)
    portal=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}" harbor-portal 2>/dev/null)
    if [ "${core:-}" = "healthy" ] && [ "${portal:-}" = "healthy" ]; then
      if docker exec nginx nginx -t >/dev/null 2>&1; then
        docker exec nginx nginx -s reload
        exit $?
      fi
    fi
  fi
  sleep 5
done
echo "harbor-nginx-reload: core/portal 未在 450s 内就绪" >&2
exit 1
EOF
sudo chmod 0755 /usr/local/sbin/harbor-nginx-reload.sh

sudo tee /etc/systemd/system/harbor-nginx-reload.service >/dev/null <<'EOF'
[Unit]
Description=Reload Harbor nginx upstream DNS after boot
Documentation=file:/usr/local/sbin/harbor-nginx-reload.sh
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/harbor-nginx-reload.sh
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now harbor-nginx-reload.service
```

仓库内另存了同样内容的备份：
[../assets/harbor-nginx-reload.sh](../assets/harbor-nginx-reload.sh)、
[../assets/harbor-nginx-reload.service](../assets/harbor-nginx-reload.service)。

验证：

```bash
systemctl status harbor-nginx-reload.service --no-pager
journalctl -u harbor-nginx-reload.service -n 20 --no-pager
```

服务是幂等的，每次开机都会 reload 一次，正常无副作用。

## 5. 排查用命令

执行机器：`ubuntu02`。

```bash
# 容器状态与 IP
docker ps --format '{{.Names}}\t{{.Status}}'
for c in nginx harbor-core harbor-jobservice harbor-portal; do
  printf '%-18s %s\n' "$c" \
    "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $c)"
done

# 三个位置分别测：core 直连 / nginx 解析 / 对外入口
docker exec harbor-core curl -s -o /dev/null -w 'core        %{http_code}\n' \
  http://127.0.0.1:8080/api/v2.0/ping
docker exec nginx curl -s -o /dev/null -w 'nginx->core %{http_code}\n' \
  http://core:8080/api/v2.0/ping
curl -ksS -o /dev/null -w 'entry       %{http_code}\n' \
  https://192.168.67.202:8443/api/v2.0/ping

# 公开接口：应返回 auth_mode/oidc_provider_name，而不是 401
curl -ksS https://192.168.67.202:8443/api/v2.0/systeminfo | jq

# nginx 访问日志（能看到 401 与上游耗时）
docker logs nginx --tail 20
```

## 6. 注意

- 看到 OIDC 按钮消失，先查 `systeminfo` 是否 401，**不要先改 OIDC 配置**。
- 同类表现：登录页没有 SSO 入口、所有 API 401、`/c/login` 401，
  但 `docker ps` 全部 healthy。
- `docker compose down && docker compose up -d` 也能恢复（容器重建、nginx 最后启动），
  但会中断 Harbor；能用 `reload` 就不要 `down`。
- 本次已核对 GitLab OAuth 应用 `harbor` 的 `uid` 与 DB 的 `oidc_client_id` 一致，
  `redirect_uri` 为 `https://192.168.67.202:8443/c/oidc/callback`，不需要重建应用。

## 7. 相关文档

- [../harbor-config-pitfalls.md](../harbor-config-pitfalls.md) 坑 7
- [../harbor-accounts-registry.md](../harbor-accounts-registry.md)
- [../../13-sso-oidc/README.md](../../13-sso-oidc/README.md) 第 5 节 Harbor 原生 OIDC
