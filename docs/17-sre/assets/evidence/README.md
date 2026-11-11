# SRE 证据：本环境实测

对应教程：[`../../10-slo-incident-alerting.md`](../../10-slo-incident-alerting.md)。

## 文件

| 文件 | 内容 |
|---|---|
| `rules-audit.txt` | 251 条告警规则的 severity/for/runbook/分类/SLO 规则 |
| `alertmanager.txt` | 路由、group_by、group_wait、inhibit、receiver 名称（不含 URL/token） |
| `active-alerts.txt` | 当前 firing、持续时间、kube-proxy/Ceph 指标缺失 |
| `alert-hygiene.txt` | 长期 firing、同根因重复、runbook 覆盖率 |
| `slo-compassio.txt` | 总请求/健康检查/业务请求、p99、error budget |
| `incident-cases.md` | 案例 A（重启告警）/案例 B（Ceph full）/变更相关性 |

## 关键数字

```text
告警规则 251：critical 82 / warning 160 / info 7 / none 2
runbook 137/251
SLO/burn 规则 5（4 条 apiserver，业务 0）
当前 firing 7（5 条非 Watchdog，最长 50.9h）

Compassio 7d：
  总请求 93,698,918
  健康+/metrics 93,631,932（99.929%）
  业务 1,948（0.0021%）
  业务 p99 219ms；健康 p99 21ms
  5xx 0、4xx 0
```

## 安全说明

- Alertmanager 证据只保留 route/group/inhibit/receiver 名称，不包含 webhook URL/token；
- 告警规则表达式为集群现状快照；
- 未修改任何告警/路由/规则。
