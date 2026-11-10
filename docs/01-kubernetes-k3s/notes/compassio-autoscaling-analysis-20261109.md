# Compassio 自动扩缩容分析与落地（HPA vs VPA）

> 日期：2026-11-09  
> 项目：Compassio（FastAPI + PostgreSQL + Redis + LLM）  
> 当前副本：backend 1 / frontend 1  
> 目标：用户多时自动扩到 2 个 backend 副本  
> 结论：**用 HPA，不用 VPA 做副本扩缩；触发条件以“学生真实等待 LLM 的 P95”为主，CPU 为兜底。VPA 只建议用 Off 模式做资源画像。**

---

## 1. 代码分析（为什么不是简单 CPU HPA）

### 1.1 运行时形态

`backend/Dockerfile`：

```dockerfile
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
```

- 每个 Pod 内 **2 个 uvicorn worker**；
- 1 个 Pod = 2 个进程；
- 扩到 2 个 Pod = 4 个 worker。

当前实际资源（1 副本）：

```text
compassio-backend    CPU 7m    MEM 371Mi
requests: cpu 50m / memory 384Mi
limits:   cpu 500m / memory 768Mi
```

CPU 非常低，说明它不是 CPU 密集型服务。

### 1.2 关键请求路径：`GET /api/assess/{id}/next`

`backend/app/routers/assess.py`：

1. 先读预取缓存 `read_next(id)`；
2. 命中且题目未答过 → 直接返回（快路径）；
3. 未命中 → 调用 `pick_next_item(..., observe_llm_wait=True)`；
4. 如果落到 LLM 检查点，记录：

```python
observe_next_llm_wait(duration)
inc_next_cache("miss", reason="llm_blocked")
```

也就是说：

- **学生真正的等待**只在“缓存未命中且走 LLM”时发生；
- 预取后台任务不记入学生等待（`observe_llm_wait=False`）；
- 规则路径/覆盖阶段不记入。

### 1.3 指标定义

`backend/app/observability/metrics.py`：

```text
compassio_next_llm_wait_seconds          # histogram，前台 /next 真实等待 LLM
compassio_next_cache_total{result,reason} # result=miss reason=llm_blocked 直接计数
compassio_http_requests_total             # 请求计数
compassio_http_request_duration_seconds   # 接口延迟
compassio_llm_request_duration_seconds    # LLM 调用耗时
compassio_llm_fallback_total              # LLM 回退次数
compassio_dependency_up{dependency}       # db/redis/llm 可用性
```

`backend/app/engine/adaptive.py`：

```python
if observe_llm_wait:
    observe_next_llm_wait(duration)
```

只有前台 `/next` 才记录学生等待；后台预取不记录。

### 1.4 结论

Compassio 是 **I/O 密集型**（LLM、PostgreSQL、Redis），不是 CPU 密集型：

- 用户多时，CPU 可能仍然很低；
- 单纯 CPU HPA 可能不触发，或者触发过晚；
- 最贴近业务和代码的指标是 **`compassio_next_llm_wait_seconds`** 或
  **`compassio_next_cache_total{reason="llm_blocked"}`**。

---

## 2. HPA 还是 VPA？

| 维度 | HPA | VPA |
|---|---|---|
| 能否扩到 2 个副本 | ✅ 可以 | ❌ 只调整单 Pod 的 requests/limits |
| 高可用 | ✅ 2 个 Pod 跨节点 | ❌ 单 Pod，无冗余 |
| 与单副本 PDB | 配合 `maxUnavailable: 1` | 不解决 |
| 风险 | 需要指标/阈值 | Auto 模式可能重启唯一 Pod |
| 与 HPA 冲突 | - | VPA Auto 与 HPA 同时改 CPU 会冲突 |

**结论：**

- **副本扩缩用 HPA**；
- **VPA 不要用 Auto**。如果要用，用 `updateMode: "Off"` 只做 requests/limits 推荐；
- 当前 VPA 控制器已安装但没有 VPA 对象，可以后续加 Off 模式。

---

## 3. 具体触发条件

### 3.1 主指标：学生真实等待 LLM 的 P95

External metric：

```text
compassio_next_llm_wait_p95
```

PromQL（由 prometheus-adapter 暴露）：

```promql
histogram_quantile(0.95,
  sum by (le) (rate(compassio_next_llm_wait_seconds_bucket{namespace="compassio"}[5m]))
)
and
sum(increase(compassio_next_llm_wait_seconds_count{namespace="compassio"}[5m])) >= 5
or vector(0)
```

含义：

- 只有在 5 分钟内有 **至少 5 次** 学生真实等待 LLM 时才算 P95；
- 没有等待时返回 `0`，避免 HPA 抖动；
- 触发阈值：**P95 > 1.5 秒**。

为什么是 1.5s：

- 现有告警 `CompassioNextLlmWaitHigh` 的阈值是 **P95 > 2s / 10m**；
- HPA 取 1.5s，提前扩容，避免先触发告警；
- 5 次样本 + 5 分钟窗口避免单个慢请求导致误扩。

### 3.2 兜底指标：CPU

```yaml
type: Resource
resource:
  name: cpu
  target:
    type: Utilization
    averageUtilization: 80
```

- 当前 request 50m，80% = **40m**；
- 当前实际 7–8m（约 16%）；
- 用于覆盖“请求处理/序列化/预取任务”导致的 CPU 上升；
- 由于是 I/O 密集型，CPU 不是主触发，只是兜底。

### 3.3 最终 HPA 参数

```yaml
minReplicas: 1
maxReplicas: 2
metrics:
  - external: compassio_next_llm_wait_p95 > 1.5
  - resource: cpu > 80%
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0
    policies: [{type: Pods, value: 1, periodSeconds: 60}]
  scaleDown:
    stabilizationWindowSeconds: 600
    policies: [{type: Pods, value: 1, periodSeconds: 300}]
```

- 1 → 2：最多 1 个 Pod/60s；
- 2 → 1：稳定 10 分钟后，每 5 分钟最多减 1；
- `maxReplicas: 2` 符合“用户多时扩为 2”；
- frontend 是静态 nginx，保持 1 副本，不加 HPA。

---

## 4. 落地实现

### 4.1 prometheus-adapter

安装 `prometheus-adapter` 5.3.0，用于把 Prometheus 指标暴露成 external metric。

**为什么 vendor chart：**

- 上游默认 probe 是 HTTPS `httpGet`；
- adapter 自签证书只覆盖 `localhost/127.0.0.1`；
- kubelet 从 Pod IP 探测时 TLS 校验失败，导致 CrashLoopBackOff；
- vendored chart 已把 liveness/readiness 改为 `tcpSocket: https`。

**为什么固定 worker02：**

- worker01 拉取 `registry.k8s.io/prometheus-adapter` 镜像失败（NotFound）；
- worker02 可以正常拉取；
- 单副本，固定在 worker02。

**为什么关闭默认规则：**

- 默认 `rules.default: true` 会生成大量容器指标；
- HPA 只需要一个 external metric；
- 关闭后 adapter 内存从 OOM（256Mi/512Mi）降到约 **23Mi**；
- 当前 limit 1Gi，实际 23Mi，稳定。

**最终关键 values：**

```yaml
prometheus:
  url: http://prometheus-prometheus.monitoring.svc
  port: 9090
rules:
  default: false
  external:
    - seriesQuery: compassio_http_requests_total{namespace="compassio"}
      resources:
        overrides:
          namespace:
            resource: namespace
      name:
        as: compassio_next_llm_wait_p95
      metricsQuery: |
        histogram_quantile(0.95,
          sum by (le) (rate(compassio_next_llm_wait_seconds_bucket{namespace="compassio"}[5m]))
        )
        and
        sum(increase(compassio_next_llm_wait_seconds_count{namespace="compassio"}[5m])) >= 5
        or vector(0)
resources:
  requests: {cpu: 50m, memory: 256Mi}
  limits:   {cpu: 500m, memory: 1Gi}
replicas: 1
nodeSelector:
  kubernetes.io/hostname: worker02
```

安装：

```bash
helm -n monitoring upgrade --install prometheus-adapter \
  platform/monitoring/prometheus-adapter-chart \
  -f platform/monitoring/prometheus-adapter-values.yaml --wait
```

验证：

```bash
kubectl get apiservice | grep metrics.k8s.io
kubectl get --raw \
  /apis/external.metrics.k8s.io/v1beta1/namespaces/compassio/compassio_next_llm_wait_p95
```

结果：

```json
{"items":[{"metricName":"compassio_next_llm_wait_p95","value":"0"}]}
```

### 4.2 HPA

文件：`compassio-gitops/base/08-hpa.yaml`  
已加入 `base/kustomization.yaml`。

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: compassio-backend
  namespace: compassio
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: compassio-backend
  minReplicas: 1
  maxReplicas: 2
  metrics:
    - type: External
      external:
        metric:
          name: compassio_next_llm_wait_p95
        target:
          type: Value
          value: "1.5"
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 80
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
        - type: Pods
          value: 1
          periodSeconds: 300
```

### 4.3 ArgoCD 与 HPA 的冲突处理

HPA 会修改 Deployment 的 `spec.replicas`，而 ArgoCD Git 里仍是 1。  
如果不处理，`selfHeal` 会把 HPA 扩出来的 2 副本改回 1。

在 `platform-gitops` 的 `compassio` Application 增加：

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    name: compassio-backend
    jsonPointers:
      - /spec/replicas

syncPolicy:
  syncOptions:
    - CreateNamespace=true
    - Prune=false
    - RespectIgnoreDifferences=true
```

- `ignoreDifferences`：忽略副本数差异；
- `RespectIgnoreDifferences=true`：同步时也不把 Git 的 replicas 写回去；
- frontend 不忽略，仍由 Git 固定为 1。

### 4.4 提交记录

```text
compassio-gitops:
  b34953b feat(compassio): add backend HPA scaled by LLM wait

platform-gitops:
  748d9d8 feat(monitoring): add prometheus-adapter for Compassio LLM-wait HPA
  d4618c9 fix(monitoring): stabilize prometheus-adapter for Compassio HPA
```

---

## 5. 验证

### 5.1 HPA 初始状态

```text
NAME                REFERENCE                      TARGETS                 MINPODS MAXPODS REPLICAS
compassio-backend   Deployment/compassio-backend   0/1500m, cpu: 18%/80%   1       2       1
```

- external metric：`0 / 1500m`（1.5 秒在 quantity 里显示为 1500m）；
- CPU：`18% / 80%`；
- `ScalingActive=True`，`ValidMetricFound`；
- 没有触发扩容。

### 5.2 强制扩容测试

为了验证 HPA 和 ArgoCD ignoreDifferences，临时把 CPU target 改成 1%：

```bash
kubectl -n compassio patch hpa compassio-backend --type=json -p '[
  {"op":"replace","path":"/spec/metrics/1/resource/target/averageUtilization","value":1}
]'
```

结果：

```text
t=10s deploy_replicas=1
t=20s deploy_replicas=2   # HPA 扩容成功
```

```text
compassio-backend   2/2   Running
HPA REPLICAS        2
ArgoCD compassio    Synced / Healthy
```

说明：

- HPA 能正常从 1 扩到 2；
- ArgoCD 没有把副本数改回 1，`ignoreDifferences` + `RespectIgnoreDifferences` 生效。

恢复：

```bash
kubectl -n compassio patch hpa compassio-backend --type=json -p '[
  {"op":"replace","path":"/spec/metrics/1/resource/target/averageUtilization","value":80}
]'
kubectl -n compassio scale deploy/compassio-backend --replicas=1
```

最终：

```text
compassio-backend   1/1
HPA                 0/1500m, cpu: 18%/80%
ArgoCD              Synced / Healthy
```

### 5.3 Adapter 稳定性

```text
prometheus-adapter-659886599f-zwdbp   1/1 Running   0 restarts
CPU 4m   MEM 23Mi
```

- 之前 256Mi/512Mi 会被 OOMKilled；
- 关闭默认规则 + 1Gi limit 后稳定；
- external metric 持续可查。

---

## 6. 注意事项与限制

1. **LLM 网关可能才是瓶颈**
   - 扩到 2 个 Pod 后，并发 LLM 调用从 2 worker 变成 4 worker；
   - 如果 LLM 供应商限流/延迟高，扩容不会降低单次请求的 P95，只会提高吞吐；
   - 需要同时看 `compassio_llm_request_duration_seconds`、`compassio_llm_fallback_total`。

2. **预取命中率低时，扩容不一定有效**
   - 现有告警 `CompassioPrefetchIneffective` 已覆盖“miss 高 + 真的等 LLM + Redis 正常”；
   - 如果是 Redis 故障，先修 Redis，不要只扩容。

3. **adapter 固定在 worker02**
   - 单副本；worker02 故障时 external metric 会不可用；
   - HPA 会记录 `FailedGetExternalMetric`，但 CPU 兜底仍可能工作；
   - 后续可把 adapter 改成 2 副本 + 反亲和（镜像需在所有节点可拉取）。

4. **external metric 是集群级 P95**
   - 不是每 Pod 的 P95；
   - 1→2 场景足够；如果以后 maxReplicas 更大，建议改成 per-pod custom metric。

5. **maxReplicas 固定为 2**
   - 符合当前“用户多时扩为 2”的需求；
   - 用户继续增长时，需要同时调整 ResourceQuota（当前 requests.cpu 1 / memory 3Gi）；
   - 2 个 backend 的资源：2×50m CPU / 2×384Mi 内存，仍在配额内。

6. **frontend 不加 HPA**
   - 静态 nginx，CPU 1m；
   - 单副本足够；如果静态资源流量成为瓶颈，再单独加 HPA。

7. **VPA 建议**
   - 不要用 VPA Auto；
   - 如需资源画像，加 `updateMode: "Off"` 的 VPA，观察推荐值后再手动调整 requests/limits。

8. **PDB**
   - 当前 `maxUnavailable: 1`；
   - 2 副本时允许驱逐 1 个，适合单节点维护；
   - 1 副本时也允许驱逐（会短暂不可用），符合低用量取舍。

---

## 7. 回滚

### 7.1 回滚 HPA

```bash
# 从 compassio-gitops 删除 base/08-hpa.yaml 和 kustomization 引用
git revert <hpa-commit>
```

ArgoCD 同步后 HPA 删除，Deployment 保持 Git 的 1 副本。

### 7.2 回滚 ArgoCD ignoreDifferences

从 `platform-gitops/clusters/prod/applications/existing-apps.yaml` 的 `compassio` app 删除：

```yaml
ignoreDifferences: ...
- RespectIgnoreDifferences=true
```

### 7.3 回滚 prometheus-adapter

```bash
helm -n monitoring uninstall prometheus-adapter
```

并从 Git 删除：

```text
platform/monitoring/prometheus-adapter-chart/
platform/monitoring/prometheus-adapter-values.yaml
```

### 7.4 回到 1 副本

```bash
kubectl -n compassio scale deploy/compassio-backend --replicas=1
```

---

## 8. 建议的后续验证（不烧 LLM 额度）

1. 用 **staging/LLM mock** 生成 `/next` 负载，观察：
   - `compassio_next_llm_wait_seconds` P95；
   - `compassio_next_cache_total{reason="llm_blocked"}` 速率；
   - HPA 1→2 和 2→1 的时间。
2. 观察 `compassio_llm_request_duration_seconds`：
   - 如果扩容后 LLM 耗时不变、等待下降 → 扩容有效；
   - 如果 LLM 耗时上升 → 供应商限流，扩容无效。
3. 监控 adapter：
   - `process_resident_memory_bytes` < 1Gi；
   - 重启次数 = 0；
   - external metric API 可用。
4. 监控 HPA 事件：
   - `FailedGetExternalMetric` 应为 0；
   - `SuccessfulRescale` 只在真实等待/CPU 高时出现。

---

## 9. 一句话总结

**用 HPA，不用 VPA 做副本扩缩。**  
主触发条件是代码里真实存在的 `compassio_next_llm_wait_seconds` P95 > 1.5s（5 分钟内至少 5 次等待），CPU 80% 作为兜底；`minReplicas=1 / maxReplicas=2`，缩容稳定 10 分钟。  
已通过 prometheus-adapter 暴露 external metric，并在 `compassio-gitops` 落地 HPA；ArgoCD 通过 `ignoreDifferences` + `RespectIgnoreDifferences` 不覆盖 HPA 的副本数。实测可正常 1→2，恢复后回到 1。
