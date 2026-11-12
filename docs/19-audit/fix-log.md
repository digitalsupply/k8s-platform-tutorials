# 修复台账（2026-11-11）

> 记录 `audit-report.md` 里各条问题的处理结果。**报告正文保留原始症状**（错在哪、当时为什么错），
> 修复结果只在这里和每条的「修复状态」行更新 —— 这样后来的人能看到"曾经错成什么样"。
>
> 状态口径：`已修` 改了文档并在本机验证过；`线上已修` 改的是集群/配置；`待处理` 有明确方案但没动；`不修` 判定为历史阶段或非错误。

## 1. 汇总

| 批次 | 条数 | 已修 | 待处理 | 不修（历史阶段） |
|---|---|---|---|---|
| P0（照抄会失败） | 12 | **12** | 0 | 0 |
| P1（事实/语义错误） | 95 | **46**（第一轮 6 + 第二轮 15 + 第三轮 25） | ~49 | — |
| P2（内部矛盾/版漂） | 48 | **28**（数值统一 11 + 17 个文件加状态头） | ~25（见 §10.7） | 见 §4 口径 |
| 现场真实故障 | 5 | 5 | 0 | 1（观察：ceph-03 无 mgr） |

> 三轮合计改动：文档 130 处、GitOps 源仓 3 个提交；「已修」按**发现条目**计，一条问题可能对应多处编辑。
> 只剩 §10.7 里那批"需要补业务口径"的 25 条左右。

P0 全部闭环，且每条都有可复现的验证命令（`bash -n` / `helm template` / 线上 `/etc/gitlab/gitlab.rb`）。

## 2. P0 逐条

| # | 问题 | 处理 | 验证 |
|---|---|---|---|
| 2.1 | `apply.sh` 被脱敏改成不可执行 | `AM_SECRET` 回填 `alertmanager-prometheus-alertmanager`；补两处被吃掉的收尾引号；占位符 `key=REPLACE_ME` | `bash -n` 两个脚本 exit 0 |
| 2.2 | `kubeProxyReplacement=strict` 装不上 | 三篇改 `=true` | `helm template ... --set kubeProxyReplacement=true` → `kube-proxy-replacement: "true"` |
| 2.3 | 废弃的 `clusterPoolIPv4PodCIDR` 键 | 改 `clusterPoolIPv4PodCIDRList={10.0.0.0/16}`；默认值纠正为 `10.0.0.0/8` | 渲染出 `cluster-pool-ipv4-cidr: "10.0.0.0/16"`（旧键仍是 /8） |
| 2.4 | JSON Patch 用非法成员 `values` | 两处改 `value` | RFC 6902 语义 |
| 2.5 | kube-vip env 名写错（修复等于没做） | `vip_preserve_on_leadership_loss`；超时改 15/10/2；资源改 `limits.memory=512Mi` | `kubectl -n kube-system get ds kube-vip-ds -o yaml` |
| 2.6 | `--target-ram-mb` 在 1.35 不存在 | 改成"已废止，不要执行"，补 `--watch-cache-sizes` 的真实语义 | `kube-apiserver --help \| grep -c target-ram` → 0 |
| 2.7 | AM 模板 `inhibit_rules: []` 会清空线上抑制 | 模板补回线上 3 条；正文改"线上 3 条" | 线上生成配置 `grep -c source_matchers` → 3 |
| 2.8 | 规则只带 `release` 标签会被丢弃 | 6 处补 `platform.gitops/managed: "true"` | `ruleSelector` 两标签 AND；44/44 规则都带 |
| 2.9 | burn rate 四档"多久烧光"全错 | 用户已修（`41666d8`）：改"窗口预算消耗"+720h 公式 | 原文保留，修复状态已记 |
| 2.10 | SLO 模板录制规则缺分母 | 用户已修（`41666d8`） | 5m/1h 都补了 `sum(rate(total))` |
| 2.11 | `gitlab_rails['nginx']['listen_port']` 不存在 | 12 处改 `nginx['listen_port']`；`sed -i` 方向修正 | 线上：`external_url` 无端口、`LISTEN 0.0.0.0:80`、`gitlab-ce 19.5.0` |
| 2.12 | CNPG 恢复用不存在的 `spec.recovery` | 改 `spec.bootstrap.recovery` + 顶层 `externalClusters` | 与 `cnpg-operator-how-it-works` 的正确写法一致 |

用户在本轮之前已自行修掉的两条（`c201de5` / `41666d8`）：kube-proxy 残留（`kubeProxy.enabled=false`，Service/ServiceMonitor/Rule/Dashboard 已清，`KubeProxyDown` 已消失，实测确认）与 burn-rate/SLO 模板。台账沿用用户写的「修复状态」行，没有覆盖。

## 3. P1 本轮顺带修的 6 条

| 位置 | 改动 | 依据 |
|---|---|---|
| `07/notes/ipip-vs-vxlan-explained.md:186` | 76 字节 → **50 字节**（外层 IP+UDP+VXLAN+内层以太） | 与同文 5.4 节、Cilium 官方一致；MTU 1450 |
| `07/notes/traefik-routing-architecture.md:116` | `permanent: true` → GET 301 / 非 GET 308 | 现网实测（GET 301、POST 308） |
| `04/notes/prometheus-promql-alerting-tutorial.md:647,2264` | etcd quota 8GB → **2GiB** | `etcd_server_quota_backend_bytes=2147483648` |
| `11/notes/platform-gitops-repo/etcd-README.md:121` | `etcdctl snapshot restore` → **`etcdutl snapshot restore`**，并改成三台各自恢复、token 一致、补 `--bump-revision/--mark-compacted` | 实测 etcdctl 3.6.6 的 `snapshot` 只有 `save`；`etcdutl snapshot restore` 存在 |
| `README.md` / `00/README.md` / `00/assets/hyperv-host-20261111/README.md` | GitLab 19.4.2/19.4 → **19.5.0** | `/api/v4/version`、`version-manifest.txt` |
| `README.md` 监控行 | PrometheusRule 41/ServiceMonitor 14 → **44 / 27（注明口径）** | `kubectl get … -A`：44=41+2+1，27=14+13 |

## 4. 「版本对不上」怎么处理（新增口径）

你提的这点成立，本台账按下面三档处理，不再一律算错：

1. **描述"我现在是什么"的表**（README 状态表、current-state、`00` 拓扑树）→ 必须是当前值，漂了就是错，**已改**（GitLab、PM/SM 计数）。
2. **描述"当时发生了什么"的过程记录**（`notes/` 里的 1.29、Calico 3.27.4、containerd 1.7.22、etcd 3.5.12、Kaniko）→ 是历史事实，**不算错**；需要的是加时间/版本标注，不改正文。审计报告里这部分从"事实错误"降级为"历史阶段"，见 `audit-report.md` §3 表头说明。
3. **同一个"当前值"在两处写不同的数**（如 TIME_WAIT 127/185/189）→ 仍算错，因为它不是版本演进，是抄写不一致；本轮未逐条核（需重新采集），列为待处理。

## 5. 现场真实故障（不在文档里，但影响文档结论）

| # | 现象 | 根因（已实测） | 状态 |
|---|---|---|---|
| 1 | Ceph 面板全空，`ceph_health_status` 无数据 | `ScrapeConfig monitoring/ceph-mgr` 硬编码 `10.0.0.31:9283`（ceph-01，**standby**）；active mgr 在 `10.0.0.41`（ceph-02）。前者 `/metrics` 返回 200 + 0 字节，后者 1090 条 `ceph_*` | **已修**：`staticConfigs` 改成 ceph-01 + ceph-02 两个 target（active 返回指标、standby 返回空，主备切换不用改配置）。实测 `ceph_*` 序列回到 **1090**，`ceph_health_status=0` |
| 2 | `CephClusterHealthUnknown` / `CephMGRMetricsMissing` 常驻 critical | 上面第 1 条的连带：`absent(ceph_health_status{cluster="ceph-prod"})` 成立 | **已消除**：指标恢复后两条从 firing 列表消失（实测只剩 AM 两条 + Watchdog + InfoInhibitor） |
| 3 | `AlertmanagerFailedToSendAlerts`（webhook, serverError） | 线上 `n8n-webhook` 指向公网隧道 `https://n8ntrace.ccwu.cc/...`，实测 `curl` 连接失败（code=000，Cloudflare IP 104.21/172.67 被 reset）；集群内 `n8n-svc:5678` 返回 **200** → 线上配置漂移 | **已修**：`platform-gitops` `da1fc72` 改成 in-cluster 地址，ArgoCD selfHeal 已同步，Alertmanager 12:58:43 重载；重载后无新增失败（旧失败率在 10 分钟窗口内衰减） |
| 4 | `KubeProxyDown` 常驻 critical | kube-proxy 已移除但上游 `absent(up{job="kube-proxy"})` 仍在 | **线上已修**（用户 `c201de5`，实测 firing 列表里已消失） |
| 5 | `kube-system/prometheus-kube-proxy` 残留 Service | chart 未清理 | **线上已修**（同上，实测已无） |

> 1~5 处理完之后，firing 列表只剩 `Watchdog` 与 `InfoInhibitor`（正常信号）；两条 `AlertmanagerFailedToSendAlerts` 会随 10 分钟 rate 窗口自然衰减。
>
> 遗留观察项：**ceph-03 上没有运行 mgr daemon**（`10.0.0.51:9283` 连接拒绝，`ceph -s` 只显示 1 active + 1 standby）。等 ceph-03 的 mgr 起来后再把第三个 target 加回 `ScrapeConfig`。

## 6. 对审计报告自身的三处更正

审计也会错，一并记下来：

1. **Ceph 节点 "10.0.0.116/117/118"**：我在 §3 写"该 IP 不存在"，更准确的说法是 —— **116/117/118 是 PVE 的 VMID**（`nfs01`/`backup`/`db01`），IP 是 `10.0.0.31/41/51`。原文把 VMID 当 IP 写，属表述错，不是凭空地址。已按此改 `k8s-cluster-report.md:617`。
2. **`NetworkPolicy 0`**：该表统计的是 **Calico CRD 实例**，所以"0"本身没错；错的是结论写成了集群级事实（原生 NP 有 23 条）。§3 已按"表述错"降级，并已改原文加注。
3. **PVE 8.4.13**：原先标"未验证"。现已用 `root@10.0.0.1` 核实：`pve-manager/8.4.13/5b08ebc28`、内核 `6.8.12-15-pve`、4 个存储池（`local` 98G / `local-lvm` 832G thin）、17 台 VM（其中 9 台 running）。文档这一条是对的。

## 7. 本轮新增的实测事实（供后续引用）

| 项 | 值 | 来源 |
|---|---|---|
| PVE | `pve-manager 8.4.13`，kernel `6.8.12-15-pve`，80 线程 / 62 GiB，`local-lvm` thin 832G | `pveversion`、`free -g`、`pvesm status` |
| PVE 内存水位 | 58 / 62 GiB 已用（available 3 GiB），负载 7.6 | `free -g`、`uptime` |
| Ceph 节点 | VM 116/117/118 = `nfs01`/`backup`/`db01` = `10.0.0.31/41/51` | `qm guest cmd <vmid> network-get-interfaces` |
| GitLab | CE 19.5.0，`external_url http://192.168.67.201`（无端口），nginx 监听 `0.0.0.0:80` | `version-manifest.txt`、`ss -lntp` |
| Harbor | `goharbor/harbor-core:v2.14.5`、`nginx-photon:v2.14.5` | `docker ps` |
| Hyper-V | `ubuntu01` Running 8 GiB（GitLab）、`ubuntu02` Running 6 GiB（Harbor）、`ubuntu03`/`kali` Off | `Get-VM` |
| etcd | 3.6.6；`etcdctl snapshot` 只剩 `save`，恢复必须 `etcdutl` | `etcdctl snapshot --help`、`etcdutl snapshot restore --help` |

## 8. 复现验证（本轮跑过的命令）

```bash
# 集群侧（本轮改动的两处）
kubectl -n monitoring get scrapeconfig ceph-mgr -o yaml | sed -n '/staticConfigs/,/^  [a-z]/p'
git -C platform-gitops log --oneline -1        # da1fc72 fix(monitoring): point n8n webhook at in-cluster service
kubectl -n argocd get app platform-monitoring-stack -o custom-columns='SYNC:.status.sync.status,HEALTH:.status.health.status'

# 文档侧
bash -n docs/04-monitoring-gitops/{notes/wecom-alert-receiver-20261001,assets/wecom}/apply.sh
helm template t /tmp/ciliumchart/cilium --set kubeProxyReplacement=true | grep kube-proxy-replacement
helm template t /tmp/ciliumchart/cilium --set 'ipam.operator.clusterPoolIPv4PodCIDRList={10.0.0.0/16}' | grep cidr
kubectl -n kube-system exec kube-apiserver-m01 -- kube-apiserver --help | grep -c target-ram     # 0
kubectl -n kube-system exec kube-vip-... -- kube-vip --help | grep -i preserve                  # vip_preserve_on_leadership_loss

# 主机侧（只读）
ssh root@10.0.0.1 'pveversion; pvesm status; free -g'
ssh root@192.168.67.201 'grep -E "^external_url" /etc/gitlab/gitlab.rb; ss -lntp | grep ":80 "'
ssh root@192.168.67.202 'docker ps --format "{{.Names}}\t{{.Image}}" | grep harbor-core'
ssh tfadmin@192.168.67.110 'powershell -NoProfile -Command "Get-VM | Format-Table Name,State,MemoryAssigned"'
```

> 所有主机操作均为只读（`pveversion`/`pvesm status`/`qm list`/`qm guest cmd`/`grep`/`ss`/`docker ps`/`Get-VM`）。
> 唯一对集群的写操作是本轮之前用户已完成的 `kubeProxy.enabled=false`；本轮未改集群。

---

## 9. 第二轮：按「当前状态表 vs 历史记录」重清一遍（2026-11-11 晚）

第一轮修的是"照抄会失败"；这一轮按你提的口径，把剩余条目分成两类处理：

- **A 类｜当前状态**：描述"现在是什么"的表/句子 → 必须等于实测值，**改数值**。
- **B 类｜历史记录**：`notes/` 里描述"当时发生了什么" → **不改正文**，只在文首加统一状态头（`状态：历史快照 / 已作废`+ 采集时间 + 集群版本 + 指向 current-state）。
- **C 类｜技术性错误**：与年代无关的机制/命令/语法错（例如 PromQL 不合法、Capability 说成 privileged）→ 无论哪一类都改。
- **D 类｜审计误判**：我判错或测错的，**撤回并把理由写下来**。

### 9.1 A 类：当前状态表（已改 17 处）

| 文件 | 原值 | 实测值（2026-11-11） |
|---|---|---|
| `15/README.md` ×2、`00-verification-matrix` ×3、`11-middleware-os`、`15-network` | TIME_WAIT 127 / 185 / 189 | **121**（worker01，`ss -tan state time-wait`；随流量波动） |
| `11-middleware-os`、`00-verification-matrix` | conntrack 947 / 953 | **773 / 262144** |
| `08-cicd-release`、`00-verification-matrix`、`10-pipeline-release-artifacts` | 54 个 25%/25% | **51**（全集群 74 个；补 25%/50%、1/1 两类） |
| `09-observability`、`00-verification-matrix` | "52 job = 27 SM + 16 PM" | 52 = 27 SM + 16 PM + **9 个 chart 内置 scrapeConfig**（115 target） |
| `00-verification-matrix` | 证书轮换 ✅ | ⚠️ 配置对但**从未触发**（无 CSR） |
| `00-verification-matrix` | kubelet 可低 3 minor ✅ | 📚 规则对，但本环境**零偏差未复现** |
| `00-verification-matrix` | "VIP 10.0.0.252" | Traefik LB 10.0.0.252 / **API VIP 10.0.0.168** |
| `10-irreversibles` | etcd keys 8243 | **8234** |
| `04-current-state` | 68 groups / 251 rules | **51 alerting groups / 250 rules；16 recording groups / 94 rules**（表头加"采集时间"） |
| `13/README` | "GitLab 是 OIDC/SAML 的 SP" | GitLab 是 **OIDC 的 IdP**、SAML 的 SP |

### 9.2 C 类：技术性错误（已改 15 处 + GitOps 源）

| 位置 | 改动 |
|---|---|
| `04/notes/prometheus-promql-alerting-tutorial.md:720` | `sum(...) offset 1d` → `sum(rate(x[15m] offset 1d))`（原写法 parse error） |
| 同文 `:179` | target 清单里 `kube-proxy 6` → **0（已移除）** |
| `04/manifests/rules/coverage-gap-alerts.yaml`、`bsm-coverage-alerts.yaml` | `CalicoNodeNotReady`→`CiliumAgentNotReady`（`pod=~"cilium-[a-z0-9]+"`）、`CalicoKubeControllersDown`→`CiliumOperatorNotReady`；bsm 里那两条与 coverage-gap 表达式完全相同的副本**直接删除**（同一故障会出两套告警）。**GitOps 源** `platform-gitops` `742e8e8` + `eca603e`，ArgoCD 已同步：248 条规则、CNI 家族只剩 2 条、求值 0 错误、firing 只剩 Watchdog + InfoInhibitor |
| `05/04-permissions`、`05/09-case-studies`（3 处） | "Cilium 是 privileged" → Cilium 是 `drop: ALL` + 13 caps；privileged 只有 9 个 ceph-csi + 1 个 buildkitd |
| `03/gitlab-19.4-install.md` | `8082=KAS / 8092=exporter` → 8082/8092 是 **Sidekiq 指标/健康检查**，KAS **8150**（内部 8153），exporter **9168** |
| `03/gitlab-port-80-troubleshooting.md`（2 处） | sidekiq 行注明"指标+健康检查，不承载业务流量" |
| `01/notes/.../01-现状盘点:116` | containerd 2.0 的时间点纠正为"升 **1.36** 之前"；先升 containerd 的真实理由是 1.7.22 < 矩阵下限 1.7.28 且 1.7 已 EOL |
| `09/README`（顺序 + 矛盾点）、`09/scripts/cleanup_checklist.md` | 顺序改成 **删 CR（controller 在线）→ 卸 Operator/Helm → 删 CRD**；"CRD 删了留孤儿"改成"级联删除、不可恢复" |
| `07/notes/kube-proxy-nftables-diagnosis.md` | "Calico BPF 兜底、服务未中断"改为与 README 一致的"没有 BPF 兜底，Service 不可用"，并标注那是未验证的猜测 |

### 9.3 B 类：历史记录加状态头（17 个文件，正文不动）

```text
docs/07-networking/notes/kube-proxy-nftables-diagnosis.md        ← 2026-10 Calico/kube-proxy 时代
docs/06-storage-ceph/notes/cnpg-upgrade-postmortem-2026-11-08.md
docs/06-storage-ceph/notes/ceph-csi-restart-analysis.md
docs/06-storage-ceph/notes/ceph-disk-optimization-2026-11-05.md
docs/08-control-plane-ha/notes/kube-vip-apiserver-analysis.md
docs/00-cluster-overview/notes/k8s-cluster-report.md             ← 2026-09 K8s 1.29.8 / Calico 3.27.4
docs/00-cluster-overview/notes/production-readiness-gaps-20261109.md
docs/13-sso-oidc/notes/01..05-*.md                               ← 已作废：Keycloak 方案
docs/11-gitops-platform/notes/platform-gitops-repo/{sso-README,SSO-OPS-TUTORIAL,KEYCLOAK-BASICAUTH-EXPLAINED,GRAFANA-SSO,argocd-README}.md
```

统一格式：

```text
> **状态：历史快照（2026-10，K8s 1.29.8 / Calico / kube-proxy-IPVS）**
> 本文是当时的过程记录与命令，保留原样以便复盘；其中"当前"指当时的当前。
> 集群现在已经是 K8s 1.35.9 + Cilium 1.20.4（kube-proxy 已移除），照本文排障前先看现状：current-state.md。
```

Keycloak 那 10 篇用另一套头：`状态：已作废（Keycloak 时代的 SSO 方案）` + 说明最终用 GitLab 作 IdP + 指向 13 章 README。这样"逐字节重复的旧架构文档"从误导源变成可辨别的归档。

### 9.4 D 类：审计误判与自查更正（4 条）

| 原判 | 实际情况 | 处理 |
|---|---|---|
| "Sidekiq 不存在任何监听端口，8082/8092 是错的" | **错判**。`ss -lntp` 显示 8082/8092 都是 ruby（sidekiq-cluster 指标 / health-checks），文档原文是对的 | 撤回，改为补注"指标+健康检查，不承载业务流量"；真正错的是同一文档里 KAS/exporter 的端口 |
| "cookie secret 长度单位写错" | **错判**。oauth2-proxy 按字符串字节计，`openssl rand -hex 16` = 32 字符 = 32 字节，合法 | 撤回，不改 |
| "Ceph 被写成 20.2.0 Tentacle" | 该处是**待核清单项**，同文 §10.2 已实测否掉（18.2.8 reef） | 撤回；只在"待核项未回填结论"层面保留提醒 |
| 批次 3 初版把 5 篇 notes 一律标成「2026-09/10 + K8s 1.29.8 + Calico」 | **一刀切**：`cnpg-upgrade-postmortem`（11-08，1.35.9，calico 只是调试镜像）、`ceph-disk-optimization`（11-05，1.35.9 + Calico）、`production-readiness-gaps`（11-09，1.35.9 + Cilium）都被标错 | 已按每篇自己的日期/版本重写状态头（`round2_e.py`），并在 9.3 注明"版本按各篇正文" |
| 第一轮说"所有 YAML 可解析（0 错误）" | **测量缺陷**：检查器用的 venv 里没有 PyYAML，`if yaml:` 为假 → 整段被静默跳过 | 改用 `/usr/bin/python3` 重验 197 个 YAML：33 个是 Helm/占位符模板（按设计跳过），**真实报错 1 个**——`alertmanagerconfigs` CRD 里 `=` 键触发 PyYAML 的 `tag:yaml.org,2002:value` 限制（`kubectl` 能正常解析，不是 YAML 缺陷）；检查器已改成缺 PyYAML 时显式告警而不是静默跳过 |

### 9.5 剩余 backlog（约 60 条，尚未处理）

多为"同一事实抄写不一致"和细节表述，不影响上手，按需再清：

- `04`：日志轮转文件数 14/17、PromQL 章节里若干"坑"的表述、Tempo 采样成本数字；
- `05`：`sudo` 与环境变量继承、`su` 无日志、`fs.nr_open`、cgroup 磁盘配额、`oscap` profile 名；
- `06`：PV 数 18/17、Released PV 清理顺序两份文档相反、`radosgw-admin caps` 用法、PE 大小算式；
- `12`：`virt-customize` machine-id、扩容三步缺 LV/文件系统、thinline 容量算式；
- `16`：Kafka 堆大小单位、Nginx 并发公式漏反向代理双连接；
- `13`：Grafana 管理员组映射两处不一致、oauth2-proxy 接入模式描述相反。

需要的是一条条重测再改，不适合批量替换——这类我建议按"谁维护谁核"的方式，用 `assets/current-state.md` 当唯一数字源。

---

## 10. 第三轮：按模块清 backlog（2026-11-11 深夜）

前两轮清掉了 P0 与"当前状态表"，这一轮按模块把 P1/P2 里剩余的技术错误逐条核到线上再改。
规则不变：**A 当前状态改数值｜B 历史记录加状态头｜C 技术错误无论年代都改｜D 判错的撤回**。

### 10.1 06 存储 / Ceph（12 处）

| 位置 | 改动 | 实测依据 |
|---|---|---|
| `notes/ceph-csi-upgrade-to-operator-2026-11-09.md` | Ceph **20.2.0 Tentacle → 18.2.8 Reef** | `ceph -s`：`ceph version 18.2.8 reef` |
| `README.md`、`notes/pv-cleanup-report.md` ×2 | 18 个 PV → **17**（清理报告标"当时快照"） | `kubectl get pv \| wc -l` = 17，全部 Bound |
| `notes/ceph-rbd-released-pv-audit-20261005.md` | 清理顺序与因果：`Retain` 下删 PV 不触发 CSI 删镜像；**先删 PV → 再删镜像**；"只删 PV 会新造 7 个僵尸卷"是错的（那 7 个是既有孤儿） | 语义推理 + 原文自述的两条时间线 |
| 同上（告警段） | `kube_persistentvolume_created{phase="Released"}` → 与 `kube_persistentvolume_status_phase{phase="Released"} == 1` 做 `and on(persistentvolume)`；`count(… > 0)` → `count(… == 1)` | `kube_persistentvolume_created` 无 `phase` 标签 |
| `notes/minio-vs-ceph-rgw-analysis.md` | 删掉 **CVE-2024-9331** 归因（NVD/GHSA 查无此条）；改为"匿名访问才是风险" | `curl http://10.0.0.31:7480/testbucket/` → **403**（非 public） |
| `notes/pg-s3-incident-report.md` | CLOG 段 **8KB → 256KB**（8KB 是页） | PG SLRU 段 = 32 × 8KB |
| 同上（交叉验证表） | "不是同一个 Ceph" → **是同一套**（同 mon / 同 clusterID `594e535e…`），RBD 与 RGW 只是两种接入方式 | `kubectl get sc ceph-rbd-sc` 的 clusterID；tempo3 的 PVC 也是 `ceph-rbd-sc` |
| `notes/ceph-rbd-released-pg-backup-…md` | `radosgw-admin caps add … "read,write,delete"` → **S3 bucket policy**；并更正"caps add 不存在"（caps 是 admin-ops 权限，参数要 `--caps=`） | `radosgw-admin` 子命令语义（caps = users/buckets/usage/meta） |
| `notes/cnpg-upgrade-postmortem-2026-11-08.md` | rp_filter 实测表：**all=0**（default/eth0/eth1=2） | 6 节点逐个读 `/proc/sys/net/ipv4/conf/*/rp_filter` |

### 10.2 12 Proxmox / IaC（7 处）

| 位置 | 改动 | 实测依据 |
|---|---|---|
| `notes/pve-vg-thinpool-analysis-2026-11-06.md` | `64M × 4096 = 16G` → **`PE 4M × 4096 = 16G`** | `vgdisplay -v pve`：`PE Size 4.00 MiB`、`Free PE 4096` |
| 同上 | `root 45G/94G (51%)` → **29G/94G (32%)**（标注 11-06 当时为 45G/51%） | `df -h /`：94G / 29G / 62G / 32% |
| 同上 | `discard_passdown` 因果：三层（VM `discard=on` + pool `discard_passdown` + SSD）都要开 | 存储栈语义 |
| `iac/05-batch-ops.md` | "delete pod <primary> = switchover" → **`kubectl cnpg promote`**，并说明 delete 是 failover | CNPG 语义 |
| 同上 | 扩容补 **`lvextend` + `resize2fs`**（原来只 growpart+pvresize，`df` 不会变），并修掉单引号里换行的写法 | LVM 扩容流程 |
| `10-kvm-…md` | 第 8 章子标题 `7.1/7.2/7.3` → **8.1/8.2/8.3** | 目录层级 |
| `iac/02-cloudinit-golden-template.md` | "openEuler 只有 PATA 没有 ATAPI" → **q35 机型没有 IDE 控制器**，`ide2` 不可见；`virt-customize` **不会**随机化 machine-id（用 cloud-init 或 `--run-command 'truncate -s 0 …'`） | q35 硬件拓扑 |

### 10.3 05 Linux（9 处）

| 位置 | 改动 | 实测依据 |
|---|---|---|
| `01-kernel.md` | "m01 SELinux 启用" → **内核注册了 selinux LSM，但 `/sys/fs/selinux` 为空、无 selinuxfs 挂载 = 未启用** | node-exporter 读 `/host/sys/kernel/security/lsm`（含 selinux）与 `/host/sys/fs/selinux`（空目录）；worker01 为 apparmor |
| `sudo-su-详解.md` ×3 | 提权工具的默认环境策略改为 **`env_reset` 清空环境**（只留白名单），非登录壳同理；`su` 有 PAM 日志但**无命令级审计** | sudoers 默认策略 |
| 同上 | `sudo` 加 `-i` 再带 `-c` 不合法 → 改成 `sudo -i sh -c '…'`（`-c` 是 su 的选项） | `sudo --help` |
| `08-kernel-params-limits.md` | "`fs.nr_open` 不能超过 `file-max`" → **无此约束**（前者单进程闸门、后者系统总量） | 内核文档 |
| `03-filesystem-storage.md` | "容器配额由 cgroup 决定" → **cgroup v2 无磁盘容量配额**（只有 io.max），容量靠 PVC / XFS project quota | cgroup v2 无容量控制器 |
| `04-permissions…md` | setgid 符号 `rws` → **`r-s`**（无组执行位时显示 `S`） | `ls -l` 语义 |
| `notes/memory-analysis-m01.md` | "12 线程 = GC 并行度不足 / trace 3.5s = GC STW" → **OS 线程数 ≠ GC 并行度**（看 GOMAXPROCS/P），trace 是请求级追踪，GC STW 看 `gctrace`/`go_gc_duration_seconds` | Go runtime 语义 |
| `notes/app-removal-record.md` | 脱敏坏掉的 `grep -oP 'DBPassword=<redacted>'` → `grep -oP 'DBPassword=\K.*'` | 可直接执行 |
| `07-systemd-boot.md` | m01 行整列错位，补一个 `-`（firmware 无值） | 12.9 = 2.0+3.2+7.7 |

### 10.4 04 监控 / SLO（11 处）

| 位置 | 改动 | 实测依据 |
|---|---|---|
| `notes/retention-unification-5d.md` | 加状态头：**Prometheus 现在是 15d / 25GiB**，不是 5d；对象存储是 **Ceph RGW 不是 MinIO**（文中 12 处 `mc`/ILM 在 RGW 上跑不通）；表内两行同步改 | `--storage.tsdb.retention.time=15d`、`size=25GiB`；Loki 配置里 endpoint `http://10.0.0.31:7480` |
| `notes/prometheus-promql-alerting-tutorial.md` | 通知渠道：**邮件（QQ 企业邮 SMTP）→ Webhook（n8n + 企业微信）**；`default-email` 存在但无 route 引用 | AM 生成配置里 receiver 只有 `n8n-webhook`、`wecom` |
| 同上 | `kubectl get prometheus prometheus` → **`prometheus-prometheus`** | 该 CR 实例名实测 |
| 同上 | `histogram_quantile` 漏 `by (le)` 的后果：**空结果**，不是"+Inf 垃圾值" | PromQL 语义 |
| 同上 | 抑制示例 `equal: [node]` 对 `KubePod.*` 无效（那些告警没 node 标签），补 `on(namespace,pod) group_left(node) kube_pod_info` 的写法 | 指标标签 |
| 同上 | promtool 用例 2 注释"3 次"与 `values: '0+1x10'`（10 次）矛盾 → 改 `0+1x3` | 数据自证 |
| `notes/monitoring-coverage-gap-report.md` | Loki 规则补 `by (le)`；Knative 规则把 `_sum` 改成 `_bucket` | 同上 |
| `10-observability-engineering.md` | "Counter 重置 → rate 出现负值" → **rate 恒 ≥0，只会尖刺** | PromQL 语义 |
| 同上 | 轮转文件 "14 个" → 当时 14 / **2026-11-11 复核 24 个**（动态量） | alloy `find /var/log/pods -name '*.log.*'` = 24 |
| `notes/observability-lab.md` | "14 个 ServiceMonitor" → 当时 14 / **现 27 SM + 16 PM** | `kubectl get servicemonitors -A` |

### 10.5 13 SSO（2 处）

| 位置 | 改动 | 实测依据 |
|---|---|---|
| `notes/05-grafana-sso.md` | `role_attribute_path` 与线上不一致 → 对齐到线上（`root` 用户名或 `digitalsupply` 组 → GrafanaAdmin） | `kubectl -n monitoring get cm prometheus-grafana` 的 `grafana.ini` |
| `notes/04-…forwardauth.md` | 补一句：**最终是反向代理模式**（IngressRoute 后端直接是 `oauth2-proxy-<host>`），ForwardAuth 只是试错；另说明 hubble/alloy/tekton 的 Middleware 现在是 `basicAuth` | `kubectl get ingressroute -n logging alloy` → services `['oauth2-proxy-alloy']` |

### 10.6 本轮撤回 / 不改（3 条）

| 原判 | 结论 |
|---|---|
| "Kafka `MaxHeapSize=1.99GB` 与证据/单位对不上" | **不改**。env 只有 `-Xms128M`、无 `-Xmx`，JVM 取容器/宿主内存的 1/4；1.99GB ≈ 8GiB÷4，与注释一致。节点内存现在 9.7GiB，今天重算得 2.4GB —— 数值随节点变，不是错 |
| "cnpg 复盘把 CNI 写成 Calico（实际 Cilium）" | **撤回**。该文写于 2026-11-08，Cilium 迁移是 2026-11-09，**当时确实是 Calico**；已在文首状态头说明 `calico-node` 只是借来调试 |
| "`testbucket` 是 CVE-2024-9331" | 原文错，但不是"撤回"：CVE 编号查无此条、实测匿名访问 403 —— 已按 C 类改掉归因 |

### 10.7 剩余（约 25 条）

多为"同一事实多处抄写不一致"或需要业务口径才能定值的项：

- `04`：PromQL 章节里若干"坑"的表述、Tempo 采样成本数字；
- `05`：`oscap` profile 名、cgroup 磁盘配额示例（原理已改，示例未重写）；
- `06`：README 与 notes 间的 PV/PVC 明细核对（本次只统一了总数）；
- `12`：`thinline` 容量算式、thin pool 的 LV 明细表；
- `13`：Grafana 组映射在 `notes/02` 里还有一份旧写法，需连 SSO 章节一起重写；
- `16`：Kafka 堆大小随节点内存变化的算法（数值已确认合理，未写"如何按节点算"）。

这些不再按"文档 bug"处理，属于**需要作者补业务口径**的部分；建议以 `00-cluster-overview/assets/current-state.md` 当唯一数字源，以后只维护那一处。

---

## 11. 第四轮：把"当前状态"收敛成唯一数字源（2026-11-11 深夜）

审计里反复出现同一类问题：**同一组数字被抄在两个地方，两边一起漂移**。
根 README 说 44 个 PrometheusRule / 27 个 ServiceMonitor，`04-current-state.md` 也说 44 / 248，
而现场是 **43 / 26 / 248**。改哪边都只是把漂移推迟到下一次。

这一轮换了做法：**建一个唯一数字源，其他章节不许再写死数字**。

### 11.1 新增：可重复采集的 canon

| 文件 | 作用 |
|---|---|
| `docs/00-cluster-overview/assets/collect_current_state.py` | 只读采集（kubectl + Prometheus API），输出 Markdown 表格 |
| `docs/00-cluster-overview/assets/current-state.md` | **唯一数字源**。§0 写纪律，`BEGIN/END GENERATED` 之间由脚本产出，§8 起是手写拓扑/配置 |
| `docs/00-cluster-overview/assets/current-state-raw-20261110.md` | 原 2026-11-10 的原始 dump，保留作"当时是什么样"的对照 |

canon 结构：§1 版本｜§2 节点与容量｜§3 对象计数（15 类）｜§4 组件版本（15 个组件）｜
§5 Prometheus 运行态（组/条/错误/target/保留期/firing）｜§6 存储｜§7 入口｜
§8 Ceph（`ceph -s` 实测）｜§9 外部宿主机｜§10 入口路由与鉴权｜§11 保留期与告警链路｜§12 变更历史。

刷新方式：

```bash
python3 docs/00-cluster-overview/assets/collect_current_state.py > /tmp/cs.md
# 用 /tmp/cs.md 替换 current-state.md 里 BEGIN GENERATED 与 END GENERATED 之间的内容
```

### 11.2 删掉的重复状态表

| 位置 | 处理 | 原来错在哪 |
|---|---|---|
| 根 `README.md` "当前集群状态" | **整表删除**，改为 8 条不变式 + 指向 canon | PrometheusRule 44（实际 43）、ServiceMonitor 27（实际 26） |
| `docs/04-monitoring-gitops/04-current-state.md` | **降级为"监控栈契约"**：只留 selector / CRD 归属 / 接收器 / Grafana 约束 | 版本表、应用数、规则数全是副本；PrometheusRule 44 早已是 43 |
| `docs/04-monitoring-gitops/monitoring-gitops-phase1.md` | 规则/规则数改成指向 canon | `44（35 chart + 6 GitOps + 3 团队）`、`251 alerting` 都是旧值 |
| `docs/04-monitoring-gitops/10-observability-engineering.md` | "52 job，27 SM + 16 PM" → 组成公式 + canon 链接 | SM 27 → 26 |
| `docs/15-interview-cheatsheet/09-observability.md` | 同上 | 同上 |
| `docs/15-interview-cheatsheet/00-verification-matrix.md` | 加"数字口径"声明；把 `TIME_WAIT 121`/`conntrack 773`/`51 个 25%/25%`/`52 job` 等改写成**命令 + 一次取值** | 矩阵的价值是"怎么验"，写死数字会被面试官当成背题 |
| `docs/10-cicd-delivery/10-pipeline-release-artifacts.md` | rollout 分布从写死改成**一条 jq 命令** + 一次取值 | 分布随部署变化，写死必漂 |
| `docs/11-gitops-platform/{README,10-iac-evolution}.md` | "31 个 Application" → 指向 canon | 数量会变 |
| `docs/00-cluster-overview/README.md` | 顶部加"数字口径"；修正鉴权描述 | 原文写"oauth2-proxy 保护 ArgoCD/Tekton/Hubble/Alloy/Traefik" —— **ArgoCD 与 Grafana 走各自原生 OIDC，不在 oauth2-proxy 后面**（IngressRoute 后端实测） |
| `docs/02-cilium-ebpf/README.md` | "当前状态（2026-11-10）" → 只留数据面形态，版本/数量指向 canon | 写死 1.20.4 / 6/6 |
| `docs/06-storage-ceph/README.md` | PV 数量改指向 canon，只留"删了 10 个失效 PV（95Gi）"这类历史事实 | 写死 17 |

### 11.3 判断口径（哪些数字可以留）

留：**结构不变量** —— "3 control-plane + 3 worker"、"2 个 StorageClass"、"kube-proxy 已移除"、
"oauth2-proxy 是反向代理模式"、"ceph-rbd-sc 是 Retain"。这些变了就是架构变了，值得改文档。

不留：**运行态计数** —— Pod 数、Deployment 数、PV 数、规则条数、target 数、ServiceMonitor 数、
应用数、版本号（升级就变）、TIME_WAIT/conntrack 这类秒级波动量。这些一律 canon 或现算。

### 11.4 验证

```bash
# 1) 采集脚本能跑通（exit 0，输出 7 个小节）
python3 docs/00-cluster-overview/assets/collect_current_state.py | grep -c '^### '     # → 7

# 2) 全仓库断链为 0（本轮改了 21 处链接）
python3 <检查器> .   # MD_BROKEN_LINK: 0 / MD_FENCE_UNBALANCED: 0 / SH_SYNTAX_ERROR: 0

# 3) canon 里的数字与现场一致（抽查三处）
kubectl get pv --no-headers | wc -l                                  # 17
kubectl get servicemonitors.monitoring.coreos.com -A --no-headers | wc -l   # 26
kubectl get prometheusrules.monitoring.coreos.com -A --no-headers | wc -l   # 43
```

> 遗留：`notes/` 下的历史文档里仍有旧数字，那是**历史快照**，按第二轮的规则不动正文
> （文首已有"状态：历史快照"头）。仓库里现在只有一处"当前值"，就是 `current-state.md`。
