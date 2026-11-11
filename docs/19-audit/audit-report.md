# k8s-platform-tutorials 审计报告

> 仓库：http://192.168.67.201/digitalsupply/k8s-platform-tutorials （main @ 901296f，2026-11-11 16:18）
> 审计时间：2026-11-11
> 审计对象：19 个分类、886 个文件、约 12.2 万行 Markdown（含 notes/、assets/、scripts/）
> 审计方式：静态检查（py_compile / yaml / bash -n / 链接 / 围栏）+ 8 组并行逐文件深读 + 对活环境只读实测复核
> 结论文件：本报告；逐条明细在 [`findings/`](findings/)，实测基准在 [`assets/ground-truth.md`](assets/ground-truth.md)

---

## 0. 一句话结论

**这套教程的骨架（环境、拓扑、排障过程）基本是真的，但有 169 处可指认的问题，其中 29 处会让读者照着做直接失败或得出反结论。** 最集中的三类是：

1. **历史快照与当前状态混放**——Calico/kube-proxy/1.29 时代的过程记录没有标日期或版本，和 Cilium/1.35 的现状并列，导致同一事实在仓库里有 2–3 种互相矛盾的说法（CNI、kube-proxy、Ceph 版本、GitLab 版本、PV 数量都中招）；
2. **"官方要求/默认值"类断言靠记忆转述**——containerd 2.0 的升级点、etcd 默认 quota、Calico VXLAN VNI、kube-proxy IPVS 的 iptables 行为、MetalLB L2 的行为，都写错在关键处；
3. **脱敏与"当前状态"两处工程失守**——脱敏把可执行脚本改成跑不起来（`apply.sh`），"当前状态"表的数字口径不明（41/14 实为单命名空间，全集群 44/27）。

另外，审计过程中发现**活环境本身有 4 个真实故障**，而文档把相关监控描述成"正常"——这部分在 §6，和文档错不是一回事，但会影响文档结论的可信度。

---

## 0.1 修复进度（2026-11-11 晚更新）

- **P0 12/12 已修**：第 2 章每条末尾都有「修复状态」，逐条的改动、验证命令、提交见 [fix-log.md](fix-log.md)。
- 其中 2 条由仓库作者先修（burn-rate/SLO 模板 `41666d8`、kube-proxy 残留 `c201de5`），本轮沿用其写法未覆盖。
- P1 顺带修了 6 条（VXLAN 开销、Traefik 301/308、etcd quota、etcd 恢复 runbook、GitLab 版本、PM/SM 口径）。
- 现场故障 **5/5 已处理**：`KubeProxyDown` 与残留 Service 随 `c201de5` 消失；Ceph `ScrapeConfig` 改为抓 ceph-01+ceph-02（`ceph_*` 序列回到 1090，两条 critical 假告警消失）；n8n webhook 在 `platform-gitops` `da1fc72` 改回 in-cluster（ArgoCD 已同步、AM 已重载）。根因与验证见 fix-log §5。

## 1. 文档说 vs 机器是（2026-11-11 实测）

| 项 | 文档 | 实测 | 结论 |
|---|---|---|---|
| 节点 / 版本 | 6 节点 v1.35.9 | 6/6 Ready，v1.35.9，containerd 2.3.2 | ✅ |
| CNI | Cilium 1.20.4，KPR + native routing + BPF masq | `kube-proxy-replacement=true`、`routing-mode=native`、`enable-bpf-masquerade=true`、L2 announcements 开 | ✅ |
| kube-proxy | 已移除 | DS/CM/SM 均无；**残留无 endpoints 的 Service `prometheus-kube-proxy`（292d）** | ⚠️ 半对 |
| API VIP / 入口 | 10.0.0.168:6443 / Traefik 10.0.0.252 | kube-vip 3 副本；traefik-v3.7.17，LB IP 10.0.0.252 | ✅ |
| ArgoCD | 31 Application，全 Synced/Healthy | 31，31 Synced，31 Healthy | ✅ |
| PrometheusRule | 41 | **44**（monitoring 41 + deeptutor 2 + compassio 1） | ❌ 口径错 |
| ServiceMonitor | 14 | **27**（monitoring 14 + 其余 13） | ❌ 口径错 |
| Prometheus / AM / Grafana | 3.11.2 / 0.32.0 / 12.4.3 | 同 | ✅ |
| Loki / Alloy / Tempo | 3.6.7 / 1.20.0 / 3.0.3 | 同（tempo-distributed 形态一致） | ✅ |
| Ceph | 18.2.8 reef，HEALTH_OK | 18.2.8，HEALTH_OK，3 host / 6 OSD / 465 PG，92 GiB used / 180 GiB | ✅ |
| PV | 17 个全部 Bound | 17 Bound，SC `ceph-rbd-sc` 为 **Retain** | ✅ |
| etcd 快照 | 每小时 | CronJob `5 * * * *`，最近 Job 全 Complete，S3 上传成功 | ✅ |
| GitLab | CE 19.4.2（根 README）/ 19.4（00 章） | **19.5.0 CE** | ❌ 两处都错且互不一致 |
| Harbor | v2.14.5，192.168.67.202:8443 | 服务在线，`auth_mode=oidc_auth`、provider=GitLab、匿名拉取 401 | ✅（版本需登录核） |
| PVE | 8.4.13 @ 192.168.67.156 | 10.0.0.1:8006 与 192.168.67.156:8006 **证书指纹完全相同**（SHA256 `5D:3B:B4:DD…`）→ 同一台；未登录无法取 pveversion（SSH 拒绝 publickey/password） | ⚠️ 同机已证实，8.4.13 未验证 |

---

## 2. P0：照抄会失败 / 会把结论做反（12 条，均已复核）

### 2.1 脱敏把脚本改成了不可执行 —— `apply.sh`
- 位置：`docs/04-monitoring-gitops/notes/wecom-alert-receiver-20261001/apply.sh:30,35`
- 原文：`AM_SECRET=<redacted>` / `PLACEHOLDER='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=<redacted>`
- 问题：两处脱敏破坏了语义 —— ① `AM_SECRET` 被整体替换，而它的值是 StatefulSet 名 `alertmanager-prometheus-alertmanager`，**不是密钥**；② 占位符少了收尾单引号，后面所有行被吞进字符串。
- 证据：`bash -n` → `行30: 未预期的符号"newline"附近有语法错误`；干净副本 `assets/wecom/apply.sh` 通过。
- 修复：以 assets 版为准回填；脱敏只替换字面密钥，不要把标识符一起替换；把 `bash -n` + `shellcheck` 加进提交门禁。

- 修复状态（2026-11-11）：已修。`notes/.../apply.sh` 回填 `AM_SECRET=alertmanager-prometheus-alertmanager`、补回两处被吃掉的收尾引号；两处占位符改成 `key=REPLACE_ME`。`bash -n` 两个脚本均通过。
### 2.2 `kubeProxyReplacement=strict` 在 Cilium 1.20 上装不上
- 位置：`docs/02-cilium-ebpf/Cilium-EBPF数据面实战教程.md:339`、`…-完整版.md:346`、`PodIP规划与Cilium-eBPF生产安装.md:226`
- 证据（本机渲染官方 chart 实测）：`helm template … --set kubeProxyReplacement=strict` → `Error: kubeProxyReplacement must be explicitly set to a valid value (true or false)`。
- 正确：`--set kubeProxyReplacement=true`（与集群 `kube-proxy-replacement: "true"` 一致）。

- 修复状态（2026-11-11）：已修。三篇安装命令改 `--set kubeProxyReplacement=true`；`helm template` 渲染通过。
### 2.3 `ipam.operator.clusterPoolIPv4PodCIDR` 是废弃键，`--set` 静默不生效
- 位置：同上三篇的安装命令（`:337` / `:344` / `:224`），另 `:307` 写"默认 10.0.0.0/16"
- 证据：`helm template … --set ipam.operator.clusterPoolIPv4PodCIDR=10.0.0.0/16` → 渲染出 `cluster-pool-ipv4-cidr: "10.0.0.0/8"`（**设了等于没设**，也不报错）；正确键是 `clusterPoolIPv4PodCIDRList={10.0.0.0/16}`，渲染结果才变。chart 默认值是 `10.0.0.0/8`，不是文档写的 /16。

- 修复状态（2026-11-11）：已修。改 `--set 'ipam.operator.clusterPoolIPv4PodCIDRList={10.0.0.0/16}'`，并把「默认 10.0.0.0/16」改成 chart 实际的 `10.0.0.0/8`；渲染输出 `cluster-pool-ipv4-cidr: 10.0.0.0/16` 已验证。
### 2.4 kube-proxy JSON Patch 用了非法成员 `values`
- 位置：`docs/07-networking/notes/kube-proxy-nftables-diagnosis.md:96,128`
- 问题：RFC 6902 只认 `value`；写 `values` 会被 apiserver 拒绝，文档后面"结果已改为 iptables"不可能发生。另外 `command` 原本不存在时应 `add` 而不是 `replace`。

- 修复状态（2026-11-11）：已修。两处 `"values"` 改 `"value"`（RFC 6902 合法成员）。
### 2.5 `preserveVipOnLeadershipLoss` 作为 **env 名**不存在，整篇 08 的核心修复等于没做
- 位置：`docs/08-control-plane-ha/README.md:92,161`
- 实测集群：`vip_preserve_on_leadership_loss=true`、`vip_leaseduration=15 / renewdeadline=10 / retryperiod=2`、`limits.memory=512Mi`、无 CPU limit。
- 问题：`preserveVipOnLeadershipLoss` 只是 **CLI flag** 名；写成 env 会被静默忽略。同文档给的 `5s/3s/1s→10s/8s/5s` 与 200m/128Mi 也和实际（15/10/2、512Mi、无 cpu limit）不一致。

- 修复状态（2026-11-11）：已修。env 名改 `vip_preserve_on_leadership_loss`，超时改 `15/10/2`、资源改 `limits.memory=512Mi`（无 CPU limit），与集群实测一致。
### 2.6 `--target-ram-mb` 在 1.35 不存在，写进 static Pod 会让 apiserver 起不来
- 位置：`docs/08-control-plane-ha/notes/apiserver-memory-analysis-20261109.md:184,248`（列为"优先做"第 3 项）
- 证据：`kube-apiserver --help | grep -c target-ram` → **0**；同目录 README 坑 8 与 remediation 报告都已否定该参数 —— 只有这份"分析"没改。

- 修复状态（2026-11-11）：已修。该条改成「已废止，不要执行」，保留 `--watch-cache-sizes` 的真实语义（唯一有意义的取值是 0），并指向 `apiserver-remediation-20261109/REPORT.md`。
### 2.7 Alertmanager 生成配置里 `inhibit_rules` 不是空的，而模板是空的 → 重跑一次会清空线上抑制规则
- 位置：`docs/04-monitoring-gitops/notes/prometheus-promql-alerting-tutorial.md:1933,2050`、`assets/wecom/alertmanager.yaml:29`
- 实测：生成配置有 3 条 inhibit_rules（`grep -c source_matchers` = 3）；`apply.sh` 会把整份模板渲染进 Secret。文档却写"当前没有任何抑制规则"。

- 修复状态（2026-11-11）：已修。`assets/wecom/alertmanager.yaml` 补回线上那 3 条 inhibit_rules；教程正文的「当前 []」改为「线上 3 条」，`改进②` 改成核对 `equal` 维度。
### 2.8 告警规则只写 `release: prometheus` 会被静默丢弃
- 位置：`…/prometheus-promql-alerting-tutorial.md:883`（另 :896/:1255/:1871/:2201/:2270）
- 实测：`ruleSelector = {release: prometheus, platform.gitops/managed: "true"}` 两标签 **AND**；44/44 条规则都带后者。
- 后果：§11.4 的"全链路自检"规则永远不加载 → 自检假通过。

- 修复状态（2026-11-11）：已修。示例 CR、说明段、检查清单、坑表共 6 处补上 `platform.gitops/managed: "true"`，并说明 ruleSelector 是 AND。
### 2.9 burn rate 四档"多久烧光预算"全错（量级差一个数量级）
- 位置：`…/prometheus-promql-alerting-tutorial.md:2111-2122`
- 原文："14.4× → 1 小时烧光" / "6× → 6 小时" / "3× → 1 天" / "1× → 3 天"
- 正确（30 天 SLO）：预算消耗比 = burn × 窗口 / 720h → 14.4×1h = **2%**，6×6h = **5%**，3×24h = **10%**，1×72h = **10%**。1× 烧光预算是 30 天，不是 3 天。文档自己在下一段把"燃烧率 = 实际错误率 ÷ 预算错误率"写对了，时间换算却全反。
- 修复状态（2026-11-11）：已修正为“窗口预算消耗”，补 720h 公式与烧光时间表；阈值不变。

### 2.10 SLO 模板的录制规则缺分母，阈值不可比
- 位置：同上 `:2148-2155`
- 原文：`sum(rate(...{status=~"5.."}[5m])) / 0.01`
- 正确：`sum(rate(…{status=~"5.."}[5m])) / sum(rate(…[5m])) / 0.01`。按现写法，1000 QPS 下每秒 0.15 个 5xx（0.015% 错误率）就会打 critical。
- 修复状态（2026-11-11）：模板已补总请求分母。

### 2.11 GitLab 端口排障建立在错误配置键上（5 篇文档、约 830 行）
- 位置：`docs/03-gitlab/gitlab-19.4-install.md:166` 等（共 12 处 `gitlab_rails['nginx'][…]`）
- 问题：Omnibus 没有 `gitlab_rails['nginx']` 这一层，写了不报错也不生效；端口由 `external_url` 或 `nginx['listen_port']` 决定 —— 同仓 `notes/install-and-port.md:33,38` 用的就是正确键。整条"Cilium 残留 nft 规则导致 127.0.0.1:80 超时"的归因也站不住：那条规则是 `! -o lo`（出接口**不是** lo），永远匹配不到回环流量。

- 修复状态（2026-11-11）：已修。12 处 `gitlab_rails['nginx']['listen_port']` 全改 `nginx['listen_port']`，`sed -i` 的替换方向也改对了。线上核实：`external_url "http://192.168.67.201"`（无端口）、nginx 监听 `0.0.0.0:80`，`gitlab-ce 19.5.0`。
### 2.12 CNPG 恢复 runbook 用不存在的 `spec.recovery`
- 位置：`docs/06-storage-ceph/notes/ceph-rbd-released-pg-backup-implementation-20261005.md:606`
- 问题：CNPG 的恢复是 `spec.bootstrap.recovery` + 顶层 `externalClusters`；这里写成 `spec.recovery` 且没有 `externalClusters`，apply 后 Cluster 不会进恢复流程。同仓 `cnpg-operator-how-it-works-2026-11-09.md:760` 的写法是对的 —— 两份 runbook 一份能跑一份不能。

- 修复状态（2026-11-11）：已修。改成 `spec.bootstrap.recovery` + 顶层 `externalClusters`（barmanObjectStore + s3Credentials），并补 `storageClass: ceph-rbd-sc`。
---

## 3. P1：事实性错误（版本 / 数量 / 关键行为）

> **口径说明**：本章区分两种「对不上」。①**描述当前状态**的表格/句子写错值 → 是错误（本轮已改的见 fix-log §3）；
> ②**过程记录**里出现低版本（1.29、Calico 3.27.4、containerd 1.7.22、etcd 3.5.12、Kaniko）→ 那是当时的事实，
> 属版本演进，不算错误，缺的只是「日期 + 版本」标注。下表只保留 ① 类。

### 3.1 版本与拓扑
| 位置 | 文档 | 实际 |
|---|---|---|
| `README.md:18`、`00-cluster-overview/README.md:43` | GitLab CE 19.4.2 / 19.4 | **19.5.0 CE** |
| `13-sso-oidc/notes/01-sso-overview.md:48`、`03-phase2…:18` | Ceph 17.2.8 Quincy | **18.2.8 reef** |
| `06-storage-ceph/notes/*`（多处） | "Ceph 20.2.0 Tentacle"作为待核项 | 实为 18.2.8；该文 §10.2 自己已纠正，但 §1/§4 未回改 |
| `00-cluster-overview/notes/k8s-cluster-report.md:617` | Ceph 节点 10.0.0.116/117/118 | **10.0.0.31 / .41 / .51** |
| `00-cluster-overview/notes/k8s-cluster-report.md:823` | `100 - 0 * avg(rate(...)) by (node)` | 恒等于 100；应为 `100 - (avg by (node)(rate(...))*100)` |
| `production-readiness-gaps-20261109.md:124` | master01 6C/6G | **4 核**（同文 §8.2 自证） |
| `16-middleware-os/README.md:16` | "Harbor 1.30.4"（版本号不存在） | Harbor 是 2.14.5；这行应指 nginx 1.30.4，表述混淆 |

### 3.2 kube-proxy / IPVS / nftables 的机制描述
| 位置 | 错误 | 正确 |
|---|---|---|
| `K8s-1.35-审计报告.md:28` | "kube-proxy 配置为 iptables，**从未使用 ipvs**" | 同目录 `02-升级方案.md:30,185` 记录 `mode: "ipvs"`、366 条 IPVS 规则；`07-线3执行报告` 整篇就是 IPVS→iptables 迁移 |
| `07-线3执行报告:36` | "IPVS 模式下不生成 iptables 规则" | IPVS 仍写 `KUBE-SERVICES`(masq 分支)/`KUBE-NODE-PORT`/`KUBE-POSTROUTING`/`KUBE-FIREWALL`，只是不写 `KUBE-SVC-*`；同文自己贴出迁移前 8 行 |
| `k3s-cilium-网络分析.md:151` | "kube-proxy 用 ip rule/route 把 Service 网段引到 lo" | 那是 IPVS 模式的 `kube-ipvs0`；iptables 模式无此路由 |
| `02-升级方案.md:757` | "nftables 模式 1.31+ GA" | 1.31 是 Beta（KEP-3866）；同仓 README:88 说"1.35 仍在演进" |
| `02-升级方案.md:913` | "NetworkPolicy 0，无任何策略" | 该表是 Calico CRD 计数，但结论写成了集群事实；实测 **23 条原生 NetworkPolicy**，由 Cilium 执行 |
| `kube-proxy-service-iptables-explained.md:68` | NodePort 地址 `10.244.x.x:30156` | NodePort 在节点 IP（10.0.0.x）上；同文 3.1 节自己写对了 |
| 同上 `:52` | `spec.externalIPs: 10.0.0.252` | 10.0.0.252 是 `status.loadBalancer.ingress`；externalIPs 为空 |

### 3.3 网络封装/协议细节
- `ipip-vs-vxlan-explained.md:186`：VXLAN 开销算 76 字节（漏 UDP 8 字节、又把内层 IP 头算进开销）；正确 **50** → MTU 1450，与同文 5.4 节冲突。
- 同文 `:171,199`：Calico VXLAN 默认 **VNI 4096**（不是 1）；Calico 的 VXLAN 是单播实现，不存在 `FELIX_VXLANMDS` 与 224.0.0.100 多播分发 MAC。
- 同文 `:75,99`：IPIP 外层源地址应是出接口节点 IP（172.16.1.124），不是 tunl0 的 10.244.30.64。
- `metallb-speaker-to-cilium-l2-replacement-report-20261109.md:336`："MetalLB L2 把 VIP 加到 leader 网卡上" —— L2 模式不绑地址，靠 speaker 应答 ARP；两者这点行为相同。
- `traefik-routing-architecture.md:116`：`permanent: true` 对 GET 返回 **301**，非 GET 才 308（现网实测 301/308），文档把它当 308 写进验收判据。
- `traefik-routing-architecture.md:283`：把 LB 的 DNAT 画在 filter 表的 `KUBE-EXTERNAL-SERVICES`（该链只服务 ETP=Local 且不做 DNAT）；本集群已无 kube-proxy，实际在 Cilium BPF LB。
- `cilium-bpf-lb多轮问答汇总.md:124`：由"每节点都有 LB 前端条目"推出"各节点都在宣告 VIP" —— 前端条目是本地转发的必要条件，宣告由 Lease 选主决定（实测 `cilium-l2announce-traefik-traefik` 在 worker03）。

### 3.4 可观测性语义
- `prometheus-promql-alerting-tutorial.md:720`：`… offset 1d` 挂在聚合函数后面，PromQL 直接报 `offset modifier must be preceded by …`；正确 `sum(rate(x[15m] offset 1d))`。
- 同文 `:612`：`histogram_quantile(0.99, rate(x_bucket[5m]))` 并非"坏例子"（合法，只是分维度）；真正坏的是 `sum(rate(...))` 丢掉 `le` → 空结果 + `bucket label "le" is missing` 警告，不是 "+Inf 垃圾值"。
- 同文 `:647`：etcd quota "默认 8GB" —— 实测 `etcd_server_quota_backend_bytes = 2147483648`（**2 GiB**）。
- 同文 `:42`：Alertmanager "邮件（QQ 企业邮 SMTP）" —— 实际 receivers 只有 `wecom` 与 `n8n-webhook`，无 email。
- 同文 `:179`、`04-current-state.md:37`：把 "kube-proxy 6 个 target" 当实测输出、把 health 异常记 0；实测 `job="kube-proxy"` 零 target，且 `KubeProxyDown` **正在 firing（critical）**。已修复：`kubeProxy.enabled=false`，残留 Service/SM/Rule/CM 已清理。
- `manifests/rules/coverage-gap-alerts.yaml`：`CalicoNodeNotReady` / `CalicoKubeControllersDown` / `CNIComponentNotReady` 全部匹配 `pod=~"calico-node-.*"`；Cilium 集群里是空向量 → 三条哑告警，其中两条表达式完全相同。

### 3.5 Linux / 容器 / 存储
- `05-linux`：把 Cilium 说成 `privileged: true` 并据此论证"CNI 必须特权" —— 实测 cilium-agent 是 drop ALL + 13 caps；全集群 privileged 只有 ceph-csi-rbd×9 + buildkitd×1。
- `05-linux`：`/sys/kernel/security/lsm` 含 selinux ≠ SELinux 启用（`getenforce` = Disabled）；`fs.nr_open` 不得超过 `file-max` 的内核约束不存在；`sudo -i -c` 不是合法用法。
- `08`：`/proc/net/tcp` 里 10.0.0.168 应是 `A800000A`，文档写成 `0A0000A8` → "到 VIP 连接数为 0"这条 P0 验收命令永远匹配不到。
- `06`：PV 数写 18（实测 17）；Released PV 清理顺序两份文档相反；`radosgw-admin caps add` 用法错并据此得出"子命令不存在"；PE 大小 64M 与"64M×4096=16G"算式自相矛盾。
- `12`：`virt-customize` 不会随机化 machine-id；扩容"一页命令"缺 LV/文件系统两步，照抄 `df` 不变。
- `09`：组件下线顺序把"卸载 Operator"排在"删 CR"之前 —— finalizer 没人摘，CR 永久 Terminating；同页又说"删 CRD 会留下孤儿 CR"（实际是级联删）。
- `11`：etcd 恢复 runbook 只恢复 m01（三节点必须各自 restore，否则 cluster ID mismatch），且用 3.6 已移除的 `etcdctl snapshot restore`（应为 `etcdutl`）。

---

## 4. P2：同一事实的多种说法（内部矛盾清单）

这类不影响"能不能跑"，但会让读者无法判断哪个是现状，也是本仓库最系统性的问题。

| 事实 | 出现过的说法 | 出处 |
|---|---|---|
| GitLab 版本 | 19.4.2 / 19.4 / 19.5.0 | README、00 章、03 章、13 章 |
| 当前端口 | 80 直达 / 8088 / 80 跳 8088 | 03 章 5 篇 |
| PV 数 | 17（Bound）/ 18 / "9 个 Released 孤儿" | 00、06、01 |
| TIME_WAIT | 127 / 185 / 189（只有 127 有证据文件） | 15 章多处 |
| Ceph 用量 | 18 GiB / 81 GiB / 88 GiB / 92 GiB | 00、15、06 |
| conntrack | 947 / 953 | 15 章 |
| etcd keys | 8234 / 8243 | 15 章 |
| 日志轮转文件 | 14 / 17 | 15 章 |
| Deployment 策略 | 54 个 25%/25%（实测 51，总 74） | 10、15 章 |
| 白盒 job | "52 = 27 SM + 16 PM"（27+16=43） | 15 章 |
| hostNetwork Pod | 38 / 35（实测 35） | 05 章 |
| kube-proxy | 已移除 / iptables 模式 / 从未用 IPVS / 6 target | 00、01、04、08 |
| CNI | Cilium / Calico（多篇 notes 仍按 Calico 排障） | 02、06、08、11 |
| CP 升级方式 | "只 cordon 不 drain" / "只 drain 不 cordon" | 01 章两份执行报告 |
| runc 版本 | 1.3.3（6 节点一致）/ m01 1.3.3 + 其余 5 台 1.1.14 | 01 章方案 vs 修正记录 |

**根因**：`notes/` 是过程记录，本来就会过期，但仓库把它们和"当前状态"平铺在同一层，只有极少数文件带了 `> 历史记录：…` 的头部说明。建议给每篇 notes 加统一的 `状态:` front-matter（`历史快照 / 与现状一致 / 已作废`）+ `采集时间` + `对应集群版本`，README 索引里按状态分组。

另外有 5 篇 Keycloak 时代的 SSO 笔记（`13-sso-oidc/notes/01..05`）与 `11-gitops-platform/notes/platform-gitops-repo/` 下的同名文件**逐字节重复**，而 13 章 README 写的是 GitLab OIDC —— 这批文件描述的是已被替换的架构（`sso.k8s.local`、Keycloak），现在成了误导源。

---

## 5. 结构性 / 方法论问题

1. **"实测"标签没有采集时刻**。同一份文档里 41/14、127/185/189、88G/81G 混在一起，都标"本环境"。建议所有实测数字统一格式：`命令 → 值（YYYY-MM-DD HH:MM，节点名）`，并且只在一处维护快照（现在是 `00/assets/current-state.md`，但它自己也有一批裸数字）。
2. **教程正文与运行态没有围栏**。`apply.sh`、`upgrade-k8s-series.sh` 这类脚本应当有 CI 跑 `bash -n` / `shellcheck` / `helm template` 的冒烟检查 —— 本次 3 个 P0（strict、废弃 CIDR 键、JSON Patch values）都能被 `helm template` 与 `kubectl --dry-run=server` 拦住。
3. **脱敏规则过宽**。126 处 `<redacted>` 里有 13 个 .sh、9 个 yaml，把 StatefulSet 名、占位符引号一起吃掉。建议改为白名单式脱敏（只替换 `password|token|key|secret` 的值），并对脱敏后的文件跑语法检查。
4. **目录名与内容不符**。`01-kubernetes-k3s` 里 90% 是 kubeadm 主集群的升级史，k3s 只是三节点实验；根 README 的描述会让人直接跳过这一章。
5. **公开面**。GitHub 副本 `digitalsupply/k8s-platform-tutorials` 是 **public**，且与 GitLab main 完全同步（HEAD 一致）。内网 IP、节点名、Hyper-V 宿主名 `SYZX-HY2-TX`、Ceph PG 拓扑、GitLab 端口/NAT 方案都在里面。README 的免责声明只说"RFC1918 不可从公网访问"，但拓扑与主机名本身是信息泄露面 —— 如果要继续公开，建议把内网段替换成文档化占位（`10.0.0.0/24` → `10.0.0.0/24` 保留但去掉具体节点-角色映射），或整体转为 private。

---

## 6. 审计中发现的现场真实故障（文档未记录，且与"一切正常"的结论冲突）

> **2026-11-11 晚：5 条已全部处理**（详见 [fix-log.md](fix-log.md) §5）。下面是发现时的原始记录。

以下不是文档写错，是**集群现在确实有问题**，且会让文档里"监控正常/告警可用"的说法站不住：

1. **Ceph 监控抓的是 standby mgr，指标全 0**
   `ScrapeConfig monitoring/ceph-mgr` 硬编码 `10.0.0.31:9283`（标签 `mgr_node: ceph-01`），而当前 active mgr 已切到 ceph-02（10.0.0.41）。实测 10.0.0.31/metrics 返回 **200 + 0 字节**，10.0.0.41 返回 1090 条 `ceph_*`。
   后果：Ceph 面板全空；`absent()` 类规则常驻 firing。
2. **两条 Ceph critical 告警是假的**
   `CephClusterHealthUnknown` 与 `CephMGRMetricsMissing` 正在 firing，表达式分别是 `absent(ceph_health_status{cluster="ceph-prod"})`、`absent(ceph_mon_quorum_status{cluster="ceph-prod"})` —— 因为上面第 1 条导致指标消失。
3. **Alertmanager webhook 投递在失败**
   `AlertmanagerFailedToSendAlerts`（warning，reason=serverError）与 `AlertmanagerClusterFailedToSendAlerts`（critical）都在 firing，integration=webhook。wecom adapter 自身 `/healthz` 正常（received 40 / sent 39 / failed 1），说明失败的是另一个 webhook（`n8n-webhook`）—— 即告警链路有一半是断的，而文档把"端到端告警已验证"当作结论。
4. **`KubeProxyDown` 常驻 critical**
   kube-proxy 已移除但上游规则 `absent(up{job="kube-proxy"})` 仍生效，永远 firing。当前 7 条 firing 里 4 条属于"假告警/自检"（KubeProxyDown、2×Ceph、InfoInhibitor），真正的信号被稀释。
5. **残留对象**：`kube-system/prometheus-kube-proxy`（headless，无 endpoints，292 天）。

修复优先级建议：改 ScrapeConfig 指向 active mgr（或用 Service/Endpoints 动态发现）→ 删/改 KubeProxyDown 与两条 Ceph absent 规则 → 查 n8n webhook 为什么 serverError → 清残留 Service。这 4 件做完，"全绿"才名副其实。

---

## 7. 建议的修复批次

| 批次 | 内容 | 状态 |
|---|---|---|
| 立刻（P0） | §2 的 12 条：3 个安装/补丁命令、脱敏脚本、kube-vip env 名、target-ram-mb、CNPG 恢复 YAML、inhibit 模板、rule label | **已完成（12/12）** |
| 本周 | §3 的版本/数量/机制类（尤其 kube-proxy IPVS 三处、VXLAN 50 字节、quota 2GiB、Calico VNI） | 已修 6 条，余 89 条待排 |
| 结构性 | 给 notes 加 `状态/采集时间/集群版本` front-matter；数字统一到 current-state 并附命令；CI 加 `bash -n`/`shellcheck`/`helm template` 冒烟 | 未开始 |
| 现场 | §6 的真实故障 | 2/5 已修（KubeProxyDown、残留 Service）；Ceph mgr、n8n webhook 待处理 |

---

## 8. 审计边界（哪些我没能验）

- **PVE 8.4.13**：10.0.0.1 与 192.168.67.156 是同一台，但无凭据，`pveversion` / `pvesm status` 未取到；文档里 PVE 的存储容量、thinpool 数字全部未复核。
- **Hyper-V 宿主 192.168.67.110**：不可达（GitLab/Harbor 都在 192.168.67.201/202），宿主层声明（VM 数量、内存分配）未验证。
- **Harbor 2.14.5**：匿名 `/api/v2.0/systeminfo` 只返回 auth 配置，版本号需登录确认。
- **历史过程记录的真实性**：`notes/` 里 2026-09/10 的故障时间线（PVE 断电、apiserver 192 次重启、GitLab 196 条迁移未跑）无法回溯验证，本报告只判"是否与当前状态自相矛盾"，不判"当时是否发生"。
- **1.35 特性数量**（60/17/19/22 与"15 项 GA"）：需对 release notes 逐条核，未做。
- **K8s/Cilium 上游版本号本身**（1.35.9、Cilium 1.20.4 等）：本环境为"未来版本"环境，我以实测为准，不评价版本号是否存在。

---

## 9. 附：审计产物

- 修复台账：[`fix-log.md`](fix-log.md)（P0 逐条改动 + 验证命令 + 现场故障根因 + 对报告自身的 3 处更正）
- 逐条明细（169 条，含 file:line、原文、证据、正确说法）：[`findings/g1-overview-k8s.md`](findings/g1-overview-k8s.md) … [`findings/g8-cheatsheet-readme.md`](findings/g8-cheatsheet-readme.md)
- 实测基准：[`assets/ground-truth.md`](assets/ground-truth.md)
- 静态检查结果：[`assets/static-findings.txt`](assets/static-findings.txt)（py/yaml/json/sh/链接/围栏，仅 1 处 shell 语法错）
- 原始命令输出：`ground-truth-1..7.txt`
