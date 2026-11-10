#!/usr/bin/env bash
# 只读验证 GitLab OIDC 与各平台 UI 的登录跳转。
# 依赖：curl；可选 jq。
#
# 用法：
#   bash verify_sso.sh
#   TRAEFIK_VIP=10.0.0.252 GITLAB_URL=http://192.168.67.201 bash verify_sso.sh
set -uo pipefail

GITLAB_URL="${GITLAB_URL:-http://192.168.67.201}"
TRAEFIK_VIP="${TRAEFIK_VIP:-10.0.0.252}"
HARBOR_URL="${HARBOR_URL:-https://192.168.67.202:8443}"

say() { printf '\n== %s ==\n' "$1"; }

say "GitLab OIDC discovery"
curl -sS -m 10 -o /tmp/sso-discovery.json -w 'HTTP %{http_code}\n' \
  "$GITLAB_URL/.well-known/openid-configuration" || true
if command -v jq >/dev/null 2>&1 && [ -s /tmp/sso-discovery.json ]; then
  jq -r '"issuer: " + .issuer, "authorization: " + .authorization_endpoint, "token: " + .token_endpoint, "userinfo: " + .userinfo_endpoint' /tmp/sso-discovery.json
fi

say "oauth2-proxy 保护的 UI（期望 302 到 GitLab）"
for h in hubble alloy tekton; do
  curl -sk -m 10 --resolve "$h.xyz:443:$TRAEFIK_VIP" \
    -o /dev/null -w "$h  HTTP %{http_code}  -> %{redirect_url}\n" "https://$h.xyz/"
done
curl -sk -m 10 --resolve "traefik.xyz:443:$TRAEFIK_VIP" \
  -o /dev/null -w "traefik /dashboard/  HTTP %{http_code}  -> %{redirect_url}\n" \
  "https://traefik.xyz/dashboard/"

say "ArgoCD（期望 303 到 GitLab）"
curl -sk -m 10 --resolve "argocd.devops.com:443:$TRAEFIK_VIP" \
  -o /dev/null -w "argocd  HTTP %{http_code}  -> %{redirect_url}\n" \
  "https://argocd.devops.com/auth/login"

say "Grafana 登录页（期望包含 GitLab）"
body="$(curl -sk -m 10 --resolve "grafana.k8s.local:443:$TRAEFIK_VIP" "https://grafana.k8s.local/login")"
if printf '%s' "$body" | grep -qi gitlab; then
  echo "grafana  OK  (login page contains GitLab)"
else
  echo "grafana  WARN (GitLab button not found; check auth.generic_oauth)"
fi

say "Harbor（期望 302 到 GitLab）"
curl -sk -m 10 -o /dev/null -w "harbor  HTTP %{http_code}  -> %{redirect_url}\n" \
  "$HARBOR_URL/c/oidc/login"
if command -v jq >/dev/null 2>&1; then
  curl -sk -m 10 "$HARBOR_URL/api/v2.0/systeminfo" | jq -r '"auth_mode: " + .auth_mode, "provider: " + .oidc_provider_name' 2>/dev/null || true
fi

say "集群对象"
kubectl -n oauth2-proxy get deploy -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas --no-headers 2>/dev/null || true
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.oidc\.config}' 2>/dev/null | sed -E 's/(clientSecret:).*/\1 <redacted>/' || true
