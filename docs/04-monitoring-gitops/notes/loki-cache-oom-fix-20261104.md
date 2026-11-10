# Loki chunks-cache OOMKill 修复记录（2026-11-04）

## 一、现象

`logging/loki-chunks-cache-0` 的 `memcached` 容器被 OOMKill（exit 137），告警 `PodOOMKilled` 持续 firing。用户反馈"又报了"。

实测：

```
restarts=2  lastState.terminated.reason=OOMKilled  exitCode=137
finishedAt=2026-11-03T07:25:17Z   startedAt=2026-10-19T14:25:38Z
```

即上一轮运行 **15 天** 后被 OOM，重启后缓存清空、从零开始再涨——所以表现为"每隔约两周报一次"。

## 二、根因（配置自相矛盾，不是节点内存不足）

| 项 | 值 |
|---|---|
| memcached 启动参数 | `-m 8192`（缓存上限 8 GiB） |
| 容器 memory limit | **1 Gi** |
| 节点 worker02 内存 | 6.3 Gi 已用 / 64%，**有富余** |

memcached 按 `-m` 目标持续占用内存（它认为可用 8 GiB），容器在 1 Gi 处被内核 OOMKill —— 缓存永远填不到 8 GiB，所以**必然周期性死亡**。

同类隐患（同时存在）：

| StatefulSet | `-m` | limit | 状态 |
|---|---|---|---|
| `loki-chunks-cache` | 8192 MiB | 1 Gi | **已 OOM 2 次** |
| `loki-results-cache` | 1024 MiB | 512 Mi | 尚未 OOM（上限是限制的 2 倍，一填满就会） |

来源：Helm release `loki`（chart `loki-6.55.0`），values 里只设了 `resources.limits.memory`，没设 `chunksCache.allocatedMemory / resultsCache.allocatedMemory`，于是 chart 默认的 8192/1024 被写进启动参数。

## 三、修复

按"memcached 目标 ≈ 容器 limit 的 70%"调整（缓存改为 LRU 淘汰，不再 OOM）：

```bash
kubectl -n logging patch sts loki-chunks-cache  --type='json' -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args/0","value":"-m 700"}]'
kubectl -n logging patch sts loki-results-cache --type='json' -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args/0","value":"-m 350"}]'
```

生效验证（容器内 `stats`）：

```
loki-chunks-cache  limit_maxbytes 734003200  (=700 MiB, limit 1Gi)
loki-results-cache limit_maxbytes 367001600  (=350 MiB, limit 512Mi)
```

两个 StatefulSet 滚动重启后 `2/2 Running`，Loki 业务无中断：
`loki_distributor_lines_received_total` ≈ **31 行/秒**、`bytes_received` ≈ 9.3 KB/s，`loki-read/write/backend/canary` 的 `up` 全为 1。

**注意（Helm 升级会回滚该修改）**：`loki` 由 Helm 管理，`helm upgrade --reuse-values` 会用 values 里的默认值重写 `-m`。因此另存了覆盖文件，升级时必须带上：

```yaml
# /root/loki-values-cache-fix.yaml
chunksCache:
  allocatedMemory: 700     # MiB，容器 limit 1Gi
resultsCache:
  allocatedMemory: 350     # MiB，容器 limit 512Mi
```

```bash
helm upgrade loki grafana/loki -n logging -f /root/loki-values-cache-fix.yaml --reuse-values
```

## 四、告警侧的两个问题（一并修了）

### 1) `PodOOMKilled` 永不恢复 → "为什么一直报"

原表达式：

```promql
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
```

`last_terminated_reason` 是**"历史上最后一次终止原因"**，OOM 之后一直为 1，pod 恢复、缓存正常也照样 firing —— 观感就是"又报了/一直在报"。

改为"仅最近 15 分钟内发生才告警"，恢复后自动消失：

```promql
(time() - max by (namespace, pod, container) (kube_pod_container_status_last_terminated_timestamp) < 900)
  and on (namespace, pod, container)
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
```

改后状态：`PodOOMKilled  state=inactive  health=ok`（上次 OOM 在 1 天前，已不满足 15 分钟窗口）。

### 2) 新增防复发规则 `MemcachedLimitAboveContainerLimit`

```promql
memcached_limit_maxbytes_bytes
  > on (namespace, pod) group_left (container)
    kube_pod_container_resource_limits{resource="memory", container="memcached"}
```

只要有人再配出"`-m` 大于容器 limit"就立刻告警，从源头拦住这类故障。当前状态 `health=ok / inactive`（已修正的两处都不再触发）。

所在 PrometheusRule：`monitoring/cluster-wide-alerts`，新增组 `cache-config.rules`。

## 五、结论

- **根因**：`-m 8192` 与 `1Gi` 限制自相矛盾 → 缓存涨满必被 OOMKill，约两周一轮。
- **修复**：`-m` 降到 limit 的 ~70%（700/350 MiB），改由 memcached 自身 LRU 淘汰，**不再可能 OOM**。
- **告警**：`PodOOMKilled` 改为 15 分钟窗口（可自愈）；新增 `MemcachedLimitAboveContainerLimit` 防同类配置再次出现。
- **遗留风险**：`helm upgrade loki` 会回滚 `-m`，务必带 `/root/loki-values-cache-fix.yaml`。
