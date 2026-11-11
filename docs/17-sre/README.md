# 17 · SRE：SLO、事故管理与告警设计

> 这一章不教“怎么装 Prometheus”，而是回答：
> **怎么定义用户可感知的 SLO、怎么用燃烧率告警、怎么管理事故和变更。**
>
> 详细章节：[`10-slo-incident-alerting.md`](10-slo-incident-alerting.md)。
> 一句话版本：[15 面试速查 12-sre](../15-interview-cheatsheet/12-sre.md)。

## 本环境现状

| 项 | 实测 |
|---|---|
| 告警规则 | 251 条（critical 82 / warning 160 / info 7 / none 2） |
| 有 runbook | 137 条（54.6%） |
| SLO/burn 规则 | 5 条，4 条是 kube-apiserver；业务 SLO 0 条 |
| 当前 firing | 7 条，5 条非 Watchdog，最长 50.9h |
| Alertmanager | 双出口 n8n+wecom；group_wait 30s；repeat 12h |
| Compassio 7d | 9,370 万请求，99.93% 是健康检查；业务 p99 219ms |
| 业务流量 | 1,948 请求/7d（约 0.003 req/s） |
| Blackbox/Probe | 0 |
| On-call/ack/status page | 未集成 |

## 核心结论

- **SLI 必须排除健康检查**：总请求 p99 21ms，业务 p99 219ms；
- **SLO 先定 99.9%**：单副本/单区域不要承诺 99.99%；
- **业务没有 burn rate 告警**：只有 apiserver 有 4 条；
- **5 条长期 firing 都不是用户症状**：KubeProxyDown 50.9h、Ceph 39h、Alertmanager 39h；
- **同根因不聚合**：group_by 含 alertname，inhibit 只匹配同名；
- **MTTD 比 MTTR 更致命**：重启告警在恢复后仍 firing 16h~1.5d；
- **变更相关**：7 轮改造中 3 轮直接触发故障，另有 kube-proxy 升级导致监控缺口。

## 目录

```text
17-sre/
├── README.md
├── 10-slo-incident-alerting.md
└── assets/
    ├── evidence/
    │   ├── rules-audit.txt
    │   ├── alertmanager.txt
    │   ├── active-alerts.txt
    │   ├── alert-hygiene.txt
    │   ├── slo-compassio.txt
    │   └── incident-cases.md
    ├── slo/compassio-slo-rules.yaml
    └── templates/
        ├── postmortem.md
        ├── status-page.md
        └── sev-matrix.md
```

## 怎么用

1. 先读 [`10-slo-incident-alerting.md`](10-slo-incident-alerting.md) 的 SLI/SLO 和 burn rate；
2. 对照 [`assets/slo/compassio-slo-rules.yaml`](assets/slo/compassio-slo-rules.yaml) 改成自己的指标；
3. 用 [`assets/templates/`](assets/templates/) 做 postmortem/状态页/SEV 分级；
4. 用 [`assets/evidence/`](assets/evidence/README.md) 复现本环境结论。
