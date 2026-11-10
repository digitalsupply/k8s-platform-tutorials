# Grafana Logs Drilldown 502 修复报告

> 日期：2026-11-09  
> 集群：Kubernetes v1.35.9 / Cilium 1.20.4  
> 组件：Grafana 12.4.3、Loki 3.6.7（chart 6.55.0）、Alloy 1.13.0  
> 结果：✅ Logs Drilldown 恢复正常，修复已提交 GitOps

---

## 1. 现象

Grafana 的 `Drilldown → Logs` 页面可以打开，但面板空白/报错。Grafana 日志：

```text
GET /api/datasources/uid/dfi90c2a1osn4c/resources/index/volume  status=500
GET /api/datasources/uid/dfi90c2a1osn4c/resources/drilldown-limits status=500
error="client: failed to call resources: <html><title>502 Bad Gateway</title>
       <center>nginx/1.29.8</center>"
duration=30.0s
```

Loki gateway 日志：

```text
[error] loki-read.logging.svc.cluster.local could not be resolved
        (110: Operation timed out)
```

## 2. 根因

`loki-gateway`（nginx）的 `resolver` 默认是：

```nginx
resolver kube-dns.kube-system.svc.cluster.local.;
```

在 CNI/conntrack 切换后，已有的 nginx worker 进程 UDP resolver socket 状态失效：

- 从 gateway Pod 里 `getent` / `nslookup` 正常；
- 直接访问 `loki-read:3100` 正常（200）；
- 通过 nginx `127.0.0.1:8080/loki/api/v1/*` 全部等待 30s 后 502。

即：**只有 nginx 内部 resolver 坏了**，不是 CoreDNS、不是 Loki、也不是 Grafana 数据源配置。

临时验证与恢复：

```bash
kubectl -n logging exec deploy/loki-gateway -- \
  curl -s -m 5 -o /dev/null -w '%{http_code}\n' \
  -H 'X-Scope-OrgID: fake' \
  http://loki-read.logging.svc.cluster.local:3100/loki/api/v1/labels
# 200

kubectl -n logging exec deploy/loki-gateway -- \
  curl -s -m 35 -o /dev/null -w '%{http_code}\n' \
  -H 'X-Scope-OrgID: fake' \
  http://127.0.0.1:8080/loki/api/v1/labels
# 502

kubectl -n logging exec deploy/loki-gateway -- kill -HUP 1
# 之后同样的请求返回 200
```

## 3. 修复内容

### 3.1 GitOps 提交

仓库：`http://192.168.67.201/digitalsupply/platform-gitops.git`  
Commit：`ea98fb8 fix(logging): harden Loki gateway resolver and capture config drift`

新增：

```text
platform/logging/values.yaml
platform/logging/README.md
```

关键配置：

```yaml
gateway:
  nginxConfig:
    resolver: "10.96.0.10 valid=10s"
  livenessProbe:
    httpGet:
      path: /loki/api/v1/labels
      port: http-metrics
      httpHeaders:
        - name: X-Scope-OrgID
          value: fake
    initialDelaySeconds: 60
    periodSeconds: 60
    timeoutSeconds: 10
    failureThreshold: 5
```

同时把两处历史手工漂移写回 Git：

- `chunksCache.allocatedMemory: 700`、`resultsCache.allocatedMemory: 350`
- `loki.compactor` / `loki.limits_config` 的 120h retention

### 3.2 执行 Helm 升级

```bash
helm -n logging upgrade loki /root/.cache/helm/repository/loki-6.55.0.tgz \
  --reuse-values \
  -f platform/logging/values.yaml \
  --timeout 10m --wait
```

结果：

```text
REVISION: 3
STATUS: deployed
```

> `--reuse-values` 必须保留：S3 凭据只在 Helm release 中，不在 Git。
> 由于 ConfigMap 文本顺序变化，Loki backend/read/write 和两个 memcached 进行了一次滚动重启。

## 4. 验证

### 4.1 Gateway

```text
resolver 10.96.0.10 valid=10s;

labels  = 200  0.009s
limits  = 200  0.004s
volume  = 200  0.012s
```

近 60 秒 gateway 502 = 0；resolver 错误 = 0。

### 4.2 写入/读取

```text
POST /loki/api/v1/push        -> 204
query_range {job="drilldown-selftest"} -> 1 条日志
/api/v1/labels                -> 200
```

### 4.3 Grafana

```text
/api/datasources/uid/dfi90c2a1osn4c/resources/drilldown-limits   -> 200
/api/datasources/uid/dfi90c2a1osn4c/resources/index/volume       -> 200
/a/grafana-lokiexplore-app/explore                               -> 200
plugin grafana-lokiexplore-app enabled=true version=1.0.37
```

### 4.4 保留策略未丢失

```yaml
compactor:
  retention_enabled: true
  retention_period: 120h
limits_config:
  retention_period: 120h
  max_query_lookback: 120h
  reject_old_samples_max_age: 120h
  volume_enabled: true
```

### 4.5 ArgoCD

```text
app-of-apps        Synced  Healthy
platform-grafana   Synced  Healthy
platform-metallb   Synced  Healthy
platform-cilium-l2 Synced  Healthy
```

## 5. 回滚

```bash
helm -n logging history loki
helm -n logging rollback loki <revision>
```

临时恢复 gateway（不升级）：

```bash
kubectl -n logging exec deploy/loki-gateway -- kill -HUP 1
```

## 6. 备份

```text
/root/logging-drilldown-fix-20261109/
├── loki-values-before.yaml
├── loki-manifest-before.yaml
├── loki-configmaps-before.yaml
└── loki-gateway-deploy-before.yaml
```
