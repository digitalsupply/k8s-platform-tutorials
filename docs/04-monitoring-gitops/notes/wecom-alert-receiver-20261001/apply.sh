#!/usr/bin/env bash
# ==============================================================================
# 部署「企业微信群机器人适配器」并把 Alertmanager 第二出口切过去
#
# 用法:
#   ./apply.sh --webhook-url 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=XXXX'
#       完整流程: 适配器 + Alertmanager 配置切换 + 端到端实测
#
#   ./apply.sh --webhook-url '...' --no-switch-am
#       只更新适配器（改 key / 改脚本时用），不动 Alertmanager
#
#   ./apply.sh --rollback-am backup/alertmanager.yaml.<ts>
#       把 Alertmanager 基础配置回滚到指定备份
#
#   ./apply.sh --status
#       只看当前状态
#
# 幂等: 重复执行安全。每次改 Alertmanager 配置前会自动备份。
#
# 凭据处理: 群机器人 webhook key 只写进 Secret，不回显、不进日志、不进 git。
# ==============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER_DIR="$HERE/adapter"
NS=monitoring
CM_NAME=wecom-adapter-script
SECRET_NAME=wecom-adapter
DEPLOY=wecom-adapter
AM_SECRET=alertmanager-prometheus-alertmanager
AM_CONFIGMAP=amcfg-check
AM_POD="$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=alertmanager \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
BACKUP_DIR="$HERE/backup"
PLACEHOLDER='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=REPLACE_ME'

WEBHOOK_URL=""
SWITCH_AM=1
ACTION=apply
ROLLBACK_FILE=""

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
info()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[!]\033[0m %s\n' "$*"; }

usage() { sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --webhook-url)  WEBHOOK_URL="${2:-}"; shift 2 ;;
    --no-switch-am) SWITCH_AM=0; shift ;;
    --rollback-am)  ACTION=rollback; ROLLBACK_FILE="${2:-}"; shift 2 ;;
    --status)       ACTION=status; shift ;;
    -h|--help)      usage ;;
    *) echo "未知参数: $1"; usage ;;
  esac
done

# --------------------------------------------------------------------------
# 校验
# --------------------------------------------------------------------------
validate_url() {
  local u="$1"
  if [[ "$u" == "$PLACEHOLDER" || -z "$u" ]]; then
    warn "未提供 webhook URL，使用占位符 —— 适配器会启动但 /healthz 返回 503、"
    warn "/alerts 返回 503。这是「还没拿到 key」的预期状态，不是故障。"
    return 0
  fi
  if ! [[ "$u" =~ ^https://qyapi\.weixin\.qq\.com/cgi-bin/webhook/send\?key=[A-Za-z0-9_-]+$ ]]; then
    red "webhook URL 格式不对。"
    red "  期望: https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<UUID>"
    red "  实际: ${u:0:60}..."
    red "获取方式: 企业微信客户端 -> 目标群 -> 群设置 -> 群机器人 -> 添加 -> 复制 Webhook 地址"
    exit 1
  fi
}

# --------------------------------------------------------------------------
# 状态
# --------------------------------------------------------------------------
show_status() {
  info "适配器"
  kubectl get deploy,svc,cm,secret -n "$NS" \
    -l app.kubernetes.io/name=wecom-adapter 2>/dev/null || true
  kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.webhook-url}' 2>/dev/null \
    | base64 -d 2>/dev/null \
    | sed -E 's/(key=).*/\1<已配置，长度 '"$(kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.webhook-url}' 2>/dev/null | base64 -d 2>/dev/null | wc -c)"'>/' \
    || echo "(Secret 不存在)"
  echo
  kubectl get pods -n "$NS" -l app.kubernetes.io/name=wecom-adapter 2>/dev/null || true

  info "Alertmanager 生效配置"
  if [ -n "$AM_POD" ]; then
    kubectl exec -n "$NS" "$AM_POD" -c alertmanager -- \
      wget -qO- http://127.0.0.1:9093/api/v2/receivers 2>/dev/null || echo "(读取失败)"
    echo
  fi

  info "适配器投递计数 (/stats)"
  local pod
  pod="$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=wecom-adapter \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$pod" ]; then
    kubectl exec -n "$NS" "$pod" -c adapter -- \
      wget -qO- http://127.0.0.1:8080/stats 2>/dev/null || echo "(读取失败)"
    echo
  fi
}

# --------------------------------------------------------------------------
# 部署适配器
# --------------------------------------------------------------------------
deploy_adapter() {
  info "写入脚本 ConfigMap"
  kubectl create configmap "$CM_NAME" -n "$NS" \
    --from-file=adapter.py="$ADAPTER_DIR/adapter.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl label configmap "$CM_NAME" -n "$NS" \
    app.kubernetes.io/name=wecom-adapter \
    app.kubernetes.io/component=alerting-adapter \
    --overwrite >/dev/null
  green "    ConfigMap/$CM_NAME 已更新 ($(wc -c <"$ADAPTER_DIR/adapter.py") 字节)"

  info "写入 webhook key Secret"
  # 临时文件里只放 URL 本体：--from-file 会把整个文件内容当作该 key 的值。
  # （早先误用 --from-file 配 key=value 内容，导致 Secret 值变成
  #   "webhook-url=https://..."，投递时报 unknown url type。）
  # 走文件而非 --from-literal，避免 key 出现在进程列表 (ps) 里。
  printf '%s' "$WEBHOOK_URL" > /tmp/.wecom-hook.$$
  chmod 600 /tmp/.wecom-hook.$$
  kubectl create secret generic "$SECRET_NAME" -n "$NS" \
    --from-file=webhook-url=/tmp/.wecom-hook.$$ \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -f /tmp/.wecom-hook.$$
  kubectl label secret "$SECRET_NAME" -n "$NS" \
    app.kubernetes.io/name=wecom-adapter \
    app.kubernetes.io/component=alerting-adapter \
    --overwrite >/dev/null
  if [ "$WEBHOOK_URL" = "$PLACEHOLDER" ]; then
    warn "    Secret/$SECRET_NAME 已写入占位符（尚未配置真实 key）"
  else
    green "    Secret/$SECRET_NAME 已写入真实 key（不回显）"
  fi

  info "应用 Deployment / Service / NetworkPolicy"
  kubectl apply -f "$ADAPTER_DIR/deployment.yaml" >/dev/null

  # 环境变量只在 Pod 创建时注入：把 webhook key 的哈希写进 Pod 模板注解，
  # 这样换 key 一定会产生 template 变化 -> 触发滚动更新。
  # 不写这一步的话，Secret 改了但 Pod 还拿着旧 key，表现为「改了没反应」。
  local hash
  hash="$(printf '%s' "$WEBHOOK_URL" | sha256sum | cut -c1-16)"
  kubectl patch deploy/"$DEPLOY" -n "$NS" --type=strategic -p "{
    \"spec\": {\"template\": {\"metadata\": {\"annotations\": {
      \"wecom-alert-receiver/secret-hash\": \"$hash\"}}}}}" >/dev/null
  green "    已 apply（secret-hash=$hash）"

  info "等待 rollout"
  if ! kubectl rollout status deploy/"$DEPLOY" -n "$NS" --timeout=180s; then
    red "rollout 失败，事件与日志："
    kubectl get events -n "$NS" --field-selector involvedObject.name="$DEPLOY" \
      --sort-by=.lastTimestamp 2>/dev/null | tail -10
    kubectl logs -n "$NS" -l app.kubernetes.io/name=wecom-adapter -c adapter --tail=30 2>/dev/null || true
    exit 1
  fi
  green "    rollout 完成"
  kubectl get pods -n "$NS" -l app.kubernetes.io/name=wecom-adapter -o wide
}

# --------------------------------------------------------------------------
# 端到端实测（真发一条消息到群里）
# --------------------------------------------------------------------------
smoke_test() {
  if [ "$WEBHOOK_URL" = "$PLACEHOLDER" ]; then
    warn "跳过实测（webhook key 仍是占位符，发出去必然 93000）"
    return 0
  fi
  local pod
  pod="$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=wecom-adapter \
    -o jsonpath='{.items[0].metadata.name}')"

  info "注入一条合成的 firing 负载（会真的发到群里）"
  kubectl exec -i -n "$NS" "$pod" -c adapter -- python3 - <<'PY' 2>&1 | sed 's/^/    /'
import json, urllib.request
payload = {
    "version": "4",
    "groupKey": '{}/{severity="warning"}:{alertname="WeComAdapterSmokeTest"}',
    "status": "firing",
    "receiver": "wecom",
    "commonLabels": {"alertname": "WeComAdapterSmokeTest", "severity": "warning",
                     "namespace": "monitoring"},
    "commonAnnotations": {"summary": "企业微信适配器联通性自检，非真实告警"},
    "externalURL": "http://alertmanager.example.com",
    "alerts": [{
        "status": "firing",
        "labels": {"alertname": "WeComAdapterSmokeTest", "severity": "warning",
                   "namespace": "monitoring", "pod": "wecom-adapter-smoke"},
        "annotations": {"summary": "企业微信适配器联通性自检，非真实告警"},
        "startsAt": "2026-01-01T00:00:00Z",
        "endsAt": "0001-01-01T00:00:00Z",
        "generatorURL": "http://prometheus.example.com",
    }],
}
body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
req = urllib.request.Request("http://127.0.0.1:8080/alerts", data=body,
                             headers={"Content-Type": "application/json"}, method="POST")
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        print("HTTP %s %s" % (r.status, r.read().decode()))
except urllib.error.HTTPError as e:
    print("HTTP %s %s" % (e.code, e.read().decode()))
    raise SystemExit(1)
PY
  green "    群里应该已经收到一条「WeComAdapterSmokeTest」—— 确认一下"
}

# --------------------------------------------------------------------------
# 切换 Alertmanager
# --------------------------------------------------------------------------
switch_am() {
  info "用线上同版本 amtool 校验配置"
  kubectl create configmap "$AM_CONFIGMAP" -n "$NS" \
    --from-file=alertmanager.yaml="$HERE/alertmanager.yaml" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local img
  img="$(kubectl get sts "$AM_SECRET" -n "$NS" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="alertmanager")].image}')"
  [ -z "$img" ] && { red "拿不到 Alertmanager 镜像"; exit 1; }

  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: amcfg-verify
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
  - name: amtool
    image: $img
    command: ["sh","-c","amtool check-config /cfg/alertmanager.yaml && amtool config routes --config.file=/cfg/alertmanager.yaml"]
    volumeMounts: [{name: cfg, mountPath: /cfg, readOnly: true}]
  volumes:
  - name: cfg
    configMap: {name: $AM_CONFIGMAP}
EOF
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/amcfg-verify \
    -n "$NS" --timeout=120s >/dev/null 2>&1 || true
  local out rc=0
  out="$(kubectl logs amcfg-verify -n "$NS" 2>&1)" || rc=$?
  kubectl delete pod amcfg-verify -n "$NS" --ignore-not-found >/dev/null 2>&1
  kubectl delete cm "$AM_CONFIGMAP" -n "$NS" --ignore-not-found >/dev/null 2>&1
  echo "$out" | sed 's/^/    /'
  if [ $rc -ne 0 ] || ! echo "$out" | grep -q SUCCESS; then
    red "    amtool 校验未通过，中止（Alertmanager 未被改动）"
    exit 1
  fi

  info "备份当前线上配置"
  mkdir -p "$BACKUP_DIR"
  local ts bak
  ts="$(date +%Y%m%d-%H%M%S)"
  bak="$BACKUP_DIR/alertmanager.yaml.$ts"
  kubectl get secret "$AM_SECRET" -n "$NS" -o jsonpath='{.data.alertmanager\.yaml}' \
    | base64 -d > "$bak"
  green "    $bak"

  info "写入基础 Secret（config-reloader 会热加载）"
  kubectl patch secret "$AM_SECRET" -n "$NS" --type=merge -p "{
    \"data\": {\"alertmanager.yaml\": \"$(base64 -w0 <"$HERE/alertmanager.yaml" | tr -d '\n')\"}
  }" >/dev/null
  green "    已 patch"

  info "等待 operator 生成 + Alertmanager 加载"
  for i in $(seq 1 24); do
    sleep 5
    local rcv
    rcv="$(kubectl exec -n "$NS" "$AM_POD" -c alertmanager -- \
      wget -qO- http://127.0.0.1:9093/api/v2/receivers 2>/dev/null || echo '')"
    if echo "$rcv" | grep -q 'wecom' && echo "$rcv" | grep -q 'n8n-webhook'; then
      green "    生效 receiver: $rcv"
      return 0
    fi
    if kubectl logs -n "$NS" deploy/prometheus-operator -c kube-prometheus-stack --since=20s 2>/dev/null \
        | grep -qE 'provision alertmanager configuration|failed to initialize from secret'; then
      red "    operator 报错，配置未生效"
      kubectl logs -n "$NS" deploy/prometheus-operator -c kube-prometheus-stack --since=30s 2>/dev/null | tail -5
      red "    回滚: ./apply.sh --rollback-am $bak"
      exit 1
    fi
  done
  red "    超时未生效，回滚: ./apply.sh --rollback-am $bak"
  exit 1
}

rollback_am() {
  [ -f "$ROLLBACK_FILE" ] || { red "备份文件不存在: $ROLLBACK_FILE"; exit 1; }
  info "回滚 Alertmanager 基础配置 <- $ROLLBACK_FILE"
  kubectl create configmap "$AM_CONFIGMAP" -n "$NS" \
    --from-file=alertmanager.yaml="$ROLLBACK_FILE" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: amcfg-verify
  namespace: $NS
spec:
  restartPolicy: Never
  containers:
  - name: amtool
    image: $(kubectl get sts "$AM_SECRET" -n "$NS" -o jsonpath='{.spec.template.spec.containers[?(@.name=="alertmanager")].image}')
    command: ["amtool","check-config","/cfg/alertmanager.yaml"]
    volumeMounts: [{name: cfg, mountPath: /cfg, readOnly: true}]
  volumes:
  - name: cfg
    configMap: {name: $AM_CONFIGMAP}
EOF
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/amcfg-verify -n "$NS" --timeout=120s >/dev/null 2>&1 || true
  local out
  out="$(kubectl logs amcfg-verify -n "$NS" 2>&1)" || true
  kubectl delete pod amcfg-verify -n "$NS" --ignore-not-found >/dev/null 2>&1
  kubectl delete cm "$AM_CONFIGMAP" -n "$NS" --ignore-not-found >/dev/null 2>&1
  echo "$out" | sed 's/^/    /'
  if ! echo "$out" | grep -q SUCCESS; then
    red "    回滚配置校验未通过，未写入"
    exit 1
  fi
  kubectl patch secret "$AM_SECRET" -n "$NS" --type=merge -p "{
    \"data\": {\"alertmanager.yaml\": \"$(base64 -w0 <"$ROLLBACK_FILE" | tr -d '\n')\"}
  }" >/dev/null
  green "    已回滚，等 config-reloader 热加载（约 10 秒）"
  sleep 10
  kubectl exec -n "$NS" "$AM_POD" -c alertmanager -- \
    wget -qO- http://127.0.0.1:9093/api/v2/receivers 2>/dev/null; echo
}

# --------------------------------------------------------------------------
case "$ACTION" in
  status)   show_status ;;
  rollback) rollback_am ;;
  apply)
    [ -f "$ADAPTER_DIR/adapter.py" ] || { red "缺少 $ADAPTER_DIR/adapter.py"; exit 1; }
    [ -f "$ADAPTER_DIR/deployment.yaml" ] || { red "缺少 $ADAPTER_DIR/deployment.yaml"; exit 1; }
    [ "$WEBHOOK_URL" = "" ] && { red "必须提供 --webhook-url（或用 --status）"; usage; }
    validate_url "$WEBHOOK_URL"
    echo "namespace=$NS  deploy=$DEPLOY  am_pod=$AM_POD"
    deploy_adapter
    smoke_test
    if [ "$SWITCH_AM" = "1" ]; then
      switch_am
      echo
      info "投递计数"
      kubectl exec -n "$NS" "$(kubectl get pod -n "$NS" -l app.kubernetes.io/name=wecom-adapter -o jsonpath='{.items[0].metadata.name}')" \
        -c adapter -- wget -qO- http://127.0.0.1:8080/stats 2>/dev/null; echo
    else
      warn "已跳过 Alertmanager 配置切换（--no-switch-am）"
    fi
    echo
    green "完成。"
    ;;
esac