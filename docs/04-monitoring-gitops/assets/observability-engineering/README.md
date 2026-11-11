# 可观测性工程：本环境实测

对应教程：[`../../10-observability-engineering.md`](../../10-observability-engineering.md)。

## 证据

| 文件 | 内容 |
|---|---|
| `evidence/tsdb-status.txt` | Prometheus 3.11.2、26 万 head series、top metric/label、RSS、存储、churn |
| `evidence/cardinality-sources.txt` | `path`/`id`/`uid`/`container_id` 的高基数 metric 与 series 数 |
| `evidence/cardinality-oom-lab.txt` | 15 万合成 series + 128Mi limit → OOMKilled exit 137 |
| `evidence/promql-pitfalls.txt` | `rate[10s/30s/1m]`、`irate` vs `rate`、`histogram_quantile` 聚合、bucket 列表 |
| `evidence/rule-audit.txt` | 345 条规则：短窗口 0、无聚合 histogram 4、高基数 group by 52 |
| `evidence/layered-monitoring.txt` | 黑盒 0、白盒 52 job、业务指标值 |
| `evidence/logs-lifecycle.txt` | Loki 5d、0.6GB/天、Alloy 无 JSON/采样 |
| `evidence/logs-rotation.txt` | kubelet 10Mi×5、14 个轮转文件、logrotate weekly×4 |
| `evidence/traces-sampling.txt` | OTel 0.145.0 仅 batch、无采样、Tempo 6.8 万 span/天、spanmetrics 0 |
| `evidence/cost-baseline.txt` | 每 series 内存/磁盘、日志/追踪量、成本结论 |
| `evidence/kube-proxy-leftover-fix.txt` | Cilium KPR 后 kubeProxy.enabled 残留与清理前后 |

## 复现实验

`lab/cardinality-oom.yaml`：

```bash
kubectl apply -f lab/cardinality-oom.yaml
kubectl -n cardinality-lab get pod -w
# 约 30-90s 内 prometheus 容器 OOMKilled，restartCount 增长
kubectl -n cardinality-lab describe pod cardinality-lab | grep -A3 "Last State"
kubectl delete ns cardinality-lab
```

> 实验会创建 15 万 series，限制 128Mi，**不要在生产 Prometheus 上做**；
> 跑完立即删 namespace。

## 关键结论

- 26 万 series、17.9GB/15d、RSS 1.57GiB/4GiB；apiserver 占约 49%；
- 24h series 从 22.9 万涨到 26 万（+13.5%），每小时创建 7.2k、删除 0.66k；
- `user_id`/`uid`/`container_id`/`path` 是典型高基数来源；
- 15 万 series + 128Mi → OOMKilled，证明基数直接决定内存；
- `[30s]` 窗口 `rate()` 无结果；30s scrape 至少用 `[2m]`；
- 不聚合的 `histogram_quantile` 返回 188 条、122 条 NaN；`sum by (le)` 后才是全局 p99；
- 黑盒监控缺失（0 Probe / 无 blackbox）；白盒 52 job；
- Loki 0.6GB/天、5d；Alloy 没做 JSON 解析/采样；kubelet 默认 10Mi×5 轮转；
- OTel 仅 batch、无采样；Tempo 6.8 万 span/天，但 spanmetrics 0 series；
- 无 Thanos/VM/Mimir，只有 Prometheus 本地 15d。
