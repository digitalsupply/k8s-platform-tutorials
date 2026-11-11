# G4 审计发现：docs/04-monitoring-gitops（含 notes/、assets/、manifests/）

> 审计基准：[`../assets/ground-truth.md`](../assets/ground-truth.md)（2026-11-11 实测）。所有 kubectl / PromQL 均为只读。
> 共 24 条：高 7 / 中 12 / 低 5，按严重度排序。

---

### [高] 新规则示例只要求 `release: prometheus`，缺 `platform.gitops/managed` —— 照抄必被 Prometheus 忽略
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:883（另见 :896、:1255、:1871、:2201、:2270）
- 原文: 「`release: prometheus          # ← 必须！Prometheus CR 的 ruleSelector 匹配这个 label`」；「⚠️ **没有 `release: prometheus` 这个 label 的 PrometheusRule 不会被加载**（`ruleSelector.matchLabels: {release: prometheus}`）」
- 问题: 集群实际 `ruleSelector` 是 `{release: prometheus, platform.gitops/managed: "true"}` 两个标签 AND，只写 `release` 的 CR 会被静默丢弃（Operator 不报错、Prometheus 不加载、`/api/v1/rules` 里根本看不到）。本目录其它文档（`prometheus-alertmanager-ops-guide.md:645`、`manifests/README.md:37-41`、`04-current-state.md:44-47`）都写对了两个标签，只有这篇教程写错，且它是"从零写告警"的主教材。后果最直接的一处是 §11.4 全链路自检（:1831 `labels: {release: prometheus}`）—— 那条自检规则永远不会 firing，于是"唯一能证明告警真发得出去"的步骤变成假通过。
- 证据/正确说法: `kubectl -n monitoring get prometheus prometheus-prometheus -o jsonpath='{.spec.ruleSelector}'` → `{"matchLabels":{"platform.gitops/managed":"true","release":"prometheus"}}`；`kubectl get prometheusrules -A -o json | jq` 实测 44/44 都带 `platform.gitops/managed=true`。正确写法：两个标签都要写；或改用 `kubectl apply -k rules/`（`manifests/rules/kustomization.yaml` 的 patch 会自动补 `platform.gitops~1managed: "true"`，已用 `kubectl kustomize rules` 验证输出含两个标签）。

---

### [高] `sum(...) offset 1d` 不是合法 PromQL，示例直接 parse error
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:720
- 原文: 「`sum(rate(http_requests_total[15m])) > 1.3 * sum(rate(http_requests_total[15m])) offset 1d`」
- 问题: `offset` 只能紧跟 instant/range vector selector 或子查询，不能挂在聚合/函数结果后面。该表达式在 Prometheus 3.11.2 上直接报语法错误，抄进去既不会算错、也不会告警，只会 `health=err`。§14.1 的 20 个坑里没有这一条，所以读者没有二次防线。
- 证据/正确说法: `curl -sG http://10.111.41.17:9090/api/v1/query --data-urlencode 'query=sum(rate(apiserver_request_total[5m])) offset 1d'` → `parse error: offset modifier must be preceded by an instant vector selector or range vector selector or a subquery`。正确写法：把 offset 放进选择器 —— `sum(rate(http_requests_total[15m] offset 1d))`（对照：`sum(rate(apiserver_request_total[5m]))` 正常返回 29.16）。

---

### [高] burn rate 四档的"多久烧光预算"全部算错，量级差 50 倍
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:2111-2122
- 原文: 「档位 1（fast，for: 2m）：14.4 倍速烧，**1 小时就能烧光全部预算**」；「档位 2：6 倍速，**6 小时烧光**」；「档位 3：3 倍速，**1 天烧光**」；「档位 4：1 倍速，**3 天烧光**」
- 问题: 30 天 SLO 下，"1 倍速"= 30 天烧完全部预算。14.4× 的正确含义是"**1 小时烧掉 2% 预算**"（14.4/720），不是"1 小时烧光"；6× 是 6 小时烧 5%；3× 是 1 天烧 10%；1× 是 3 天烧 10%。四条全错，且错的方向一致（把"窗口长度"当成"烧光时间"）。据此调参会把真正的 2% 事件当成"预算清零"而惊动全员，也会把 1× 的慢性泄漏误判成"3 天必挂"。
- 证据/正确说法: 预算比例 = burnrate × 窗口/30d。14.4 × 1h/720h = 2%；6 × 6/720 = 5%；3 × 24/720 = 10%；1 × 72/720 = 10%。这正是 Google SRE Workbook "Multiwindow, Multi-Burn-Rate Alerts" 表的 2%/5%/10% 三档。同一文件 :2131 对燃烧率定义（"实际错误率 ÷ 预算错误率"）的表述是对的，与这里的时间换算自相矛盾。

---

### [高] SLO 模板的录制规则缺分母，算出来的是"错误数/秒 ÷ 0.01"而不是燃烧率
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:2148-2155
- 原文: 「`- record: myservice:http_requests:burnrate5m` / `expr: |` / `  sum(rate(myservice_http_requests_total{status=~"5.."}[5m]))` / `  / 0.01    # SLO 99% → 允许 1% 错误率`」
- 问题: 燃烧率 = 错误率 / (1-SLO) = [5xx 速率 ÷ 总请求速率] ÷ 0.01。模板漏掉了 `sum(rate(...total[5m]))` 这个分母，得到的是"每秒 5xx 条数 ×100"，量纲完全不对，和后面的 `> 14.4` 阈值不可比：业务量 1000 QPS 时只要 0.15 条/秒 5xx（0.015% 错误率，远未超 SLO）就会触发 critical。文档自己在 :2131 把定义写对了，模板却写错，属"照抄即误报"。
- 证据/正确说法: 正确写法：`sum(rate(myservice_http_requests_total{status=~"5.."}[5m])) / sum(rate(myservice_http_requests_total[5m])) / 0.01`。可对照集群里真实的上游录制规则 `apiserver_request:burnrate5m`（`kubectl get prometheusrule prometheus-kube-prometheus-apiserver-burnrate.rules -n monitoring -o yaml`，分子分母都是 `sum(rate(...))`）。

---

### [高] 告警规则的 CNI 假设已过期：`KubeProxyDown` 正在永久 firing，文档仍把 kube-proxy 当有效监控
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:179（另见 :1104、:2430）；docs/04-monitoring-gitops/04-current-state.md:37-38
- 原文: 「`kubelet 18 | apiserver 3 | alloy 6 | node-exporter 6 | kube-etcd 3` / `| kube-proxy 6 | ...`」；「`prometheus-kubernetes-system-kube-proxy | 1 | critical | 15m | 上游`」；04-current-state：「Prometheus 加载 | 68 groups / 251 alerting rules」「health 异常 | 0」
- 问题: 集群 CNI 已是 Cilium 1.20.4 且启用了 kube-proxy replacement，kube-system 里没有 kube-proxy（也没有任何 kube-proxy target）。上游规则 `KubeProxyDown = absent(up{job="kube-proxy"})` 因此**永久成立**，现在就是 critical firing 状态。文档一边把"kube-proxy 6 个 target"当作实测输出，一边把 `health 异常 0` 当作健康结论，掩盖了这条常驻误报——而这类"永远红的 critical"正是本目录反复警告的告警疲劳源头。
- 证据/正确说法: `count(up{job=~".*kube-proxy.*"})` → 空（0 个 target）；`kubectl -n kube-system get ds` → 只有 `cilium`(6/6) 与 `kube-vip-ds`(3/3)；`curl /api/v1/alerts` 命中 `KubeProxyDown alertstate=firing severity=critical`。正确说法：kube-proxy 已移除，`KubeProxyDown` 应删除或改为 `absent(up{job="kube-proxy"}) and on() kube_node_info` 之类的"仅在存在该组件时判定"，并在文档中登记为已知死规则。

---

### [高] "CNI 覆盖"三条规则全部针对 Calico，在 Cilium 集群里是死规则
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:1076-1077、:2392、:2398（规则实体见 manifests/rules/coverage-gap-alerts.yaml、manifests/rules/bsm-coverage-alerts.yaml）
- 原文: 「L0 覆盖盲区补位 `coverage-gap-alerts(11)` / `bsm-coverage-alerts(12)`（**CNI**、ArgoCD、Loki、MetalLB、kube-vip、默认ns） ← 专治"没人管"」；规则名 `CalicoNodeNotReady`、`CalicoKubeControllersDown`、`CNIComponentNotReady`
- 问题: 三条规则的表达式都是 `sum by (pod) (kube_pod_status_ready{namespace="kube-system",pod=~"calico-node-.*",condition="true"}) < 1` 一类写法。集群里没有 calico Pod（CNI 已换 Cilium），聚合结果为空向量，`< 1` 不产生任何序列 → 永不触发。文档把它当作"CNI 这一层已经补上了"的核心证据，实际是 3 条哑告警；`CNIComponentNotReady` 与 `CalicoNodeNotReady` 还是完全相同的表达式（重复规则）。Cilium 侧只有 `up{job=~".*cilium.*"}`（8 个 target）在采集，没有任何就绪性/丢包告警。
- 证据/正确说法: `count(up{job=~".*calico.*"})` → 空；`count(up{job=~".*cilium.*"})` → 8；`kubectl get prometheusrules -A -o json` 里上述三条 expr 原样为 `pod=~"calico-node-.*"`。正确做法：改为 `kube_pod_status_ready{namespace="kube-system",pod=~"cilium-.*"}` + `cilium_operator_*`/`cilium-dbg status` 导出的健康指标，或直接删掉并登记。

---

### [高] wecom 的 `apply.sh` 语法错误、根本无法执行（脱敏吃掉引号 + 把 StatefulSet 名也脱了）
- 位置: docs/04-monitoring-gitops/notes/wecom-alert-receiver-20261001/apply.sh:30-31（同一脚本的干净版本在 assets/wecom/apply.sh:30-31）
- 原文: 「`AM_SECRET=<redacted>`」/「`PLACEHOLDER='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<redacted>`」（单引号未闭合）
- 问题: 两处脱敏把脚本改坏了：① `AM_SECRET=<redacted>` 把真实值 `alertmanager-prometheus-alertmanager` 整体替换，`<redacted>` 在 bash 里被解析成输入重定向 + 语法错误；② `PLACEHOLDER='...key=<redacted>` 少了收尾单引号，导致后续所有行被吞进字符串。`bash -n` 直接报错，`set -euo pipefail` 的"幂等部署脚本"一次都跑不起来，而 README:73 正是让读者执行它。更糟的是 `<redacted>` 语义上还泄漏了"这里原本有东西"，却没有说明该填什么。
- 证据/正确说法: `bash -n notes/wecom-alert-receiver-20261001/apply.sh` → `行30: 未预期的符号"newline"附近有语法错误`（exit 2）；`bash -n assets/wecom/apply.sh` → exit 0（干净副本，`AM_SECRET=alertmanager-prometheus-alertmanager` 是正确值）。修复方向：以 `assets/wecom/apply.sh` 为准回填 —— `AM_SECRET=alertmanager-prometheus-alertmanager`、`PLACEHOLDER='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=REPLACE_ME'`（占位符不要用 `<...>`，且引号必须成对），再跑 `bash -n` + `shellcheck` 作为提交门禁。

---

### [中] 把 Alertmanager 通知写成"邮件（QQ 企业邮 SMTP）"，实际是 n8n webhook + wecom
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:42
- 原文: 「| Alertmanager | 邮件（QQ 企业邮 SMTP）通知 | `prometheus-alertmanager` (10.111.199.90:9093) |」
- 问题: 集群内生效的 Alertmanager 配置只有两个 receiver：`n8n-webhook`（webhook_configs）和 `wecom`（指向 wecom-adapter）。没有任何 email/smtp 配置。邮件是主机上那个已被废弃的 systemd Alertmanager 的配置（同文 :1891 自己写了"主机上 `default-email`（QQ 企业邮 SMTP）"），作者把"废掉的那套"当成了生效的那套，正好踩了自己 §10.5/§12.1 定义的坑。
- 证据/正确说法: `kubectl -n monitoring get secret alertmanager-prometheus-alertmanager-generated -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip` → `receivers: wecom(webhook), n8n-webhook(webhook)`，无 email；`sum by (integration) (alertmanager_notifications_failed_total)` 里 email 系列恒为 0。

---

### [中] "生效中的真实配置 … inhibit_rules: []"与实测不符；同款模板会抹掉集群现有抑制规则
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:1933、:2050；docs/04-monitoring-gitops/assets/wecom/alertmanager.yaml:29
- 原文: 「`inhibit_rules: []                    # ⚠️ 当前没有任何抑制规则`」；「**改进 ②：补上 12.4 的 `inhibit_rules`**（当前 `[]`，节点故障会产生级联轰炸）」
- 问题: 生成配置里实际有 3 条完整 inhibit_rules（critical→warning/info、warning→info、InfoInhibitor→info，`equal` 分别含 `namespace`/`alertname`）。文档把它写成空数组，会把读者引向"从零设计抑制"而非"检查现有三条为什么失效"。更实际的风险是 `assets/wecom/alertmanager.yaml` 这个"完整配置模板"里 `inhibit_rules: []`，而 `apply.sh` 是拿它整份渲染进 Secret 的 —— 重跑一次 apply.sh 就会把集群现有抑制规则全部清空，且不会报错。
- 证据/正确说法: `kubectl -n monitoring get secret alertmanager-prometheus-alertmanager-generated ... | gunzip` → `inhibit_rules:` 下 3 条 `source_matchers`（`grep -c 'source_matchers'` = 3）。修复方向：模板里保留这三条（或从现有 Secret 反向生成模板），并在 apply.sh 里加"新配置 inhibit 条数 < 旧的则中止"的护栏。

---

### [中] "（默认 quota 8GB）"—— etcd 默认与实测都是 2GiB，容量估算差 4 倍
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:647（另见 :2230）
- 原文: 「`# 默认 quota 8GB，距离告警还有很远；一旦 watch/写入暴涨，4 小时外推会立刻超限`」；表内「etcd db | ~105MB / 8GB quota」
- 问题: etcd 的 `--quota-backend-bytes` 默认是 2GiB（2147483648），本集群 etcd 静态 Pod 没有覆盖该参数，实测 `etcd_server_quota_backend_bytes = 2147483648`。按 8GB 估算会把"还有 97% 余量"错算成"还有 99% 余量"，并且 `etcdDatabaseQuotaLowSpace`（>N% 触发）的真实余量判断会偏乐观 4 倍。
- 证据/正确说法: `curl -sG .../api/v1/query --data-urlencode 'query=etcd_server_quota_backend_bytes'` → 3 个成员均为 `2147483648`；`kubectl -n kube-system get pod etcd-m01 -o jsonpath='{.spec.containers[0].command}' | grep -i quota` → 无输出（未覆盖默认值）。

---

### [中] `histogram_quantile` 的"失败模式"解释错了：不是"+Inf 垃圾值"，是空结果
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:612-613、:2196
- 原文: 「`# ❌ 忘记 by (le) -> 把所有桶混在一起 -> 结果永远是 +Inf 附近的垃圾值` / `histogram_quantile(0.99, rate(x_bucket[5m]))`」；坑 #8「忘记 `by (le)` 算分位数 | 结果永远是 +Inf / 0」
- 问题: 给的反例根本不坏。`histogram_quantile(0.99, rate(x_bucket[5m]))` 会按"除 le 之外的全部标签"分组，对每条序列各算一个 p99，是合法用法（只是分维度、样本少的组会 NaN）。真正会坏的是**聚合并丢掉 le**：`histogram_quantile(0.99, sum(rate(x_bucket[5m])))` —— 它返回空向量 + 一条 `bucket label "le" is missing` 警告，不是 +Inf。照文档的因果去排查，会把"没聚合"和"聚合错"两类问题混为一谈。
- 证据/正确说法: 实测 `query=histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))` → 正常返回 3 条（每 instance 一条，值 0.0018…）；`query=histogram_quantile(0.99, sum(rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])))` → `"result": []` + `warnings: ["bucket label \"le\" is missing or has a malformed value"]`。正确表述：忘记 `sum by (le)` 只会"少聚合"（分维度、部分 NaN）；`sum()` 丢掉 `le` 才彻底算不出来。

---

### [中] 建议的 Loki/Knative 告警里，`histogram_quantile` 一个漏 `by (le)`、一个拿 `_sum` 当桶
- 位置: docs/04-monitoring-gitops/notes/monitoring-coverage-gap-report.md:166、:176
- 原文: 「`histogram_quantile(0.95, sum(rate(loki_request_duration_seconds_bucket[5m]))) > 2`」；「`histogram_quantile(0.95, sum(rate(knative_request_count_sum...))) > 1`」
- 问题: 第一条用了 `sum(...)` 但没 `by (le)`，把 10 个桶压成一条无 `le` 的序列 → 恒空（配 `> 2` 永远不会响，正是这份文档在批评的"哑告警"）。第二条更彻底：`_sum` 是累计求和，本身没有 `le` 标签，喂给 `histogram_quantile` 必然无结果；而且 `knative_request_count` 未必是 histogram。这两条是"补覆盖"的交付物，实际等于又加了 2 条死规则。
- 证据/正确说法: 与上一条同法可验：`sum(rate(..._bucket[5m]))` 喂 `histogram_quantile` → 空 + `le is missing` 警告。正确写法 `histogram_quantile(0.95, sum by (le) (rate(loki_request_duration_seconds_bucket[5m])))`；Knative 侧应改用其真实 histogram（如 `knative_..._duration_seconds_bucket`）或对 `_sum/_count` 手工求平均。

---

### [中] "保留统一为 5 天"与实测 Prometheus 15d 不符，而且引用了不存在的验证输出
- 位置: docs/04-monitoring-gitops/notes/retention-unification-5d.md:99、:118、:401、:418；docs/04-monitoring-gitops/notes/cluster-observability-report.md:28
- 原文: 「Prometheus `/api/v1/status/flags` | `storage.tsdb.retention.time: 5d` ✅」；「**L/M/T 三层全部 5 天（120h）**：Prometheus `5d`…」
- 问题: 实测 `storage.tsdb.retention.time = 15d`、`storage.tsdb.retention.size = 25GiB`（Prometheus CR `spec.retention: 15d`），与"统一 5 天"的结论冲突；`10-observability-engineering.md:21` 也写的是 `retention 15d / 25GiB`。即同一仓库对同一参数有两个互斥的"实测值"，其中"5d"那条还带 `/status/flags` 的验证语句，可信度错觉最强。Alertmanager 120h、Loki 120h、Tempo 120h 三项是对的。
- 证据/正确说法: `curl -s localhost:9090/api/v1/status/flags | jq '.data["storage.tsdb.retention.time"]'` → `"15d"`；`kubectl -n monitoring get prometheus prometheus-prometheus -o jsonpath='{.spec.retention}'` → `15d`。正确说法：指标侧是 15d/25GiB（先到先删），日志/追踪/告警通知是 120h，"三层统一 5 天"只对 L/T/AM 成立。

---

### [中] 把 Ceph RGW 全篇写成 MinIO（32 处），据此刻画"桶/ILM/versioning"行为
- 位置: docs/04-monitoring-gitops/notes/retention-unification-5d.md:73-75、:110、:568-572（另见 notes/cluster-observability-report.md 14 处、notes/wecom-alert-receiver-20261001/MCRUN-INCIDENT-20261001.md 12 处）
- 原文: 「`│  MinIO  10.0.0.31:7480                         │  ③ 对象存储生命周期（桶级策略）`」；「`mc ilm rule ls --json la/loki-chunks`」
- 问题: 10.0.0.31:7480 是 Ceph RGW（本仓库 README:160-165 自己写了"Ceph RGW 17.2.8 → 18.2.8"、GROUND-TRUTH 也记 `RGW 在 10.0.0.31:7480`）。把 S3 网关认成 MinIO 会直接误导排障：ILM 语义、`mc ilm` 子命令支持度、versioning 实现、以及"Ceph 池满 → RGW 返回 500 → Loki 写入失败"这条真实故障链（本目录 `prometheus-nfs-to-ceph-migration` 记录过池满事故）都会被归到错误的组件上。
- 证据/正确说法: `curl -sI http://10.0.0.31:7480/` → `x-amz-request-id: tx00000a088ea32776dfa4e-...-my-zone`（`tx0000…`+zone 名是 Ceph RGW/civetweb 的固定指纹，MinIO 会回 `Server: MinIO`）。正确说法：S3 兼容层是 Ceph RGW（reef 18.2.8），桶的 lifecycle 由 RGW 的 LC 实现，排查要 `radosgw-admin lc list` / `ceph df`，而不是 `mc admin`。

---

### [中] 首页与教程的规则/采集器计数仍是 41 / 14，实测 44 / 27
- 位置: README.md:87（仓库根）；docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:2482、:66
- 原文: 「| 监控 | Prometheus/Alertmanager/Grafana 正常；**PrometheusRule 41 个；ServiceMonitor 14 个** |」；「`kubectl get prometheusrule -A                          # 41 个 CR`」
- 问题: 全集群实测 PrometheusRule **44**、ServiceMonitor **27**。`41` 恰好是 `-n monitoring` 的数量（另有 deeptutor 2 + compassio 1 = 44），所以 `-A` 后面标 41 一定是错的；而首页把 41/14 当集群总量，两个数都偏小（SM 少算 13 个，等于把 Loki/Tempo/Cilium 等一大半采集目标排除在"现状"之外）。`04-current-state.md:34` 的 44 是对的，仓库内自相矛盾。
- 证据/正确说法: `kubectl get prometheusrules -A --no-headers | wc -l` → 44；`kubectl get prometheusrules -n monitoring --no-headers | wc -l` → 41；`kubectl get servicemonitors -A --no-headers | wc -l` → 27；`kubectl get podmonitors -A --no-headers | wc -l` → 16。

---

### [中] 用"整机 RSS ÷ series"当每序列内存单价，再线性外推 100 万 series
- 位置: docs/04-monitoring-gitops/10-observability-engineering.md:22、:68-69、:563
- 原文: 「每个 series 在 head 里约占 **1–6KB**（本环境实测 RSS/series ≈ 6KB）」；「**1M series 约 6GB 内存**」
- 问题: 1.57GiB/260k ≈ 6KB 是"进程 RSS 除以活跃序列"，里面含查询缓冲、索引/WAL 缓存、compaction 与 Go runtime 开销；把它当单价会把容量规划高估 2–3 倍（业界经验值 1–2KB/head series，Prometheus 官方 sizing 也是"每百万序列 ~2–3GB"）。这条数字还与本文件 §2.3 的实验结论（GOMEMLIMIT 是软限制、128Mi 就 OOM）互相冲突：同一个"6KB/series"既用来算 1M≈6GB，又解释不了 15 万 series 在 128Mi 下崩掉（0.9KB/series 就死）。
- 证据/正确说法: `process_resident_memory_bytes / prometheus_tsdb_head_series` = 1.57GiB/260359 ≈ 6.3KB（实测值本身没错，错在把它当"每序列 head 成本"）。正确表述：单序列 head 成本约 1–2KB（chunk + index），RSS 另含缓存；容量规划用"1M series 预留 2–3GB 内存 + 20% 余量"，且必须用受控压测校准（本文件 §2.3 的实验就是校准手段）。

---

### [中] 查 Prometheus CR 的命令写错资源名，直接 NotFound
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:1899
- 原文: 「`kubectl get prometheus prometheus -n monitoring -o yaml | grep -A6 'alerting:'`」
- 问题: 本集群 `Prometheus` CR 名是 `prometheus-prometheus`（kube-prometheus-stack 的 `<release>-<chart>` 命名），照抄会 `NotFound`。这一步在 §12.1"确认哪份配置生效"的三条命令里排第一，失败后读者容易误判成"没有 alerting 配置"。
- 证据/正确说法: `kubectl -n monitoring get prometheus prometheus` → `Error from server (NotFound): prometheuses.monitoring.coreos.com "prometheus" not found`；`kubectl -n monitoring get prometheus` → `prometheus-prometheus`。正确命令：`kubectl -n monitoring get prometheus prometheus-prometheus -o jsonpath='{.spec.alerting}'`（同文 :110、:274 用的就是这个名字，前后不一致）。

---

### [中] 抑制示例 `equal: [node]` 对 `KubePod.*` 目标无效——被抑制的告警没有 node 标签
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:2005-2007
- 原文: 「`- source_matchers: ['alertname = "KubeNodeNotReady"']` / `  target_matchers: ['alertname =~ "Kubelet.*|KubePod.*|Node.*"']` / `  equal: [node]`」
- 问题: `equal` 要求两侧标签值相同，缺失标签按空串处理。`KubeNodeNotReady` 带 `node="worker01"`，而 `KubePodNotReady`/`KubePodCrashLooping` 这类目标的标签是 `namespace/pod`，没有 `node`（值为 `""`），`"worker01" != ""` → 不抑制。于是示例承诺的"节点 NotReady 时压掉该节点上的 Pod 告警"这条最主要的效果不会发生，只剩 `Kubelet*`/`Node*` 被压。
- 证据/正确说法: `kube_pod_status_ready`、`kube_pod_container_status_restarts_total` 的标签集里没有 `node`（可用 `/api/v1/series?match[]=kube_pod_info` 对照，`node` 在 `kube_pod_info` 上而不在告警序列上）。正确做法：拆成两条抑制 —— 对 `Kubelet*|Node*` 用 `equal: [node]`；对 `KubePod*` 改用 `equal: [namespace]`（或先 `label_replace` 把 node 灌进 Pod 告警）。

---

### [中] wecom 文档的"已生效配置"用的是自建应用字段，与它自己选的群机器人路线互相矛盾
- 位置: docs/04-monitoring-gitops/notes/wecom-alert-receiver-20261001/README.md:11-15
- 原文: 「| receiver | `wecom`（企业微信自建应用） |」「| corp_id | `wwd98e843d2350fa9c` |」「| agent_id | `1000003` |」「| 接收对象 | `to_tag: "1"`（标签 test） |」
- 问题: 同一篇文档的结论是"群机器人路线是正确选项"，实现是 `wecom-adapter` 转发 `webhook/send?key=...` —— 群机器人**没有** corp_id/agent_id/to_tag 这三个概念，`alertmanager.yaml` 模板和生成配置里也没有这些字段（只有 `webhook_configs.url`）。这张"已生效配置"表描述的是被否决的自建应用方案，却被标成"已生效"，会让后来者以为自建应用还在跑、去企业微信后台找 agentid。另外它把 corp_id 明文写进文档（不是密钥，但属组织标识，和"凭据只进 Secret"的自我约束不一致）。
- 证据/正确说法: `assets/wecom/alertmanager.yaml` 与该目录 `alertmanager.yaml` 均只有 `webhook_configs: url: http://wecom-adapter...`；`curl 10.105.6.52:8080/stats` → `{"received":40,"sent":39,"failed":1,"last_errcode":0}`（群机器人链路在跑）。正确说法：生效配置是 receiver `wecom` → webhook → wecom-adapter → 群机器人；corp_id/agent_id/to_tag 属"已否决方案"，应移到"调研结论"而不是"已生效"。

---

### [低] 同一个 worker01，两份"实测"给出不同的轮转文件数与占用
- 位置: docs/04-monitoring-gitops/10-observability-engineering.md:421-423；docs/04-monitoring-gitops/11-logging-pipeline.md:29、:188
- 原文: 「`worker01 已出现 14 个 *.log.* 轮转文件，最大约 10.5MB`」/「`/var/log 326M，其中 /var/log/pods 183M`」 vs 「`worker 17 个轮转文件，最大约 10.5MB`」/「`worker01: /var/log/pods 176M，17 个轮转文件`」
- 问题: 两篇同一天、同一节点、同一指标，数字 14 vs 17、183M vs 176M。轮转文件数会随写入变化，但两篇都以"实测"口吻给出确定值且互相引用同一批证据文件，读者无法判断哪个可信。这类小数字不一致会削弱整章"所有数字都是实测"的可信度。
- 证据/正确说法: 建议只保留一处（或标注采集时刻 `HH:MM`），并在另一处引用而非复述。

---

### [低] "Counter 重置 → `rate` 出现负值"—— rate 永远不会返回负值
- 位置: docs/04-monitoring-gitops/10-observability-engineering.md:285
- 原文: 「| Counter 重置 | `rate` 出现负值/尖刺 | Prometheus 会处理重置，但窗口太短会抖动 |」
- 问题: `rate()`/`increase()` 内部按 reset 语义做补偿，输出恒 `>= 0`；会出负值的是 `delta()`/裸减法（对 counter 用错函数时）。把"负值"归给 `rate` 会让人去查 Prometheus 的 reset 逻辑，而真正该查的是"是不是对 counter 用了 `delta`/直接相减"。
- 证据/正确说法: `rate(node_cpu_seconds_total{mode="idle"}[1m])` 类查询恒为非负；反例：`kube_pod_container_status_restarts_total - kube_pod_container_status_restarts_total offset 1h` 在 Pod 重建后确实是负的（本目录 `prometheus-promql-alerting-tutorial.md:704-706` 用的就是这个写法，但没有提示重建后为负）。

---

### [低] promtool 单元测试用例 2 的注释与数据对不上（说 3 次，实际给到 10 次）
- 位置: docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:1756-1760
- 原文: 「`# ---- 用例 2：只有 3 次重启 → 必须保持沉默（验证阈值下限）----`」+「`values: '0+1x10'`」
- 问题: `0+1x10` 是"从 0 开始 +1 重复 10 次"，末值 10；而阈值是 `> 10`，所以恰好卡在边界上"不告警"。注释说的"3 次"和实际数据差 3 倍多，用例实际验证的是"等于阈值不触发"，不是"远低于阈值不触发"—— 阈值写成 `>= 10` 时该用例才会真正暴露问题，注释却让人以为已经覆盖了下限。
- 证据/正确说法: 语义应为 `values: '0+1x3'`（3 次）或把注释改成"末值 10，验证 `> 10` 的边界不含等号"。

---

### [低] "只有 … 14 个 ServiceMonitor"与实测 27 个不符
- 位置: docs/04-monitoring-gitops/notes/observability-lab.md:558
- 原文: 「本集群的 Tempo **原本没有被监控**（只有 Loki、Grafana、Prometheus 自己等 14 个 ServiceMonitor）。我们给它加上。」
- 问题: 全集群 ServiceMonitor 实测 27 个（另有 PodMonitor 16 个）。即便"加 Tempo 之前"少几个，也解释不了 27 与 14 的差距；这个数字被写进实验背景，会让读者对"覆盖缺口有多大"形成错误印象（真实缺口比 14 个的世界小得多）。
- 证据/正确说法: `kubectl get servicemonitors -A --no-headers | wc -l` → 27。建议改为"当时 27 个 ServiceMonitor 中没有一个是 Tempo"，或标注采集时点并说明统计口径（是否只算某个 namespace）。

---

### [低] "ILM 7d 会导致双重删除/撞上对象不存在"的论证站不住（7d 本就 > 5d）
- 位置: docs/04-monitoring-gitops/notes/retention-unification-5d.md:145-149
- 原文: 「假设跳过这步，直接开 Loki `retention_period: 120h`：**双重删除**：Loki compactor 在第 5 天发起删除，MinIO ILM 在第 7 天独立发起删除…第二次会撞上"对象不存在"」「**不可逆**…」
- 问题: 官方约束是"lifecycle 必须长于 retention"，5d < 7d 已经满足；compactor 第 5 天删掉的对象，ILM 第 7 天只是扫到空目录，不会产生删除失败重试，更不会"双重删除"。真正需要抬高 ILM 的理由只有"给 compactor 留缓冲、避免将来把 retention 调长时反过来被 ILM 抢先"，而不是文中所列的三个后果。同一文档 §2.2 与 §八 又把 10 > 5 说成"满足官方约束"，前后口径不一致。
- 证据/正确说法: Loki 文档原文只要求 `lifecycle > retention_period`；7d > 5d 已合规。建议改写为"预留余量以便后续调长 retention"，并删掉"撞对象不存在/删除失败重试"的因果描述。
