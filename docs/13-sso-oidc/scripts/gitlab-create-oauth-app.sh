#!/usr/bin/env bash
# 在 GitLab 上创建 Grafana 的 OAuth Application，并把 client secret 直接加密成 SealedSecret。
#
# 用法：
#   export GITLAB_TOKEN='<admin api token>'
#   export GITLAB_URL='http://192.168.67.201'          # 可选
#   export GRAFANA_URL='https://grafana.k8s.local'     # 可选
#   ./scripts/gitlab-create-grafana-oauth-app.sh
#
# 说明：
#   - GitLab 创建 Application 后 secret 只返回一次，脚本会写入 /tmp（600）并立刻 seal；
#   - 脚本不会把 secret 打印到终端；
#   - 如果同名 Application 已存在，脚本会停止并提示手工处理（GitLab 无法找回旧 secret）。

set -euo pipefail

GITLAB_URL="${GITLAB_URL:-http://192.168.67.201}"
GITLAB_TOKEN="${GITLAB_TOKEN:?请先 export GITLAB_TOKEN=<gitlab admin api token>}"
GRAFANA_URL="${GRAFANA_URL:-https://grafana.k8s.local}"
APP_NAME="${APP_NAME:-grafana}"
REDIRECT_URI="${REDIRECT_URI:-${GRAFANA_URL}/login/generic_oauth}"
SCOPES="${SCOPES:-openid profile email}"
SECRET_JSON="$(mktemp /tmp/gitlab-${APP_NAME}-oauth.XXXXXX.json)"
SEALED_OUT="${SEALED_OUT:-platform/monitoring/stack/sealedsecret-grafana-oauth.yaml}"

umask 077
cleanup() { rm -f "$SECRET_JSON"; }
trap cleanup EXIT

echo "==> 检查 GitLab 连接与权限"
curl -sf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/personal_access_tokens/self" >/dev/null

echo "==> 检查是否已存在同名 Application"
EXISTING_ID="$(curl -sf -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/applications" \
  | python3 -c "
import json,sys
name=sys.argv[1]
apps=json.load(sys.stdin)
for a in apps:
    if a.get('application_name')==name:
        print(a.get('application_id') or a.get('uid') or a.get('id'))
        break
" "$APP_NAME")"

if [ -n "${EXISTING_ID}" ]; then
  echo "!! 已存在名为 ${APP_NAME} 的 Application（client_id=${EXISTING_ID}）" >&2
  echo "!! GitLab 不会再次返回 secret。若 secret 丢失，请先在 GitLab 删除该 Application 再重跑本脚本。" >&2
  exit 1
fi

echo "==> 创建 OAuth Application"
HTTP_CODE="$(curl -s -o "$SECRET_JSON" -w '%{http_code}' \
  -X POST -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${GITLAB_URL}/api/v4/applications" \
  --data-urlencode "name=${APP_NAME}" \
  --data-urlencode "redirect_uri=${REDIRECT_URI}" \
  --data-urlencode "scopes=${SCOPES}" \
  --data-urlencode "confidential=true")"

if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
  echo "!! 创建失败，HTTP ${HTTP_CODE}" >&2
  cat "$SECRET_JSON" >&2
  exit 1
fi

CLIENT_ID="$(python3 -c "import json;print(json.load(open('$SECRET_JSON'))['application_id'])")"
python3 -c "import json,sys; d=json.load(open('$SECRET_JSON')); sys.exit(0 if d.get('secret') else 1)" \
  || { echo "!! GitLab 未返回 secret" >&2; exit 1; }

echo "client_id (写入 values.yaml): ${CLIENT_ID}"

echo "==> 生成 SealedSecret：${SEALED_OUT}"
kubectl -n monitoring create secret generic "${APP_NAME}-oauth" \
    --dry-run=client -o yaml \
    --from-literal=client-secret="$(python3 -c "import json;print(json.load(open('$SECRET_JSON'))['secret'])")" \
| kubeseal \
    --namespace monitoring \
    --name "${APP_NAME}-oauth" \
    --controller-name sealed-secrets-controller \
    --controller-namespace kube-system \
    --format yaml \
> "${SEALED_OUT}"

echo "==> 完成"
echo "下一步："
echo "  1. 把 platform/monitoring/values.yaml 里 auth.generic_oauth.client_id 设为 ${CLIENT_ID}"
echo "  2. git add ${SEALED_OUT} platform/monitoring/values.yaml && git commit && git push"
echo "  3. 等 ArgoCD 同步后验证登录页出现 Sign in with GitLab"
