# G7 · 控制面 HA / 生命周期 / GitOps / SRE 审计发现

> 范围：`docs/08-control-plane-ha/`、`docs/09-incidents-and-readiness/`、`docs/11-gitops-platform/`、`docs/17-sre/`
> 基准：[`../assets/ground-truth.md`](../assets/ground-truth.md)（2026-11-11 实测）+ 本次只读 kubectl /  openssl / apiserver `--help` 复核
> 共 18 条，按严重度排序。

---

### [严重度 高] 08 的"谁连谁"分析把数据面写成 kube-proxy/iptables + Calico，与实测的 Cilium KPR 完全不符

- 位置: docs/08-control-plane-ha/notes/kube-vip-apiserver-analysis.md:12（另见 27、53、69、92、120-123、180、188）
- 原文: 「kube-proxy（全节点） | **`10.0.0.61:6443`（m01），全节点统一**」；「由 kube-proxy（iptables 模式）做 DNAT，随机分摊到**三台 apiserver**」；「调 CNI(Calico) 配 Pod 网络」
- 问题: 该文档以"当前现状"口吻断言每台节点都有 kube-proxy 并在本机写 iptables 规则、Pod 网络由 Calico 提供，据此得出「kube-proxy 存在单点」「把 `kube-system/kube-proxy` ConfigMap 的 server 改为 VIP 再滚动重启 DaemonSet」等一整条整改建议。实测集群里既没有 kube-proxy DaemonSet 也没有该 ConfigMap，Service→后端由 Cilium eBPF（kube-proxy-replacement）完成，不经 iptables `statistic --mode random`；CNI 是 Cilium 不是 Calico。照此文档排障会去改一个不存在的 ConfigMap，并把"Pod 访问 apiserver 要经 kube-proxy"这一错误因果链教给读者。
- 证据/正确说法: `kubectl -n kube-system get ds` 只有 `cilium`（6/6）；`get cm` 只有 `cilium-config`，其中 `kube-proxy-replacement=true`、`routing-mode=native`；仅残留一个无 endpoints 的 Service `prometheus-kube-proxy`。GROUND-TRUTH 第 23-26 行。正确说法：本集群 Service 的 DNAT/负载均衡由 Cilium 在 eBPF 中完成，`10.96.0.1:443` 的后端由 Cilium 维护，不存在 kube-proxy 进程。同一错误在 `notes/kube-vip-planA-complete-inventory-20261013.md:4,18,32,48`（"全集群 kube-proxy 已切 VIP、6/6 滚动"）与 `docs/11-gitops-platform/notes/gitops-coverage-and-recommendations-2026-11-08.md:98-99`（把 `calico-node`、`kube-proxy` 计入手工工作负载）重复出现。

---

### [严重度 高] apiserver 内存分析仍把 `--target-ram-mb` 列为"优先做"，而该参数在 1.35 根本不存在

- 位置: docs/08-control-plane-ha/notes/apiserver-memory-analysis-20261109.md:184-187（§4.1 第 3 条）、248（§5 总结）
- 原文: 「3. **设置 `--target-ram-mb`** 例如 2048 或 3072（按节点内存），让 apiserver 按目标内存调整缓存大小。它不是硬限制，但能避免缓存无界增长。」；总结「优先做：清理 Helm 历史、减少 CRD/operator watch、**设置 `--target-ram-mb`**、给 control-plane 加内存」
- 问题: 这不是"过期建议"，而是会让 apiserver 起不来的错误参数——static Pod 里加未知 flag，容器直接 `unknown flag` 退出，控制面少一台。更糟的是同目录的执行记录与本章 README 都已经否定了它，只有这份"分析"文档还在把列为第 3 优先动作，读者按分析文档执行就会踩坑。
- 证据/正确说法: `kubectl -n kube-system exec kube-apiserver-m01 -- kube-apiserver --help` 输出中无任何 `target-ram` 项（只有 `--watch-cache-sizes`）。同目录 `notes/apiserver-remediation-20261109/REPORT.md:17,240` 明写"1.35.9 已不存在该参数，未设置"；`docs/08-control-plane-ha/README.md:130-133` 坑 8 也这样写。应删除该建议，并说明 `--watch-cache-sizes` 只有 0 有意义（help 原文：only meaningful size setting is zero；non-zero values are equivalent）。

---

### [严重度 高] kube-vip"关键配置"用了不存在的 env 名，超时/资源也与自己的资产和集群实际不符

- 位置: docs/08-control-plane-ha/README.md:83-99（坑 2、坑 3）、154-168（修复关键）
- 原文: 「- name: **preserveVipOnLeadershipLoss** / value: "true"」；「原来 `5s/3s/1s`…调整为更宽松的值（如 `10s/8s/5s`）」；「limits: {cpu: 200m, memory: 128Mi}」
- 问题: kube-vip 从环境变量读的是 `vip_preserve_on_leadership_loss`；`preserveVipOnLeadershipLoss` 只是 CLI flag 名（`--preserveVipOnLeadershipLoss`），写成 env 会被静默忽略 —— 于是"丢租约不再删 VIP"这个整篇 08 的核心修复，按 README 抄下去等于没做，故障链照旧。同一节给出的 10s/8s/5s 与 200m/128Mi 也不等于实际取值（15/10/2、仅 memory 512Mi、刻意不设 CPU limit），读者无法判断哪个是"当前状态"。
- 证据/正确说法: `kubectl -n kube-system get ds kube-vip-ds -o yaml`：`vip_preserve_on_leadership_loss=true`、`vip_leaseduration=15 / vip_renewdeadline=10 / vip_retryperiod=2`、`limits.memory=512Mi`、无 cpu limit；`assets/kube-vip-ha-daemonset-FIXED.yaml` 与 `assets/kube-vip-ds-AFTER-p0.yaml` 同。`notes/kube-vip-restart-rootcause-and-fix.md:284-293` 还专门记录了"键名从二进制提取"，README 却写反，属同仓自相矛盾。

---

### [严重度 高] 组件下线顺序把"卸载 Operator/Helm"排在"删 CR"之前，会把 CR 永久卡在 Terminating

- 位置: docs/09-incidents-and-readiness/README.md:25-26 与 136；docs/09-incidents-and-readiness/scripts/cleanup_checklist.md:27-29
- 原文: 「盘点依赖 → 备份 → 停流量/缩容 → **卸载控制器（Operator/Helm）** → **删自定义资源** → 删 CRD → 删 Webhook/APIService…」；清单同款「- [ ] 卸载 Operator 或 Helm release / - [ ] 删除 CR（等待 finalizer 释放）」
- 问题: CR 的 finalizer 是由仍在运行的 controller 移除的。先把 Operator 卸掉再删 CR，没有任何进程去摘 finalizer，CR 会一直 `deletionTimestamp` 挂着，接着删 namespace 也卡 `Terminating`，最后只能 `kubectl patch ... -f finalizers` 硬摘（文档自己把"finalizer 指向的 controller 已删除"列为卡住原因，却把这个顺序写成了标准流程）。顺序应当是：删 CR（controller 在线，走完 finalizer）→ 卸 Operator / `helm uninstall`（Helm 不删 `crds/` 里的 CRD）→ 删 CRD → 删 Webhook/APIService → 删 RBAC → 删 ns。
- 证据/正确说法: 同文 §3 自述「优先用 Operator 的卸载流程（如 `kubectl delete knativeserving`），它会…释放 finalizer」——释放 finalizer 恰恰发生在"删 CR"这一步；`notes/knative-removal-record-20261013.md:44-48` 的实际执行也是先 `delete knativeserving`、后 `helm uninstall knative-operator`，与本清单相反。

---

### [严重度 高] etcd 恢复手册在 3 节点集群里只恢复 m01，且用的是 3.6 已移除的 `etcdctl snapshot restore`

- 位置: docs/11-gitops-platform/notes/platform-gitops-repo/etcd-README.md:117-129
- 原文: 「停掉所有 control-plane 的静态 Pod…在 m01 恢复：`etcdctl snapshot restore /var/backups/etcd/restore.db --name m01 --initial-cluster m01=…,master01=…,master02=… --data-dir /var/lib/etcd-restore`」→「4. 备份并替换 `/var/lib/etcd`」
- 问题: ①只 restore m01，master01/02 保留旧数据目录（旧 cluster ID），三者 peer 握手必然 `cluster ID mismatch`，集群起不来；必须三台各用同一快照 restore，`--initial-cluster`/token 逐字一致，只有 `--name`、`--initial-advertise-peer-urls`、`--data-dir` 不同。②本集群 etcd 是 3.6.6，恢复只能由 `etcdutl snapshot restore` 执行（本仓 08 文档自己这么写），`etcdctl snapshot restore` 在 3.6 已不存在。③缺 `--bump-revision`/`--mark-compacted`，K8s 数据恢复后会遇到 informer/watch cache 不刷新。这份是"备份唯一恢复路径"的 runbook，按它做等于把可恢复故障变成不可恢复。
- 证据/正确说法: `docs/08-control-plane-ha/notes/k8s-etcd-data-and-migration.md:563,579`（"3.6 起恢复只能由 etcdutl 执行"）、`:856-871`（三台参数一致的全量恢复）；GROUND-TRUTH：etcd 镜像 `registry.k8s.io/etcd:3.6.6-0`。

---

### [严重度 中] `/proc/net/tcp` 的十六进制地址写反，"到 VIP 的连接数应为 0"这条判据永远返回 0

- 位置: docs/08-control-plane-ha/notes/kube-vip-restart-rootcause-and-fix.md:870-872
- 原文: 「#     VIP 10.0.0.168=**0A0000A8** / 10.0.0.121=7900000A / 10.0.0.120=7800000A / 10.0.0.61=3D00000A / 回环=0100007F」→「`grep -c '0A0000A8:192B' /proc/net/tcp     # 到 VIP 的连接数，应为 0`」
- 问题: `/proc/net/tcp` 按小端逐字节输出，10.0.0.168 应是 `A800000A`（168=0xA8 在最前）；文档其余四项（121→7900000A、120→7800000A、61→3D00000A、127.0.0.1→0100007F）都符合这个规律，只有 VIP 一项写成了"大端反序 + 段序颠倒"的 `0A0000A8`。于是这条"验证已无组件依赖 VIP"的命令无论实际有多少连接都匹配不到，会给出一份假的清白结论——而它正是 P0 闭环的验收证据。
- 证据/正确说法: 10.0.0.168 → `A800000A`；`grep -c 'A800000A:192B' /proc/net/tcp`（或直接用 `ss -tnp | grep 10.0.0.168`）。

---

### [严重度 中] Tekton 清理记录称 ArgoCD 只剩 3 个 Application，实测 31 个

- 位置: docs/09-incidents-and-readiness/notes/tekton-demo-cicd-removal-record-20261028.md:45
- 原文: 「ArgoCD 应用 `tekton-demo-api`：argocd 命名空间中已无此应用（**现存仅 compassio / deeptutor / open-webui**）」
- 问题: 这条"确认无残留"的结论用的是错误的全局前提。实测 argocd 命名空间有 31 个 Application（含 4 个业务 App：china-study-free/compassio/deeptutor/open-webui，以及 platform-* 一大票）。写成"现存仅三个"会让读者以为平台 App 都不存在，也可能掩盖真正该核对的对象（该 demo 的 App 名是否还以别的名字挂着）。
- 证据/正确说法: `kubectl -n argocd get applications | wc -l` = 31；同仓 `docs/11-gitops-platform/README.md:26` 与 `docs/11-gitops-platform/10-iac-evolution.md:293` 都写 31。

---

### [严重度 中] 同一节里"删 CRD 会留下孤儿 CR"与"删 CRD 会级联删所有 CR"直接冲突

- 位置: docs/09-incidents-and-readiness/README.md:32 与 41
- 原文: 「顺序反了会出现：- CRD 删了但 CR 还在 → **孤儿对象**」；两段后表格「| CRD | 定义自定义资源类型 | **删除会级联删除所有 CR** |」
- 问题: 同一页两个相反断言。K8s 的 CRD 删除会通过 GC 级联删除其全部 CR（这也正是下文"坑 2：`prune: true` + CRD = 灾难"的前提）。按第一句理解，运维会以为"先删 CRD 也没事，最多留几个孤儿对象"，从而低估风险。
- 证据/正确说法: 删除 CRD 触发其所有 CR 的级联删除（`kubectl delete crd` 后 `kubectl get <cr> -A` 为空）；不存在"CRD 删了 CR 还在"的状态。真正会留下的是"CR 删了、controller 已卸载 → finalizer 卡住"。

---

### [严重度 中] 11 章"坑 1"描述的 app-of-apps 删除行为与本仓根 App 的 `prune: false` 矛盾，给出的修复根本无法执行

- 位置: docs/11-gitops-platform/README.md:137-143（对比 54-72 的根 App 清单）
- 原文: 「从 `clusters/prod/applications/` 删掉一个 Application YAML，**根 App 会删除该 Application 对象**，但不会删除它管理过的集群资源…**修复**：下线流程要显式：先 `prune` 同步一次，确认资源删除，再删 Application。」
- 问题: 根 App 的 `syncPolicy.automated.prune` 是 `false`（同文档 70 行，实测也是 false）。prune=false 的父 App 不会删除"从 Git 消失的子 Application 对象"，所以真实行为是"子 Application 和它管的资源都留着"——比文档描述的更隐蔽（GitOps 里已经看不到，集群里还在跑），而"先 prune 同步一次"在根 App 上是关着的，照做无效。要么把根 App 的 prune 打开（并接受误删风险），要么改成"先 `argocd app delete <child> --cascade=foreground` 显式下线，再从 Git 删文件"。
- 证据/正确说法: `kubectl -n argocd get application app-of-apps -o jsonpath='{.spec.syncPolicy}'` → `{"automated":{"prune":false,"selfHeal":true}}`。另外"删 Application 不删资源"的正确机制是缺 `resources-finalizer.argocd.argoproj.io`，与 prune 无关（同仓 `notes/p0-gitops-execution-log-2026-11-08.md:250` 自己保留了该 finalizer）。

---

### [严重度 中] 把 31 个 App 的 syncPolicy 一律写成 "prune=false selfHeal=true"，实际有 7 个开了 prune

- 位置: docs/11-gitops-platform/10-iac-evolution.md:300-303
- 原文: 「app-of-apps -> clusters/prod/applications/ / 31 个 Application，全部 Synced/Healthy / **syncPolicy: automated prune=false selfHeal=true**」
- 问题: 这是把单一样本当成了全集群事实。实测 24 个 App 是 `prune:false`，7 个是 `prune:true`（china-study-free、deeptutor、open-webui、platform-grafana、platform-monitoring-rules、platform-monitoring-wecom、platform-sso-oauth2-proxy）。读者会据此认为"任何从 Git 删掉的资源都还在"，而这 7 个 App 恰好会真删——本节又是在讲"Git 是唯一事实源"，结论偏差会直接影响下线/回滚判断。
- 证据/正确说法: `kubectl -n argocd get applications -o json` 统计 `syncPolicy.automated`：`{(True,False,True):24, (True,True,True):7}`；`notes/platform-gitops-repo/grafana-README.md:73` 也写 `platform-grafana` 是 `prune: true`。

---

### [严重度 中] P0 记录把"删 Application 不删资源"归因于 `prune=false`（机制错误，且与本文档自己的注记冲突）

- 位置: docs/11-gitops-platform/notes/p0-gitops-execution-log-2026-11-08.md:366-367 与 377
- 原文: 「# 需要时删除 App（**不会删除资源，因为 prune=false**） `kubectl -n argocd delete application platform-cnpg-cluster`」；同节末尾又写「`prune=false` 只防止"从 Git 删除资源时级联删除"；如果手动 `kubectl delete application` 且 App 带 `resources-finalizer`，仍可能触发级联删除」
- 问题: 删除 Application 是否会删掉它管的资源，只取决于该 Application 上有没有 `resources-finalizer.argocd.argoproj.io`；`prune` 只影响 sync 阶段的多余资源清理，与 Application 生命周期无关。而 `platform-cnpg-cluster` 这类由 app-of-apps 创建的 App 恰恰带着该 finalizer（同文档 250 行明说不删 finalizer），所以这条"安全回滚命令"实际会级联删除 CNPG Cluster。这是会真丢库的操作指导。
- 证据/正确说法: 回滚顺序应为：先 `argocd app set <app> --sync-policy none`，再 `kubectl -n argocd patch application <app> -p '{"metadata":{"finalizers":null}}' --type=merge`，最后 delete；或 `argocd app delete --cascade=false`。

---

### [严重度 中] SLO 规则没有分母为 0 的保护：全站无流量时 burn rate 为 NaN，快烧告警静默

- 位置: docs/17-sre/assets/slo/compassio-slo-rules.yaml:24-28（另 30-68、71-80、93-98）
- 原文: 「- record: compassio:sli_error_ratio:rate5m / expr: compassio:sli_errors:rate5m / compassio:sli_requests:rate5m」
- 问题: 分子分母同源同窗口，业务请求归零（最典型的"全站不可用/入口挂了"）时是 `0/0 = NaN`。Prometheus 里 `NaN > 14.4` 为 false，`and` 两侧同时不匹配 → `CompassioErrorBudgetFastBurn` 在最该响的时候不响；同理 `histogram_quantile` 在窗口内无样本时返回 NaN，`CompassioLatencySLOBreach` 也静默。规则文件通篇没有 `or vector(0)` / `clamp_min` / `> 0` 守卫。
- 证据/正确说法: `compassio_*` 指标在无请求时 rate 为 0 而非无序列（scrape 仍存在），故必然出现 0/0。应写成 `sum(increase(errors[5m])) / clamp_min(sum(increase(total[5m])), 1)`，或对分母加 `> 0` 并用 `or vector(0)` 兜底；同时给 latency 规则加 `and on() (sum(rate(..._count[5m])) > 0)`。

---

### [严重度 中] 用 5m/30m 窗口给 0.003 req/s 的业务算错误率，14.4 阈值退化成"一个 5xx 就 page 一小时"

- 位置: docs/17-sre/assets/slo/compassio-slo-rules.yaml:11-58、92-113（与 docs/17-sre/10-slo-incident-alerting.md:112-119 冲突）
- 原文: 规则「1h/5m 双窗口 > 14.4」；正文 §2.4 却写「业务 7 天只有 1,948 次请求…7d 窗口样本太小，建议用 **30d** 或合成拨测」
- 问题: 0.0032 req/s ≈ 每 5 分钟 1 个请求，`[5m]` 里的 error_ratio 只能在 0 与 1 之间跳：任意一次 5xx 就让 5m burn = 1000、1h burn ≈ 8.7–100，双窗口同时超 14.4，于是"一次失败 page 一整小时"；反过来没有请求时又是 NaN（上一条）。正文已经指出低流量不可用短窗口，示例资产却全用短窗口，两者不能同时成立。低流量下应改用 blackbox 合成拨测（本环境 0 个 Probe，正文也承认）或按"错误请求数/时间"而非比例定义 SLI。
- 证据/正确说法: `docs/17-sre/assets/evidence/slo-compassio.txt`：`business rate 0.0032 req/s`、7d 业务请求 1,948、5xx=0；1,948/7/24/3600 = 0.0032。

---

### [严重度 中] monitoring 运维文档首尾矛盾：开头说已被 ArgoCD 接管，末尾"历史方案"说 ArgoCD 不接管

- 位置: docs/11-gitops-platform/notes/platform-gitops-repo/monitoring-README.md:13-16 与 511-520（另 50-61 仍以手工 helm 为"标准升级方式"）
- 原文: 开头「2026-11-10 更正：kube-prometheus-stack 已由 ArgoCD Application `platform-monitoring-stack` 接管…下面的手动 Helm 命令仅作为 break-glass 参考」；末尾「以下内容是最初计划的…方案，仅作记录。**本次没有执行**…当前采用 Helm + values 文件管理，**ArgoCD 不接管 monitoring**」
- 问题: 同一份文档对"monitoring 归谁管"给出相反结论，而这是判断"手改会不会被 selfHeal 回滚""能不能直接 `kubectl edit` CR"的前提。实测 `platform-monitoring-stack` 存在且 `selfHeal: true`，说明开头是对的、末尾这段是未清理的旧文，但读者无法分辨；§2 又把 `helm upgrade` 写成"标准升级/变更方式"，与"变更应提交 Git"冲突。
- 证据/正确说法: `kubectl -n argocd get application platform-monitoring-stack -o jsonpath='{.spec.syncPolicy}'` → `{"automated":{"prune":false,"selfHeal":true}}`。应删除末段"历史方案"或明确标注"已被 2026-11-10 的接管取代"。

---

### [严重度 中] 变更相关性把 `KubeProxyDown` 归因于"kube-proxy 升级/metrics bind"，而正文说 kube-proxy 已被 Cilium 取代

- 位置: docs/17-sre/assets/evidence/incident-cases.md:120（另 22、40）；docs/17-sre/10-slo-incident-alerting.md:430
- 原文: 「| 额外 | **kube-proxy 升级** | metrics bind 变化，kube-proxy target 全 0，`KubeProxyDown` 长期误报 |」；行动项「kube-proxy metrics bind 0.0.0.1 → 0.0.0.0 已完成」
- 问题: 同一批文档的主文写的是「Cilium KPR 替代 kube-proxy，`up{job="kube-proxy"}` 0 series，`absent()` 恒真」。两句话不能同时成立：若 kube-proxy 根本不存在，就不存在"升级 kube-proxy""把 metrics bind 改成 0.0.0.0"这次变更，这条事件被计入"4 次变更相关事件 / 43%"也站不住。相关性分析的价值全在归因准确，这里把"采集目标随组件退场消失"错记成"一次变更引入了监控缺口"。
- 证据/正确说法: `kubectl -n kube-system get ds` 无 kube-proxy；`up{job="kube-proxy"}` 0 series（evidence/active-alerts.txt）。正确结论：该告警根因是"指标源已不存在而规则用 `absent()`"，处置是删除/改写规则，不是"改 metrics bind"。

---

### [严重度 中] 覆盖率盘点的 86 个工作负载里仍包含 Calico / kube-proxy 这类不存在的组件

- 位置: docs/11-gitops-platform/notes/gitops-coverage-and-recommendations-2026-11-08.md:98-99（另 23、149、237）
- 原文: 「**网络与基础组件** - **Calico**：`calico-node`、`calico-kube-controllers` - CoreDNS、metrics-server、**kube-proxy**、kube-vip」
- 问题: 这份文档的 86 个分母、21 个"完全手动"以及 12.8%/44.2% 等占比，都建立在这份工作负载清单上；清单里 3-4 个条目（calico-node、calico-kube-controllers、kube-proxy）在本集群并不存在，同时漏掉了实际在跑的 Cilium（6 Pod）、cilium-operator（2 Pod）。数字看着精确，实际不可复核，且会误导后续"P2 暂不纳管 kube-proxy/Calico 配置"的取舍。
- 证据/正确说法: `kubectl get pods -A` 中无 calico-*、kube-proxy-*；Cilium DaemonSet 6/6 + operator 2/2（GROUND-TRUTH 第 22 行）。应把清单改为 Cilium，并按实测重算分母。

---

### [严重度 低] README 称"etcd 快照没有验证"，但上线中的 CronJob 每次都做 status 校验；给出的校验命令在宿主机又不可用

- 位置: docs/08-control-plane-ha/README.md:135-143（坑 9）
- 原文: 「**坑 9：etcd 快照没有验证** 只执行 `snapshot save` 不够，要验证：`etcdutl snapshot status <snapshot>.db -w table`」
- 问题: ①与同仓资产矛盾：`assets/etcd-snapshot-cronjob.yaml` 的脚本在 `snapshot save` 之后立即执行 `/usr/local/bin/etcdctl --write-out=table snapshot status "${OUT}"`，失败即 `set -eu` 退出、Job 标红——不是"没有验证"。②`etcdutl` 在控制面宿主机上并不存在（同仓 etcd 文档 §6.1 实测"宿主机 etcdctl 3.5.12、没有 etcdutl"），运维照着 README 在 m01 上敲会 command not found。
- 证据/正确说法: `assets/etcd-snapshot-cronjob.yaml` 第 30-38 行；`docs/08-control-plane-ha/notes/k8s-etcd-data-and-migration.md:699`。应写成"用容器内的 etcdutl（`kubectl -n kube-system exec etcd-m01 -- etcdutl snapshot status ...`）或宿主 etcdctl 3.5 的 `snapshot status`"，并说明 CronJob 已在做校验。

---

### [严重度 低] `--dry-run=server` 并不能"看到 finalizer / 级联"，把它当成删除前的安全网会误判

- 位置: docs/09-incidents-and-readiness/10-three-irreversibles.md:95-103、377-378
- 原文: 「| `--dry-run=server` | 是 | 是 | RBAC、webhook、finalizer、配额、不可变字段 |」；「**删除 namespace 前必须用 server dry-run**，因为 namespace 删除会触发级联和 finalizer，client dry-run 看不到这些。」
- 问题: server dry-run 走完 admission 但不落盘：既不设置 `deletionTimestamp`，也不触发 GC，所以它既不会告诉你"这个对象有 finalizer 会卡住"，也不会列出将被级联删除的子资源；它只能验证 RBAC/准入 webhook/字段合法性/配额。真实的 finalizer 阻塞与级联范围必须靠 `kubectl get ns -o json | jq '.spec.finalizers'`、`kubectl get all,pvc,... -n <ns>` 和 CRD 的 owner 关系来盘点。
- 证据/正确说法: 本文档 §1.4 的实测输出也印证了这点——server dry-run 返回 "deleted (server dry run)"、对象仍在，没有任何级联/finalizer 信息。应把"能看到 finalizer"改为"能看到准入与 RBAC 拒绝"，并补一条"级联范围需另行盘点"。

---

### [严重度 低] "合计 4 次变更相关事件（3/7 = 43%）"口径自相矛盾

- 位置: docs/17-sre/10-slo-incident-alerting.md:430-435；docs/17-sre/assets/evidence/incident-cases.md:122-124
- 原文: 「另有 kube-proxy 升级导致监控缺口；**合计 4 次变更相关事件（3/7 = 43%）**」
- 问题: 前面数出 4 次（CNPG、Grafana Operator、存储迁移、kube-proxy），括号里却用 3/7 算 43%。两个口径混在一句话里，读者无法判断"43%"到底是哪一个。要么 4/8（含"额外"这一轮）=50%，要么 3/7=43% 但删掉"合计 4 次"。
- 证据/正确说法: 同表共 8 行（7 轮 + 1 条"额外"），直接触发故障的是 3 行 + 1 条存疑（见上一条"kube-proxy"归因问题）。

---

### [严重度 低] 用 `xfs_growfs -D 32768` 充当"XFS 不能缩容"的反例，命令语义被误用

- 位置: docs/09-incidents-and-readiness/10-three-irreversibles.md:141-147
- 原文: 「`$ xfs_growfs -D 32768 /mnt/xfs` … `xfs_growfs: XFS_IOC_FSGROWFSDATA xfsctl failed: Invalid argument` … # 大小没变」
- 问题: `xfs_growfs -D` 是**扩容**数据区的接口（参数是目标块数），拿它去"缩容"本来就不可能成功；失败原因是参数非法/不支持缩小，而不是"XFS 拒绝缩容"的证据。结论（XFS 不支持 shrink，只能备份重建）是对的，但证据链是"用错命令证明了结论"，容易被面试官/读者反问。正确证据是 `xfs_info` 显示无 shrink 路径、`man xfs_growfs` 只有 grow 语义，或直接引用官方"XFS cannot be shrunk"。
- 证据/正确说法: `xfs_growfs(8)`：`-D size` 仅用于增大 data section；XFS 官方 FAQ "XFS filesystems may not be shrunk"。
