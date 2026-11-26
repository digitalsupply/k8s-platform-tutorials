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
