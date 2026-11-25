#!/usr/bin/env bash
# 为 Headlamp 用户签发 k8s Bearer Token。
#
# 用法:
#   ./get-token.sh <root|bigdev> [有效期，默认 24h]
#
# 例:
#   ./get-token.sh root 8h
#   ./get-token.sh bigdev 24h
#
# 需要一份能创建 ServiceAccount token 的 kubeconfig（通常是管理员）。
# token 输出到 stdout，提示信息输出到 stderr，方便管道使用：
#   ./get-token.sh bigdev 24h | xclip -selection clipboard
set -euo pipefail

USER_NAME="${1:-}"
DURATION="${2:-24h}"

case "$USER_NAME" in
  root)   SA="headlamp-root" ;;
  bigdev) SA="headlamp-bigdev" ;;
  *)
    echo "用法: $0 <root|bigdev> [24h]" >&2
    exit 1
    ;;
esac

if ! command -v kubectl >/dev/null 2>&1; then
  echo "错误: 找不到 kubectl" >&2
  exit 1
fi

if ! kubectl -n headlamp get serviceaccount "$SA" >/dev/null 2>&1; then
  echo "错误: 找不到 ServiceAccount headlamp/$SA" >&2
  echo "请先确认 ArgoCD 应用已同步:" >&2
  echo "  kubectl -n argocd get app platform-headlamp" >&2
  exit 1
fi

TOKEN="$(kubectl -n headlamp create token "$SA" --duration="$DURATION")"

cat >&2 <<EOF
用户      : $USER_NAME
K8s 身份  : system:serviceaccount:headlamp:$SA
有效期    : $DURATION
登录地址  : https://headlamp.devops.com

步骤:
  1. 浏览器打开上面的地址，先走 GitLab 登录（需要 digitalsupply 组）；
  2. 在 "Headlamp Cluster Authentication" 输入框粘贴下面这行 JWT；
  3. 点 Authenticate。

注意: token 等同于该身份的密码，不要写进文档、聊天记录或代码仓库。
EOF

printf '%s\n' "$TOKEN"
