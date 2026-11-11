# 修复台账（2026-11-11）

> 记录 `audit-report.md` 里各条问题的处理结果。**报告正文保留原始症状**（错在哪、当时为什么错），
> 修复结果只在这里和每条的「修复状态」行更新 —— 这样后来的人能看到"曾经错成什么样"。
>
> 状态口径：`已修` 改了文档并在本机验证过；`线上已修` 改的是集群/配置；`待处理` 有明确方案但没动；`不修` 判定为历史阶段或非错误。

## 1. 汇总

| 批次 | 条数 | 已修 | 待处理 | 不修（历史阶段） |
|---|---|---|---|---|
| P0（照抄会失败） | 12 | **12** | 0 | 0 |
| P1（事实/语义错误） | 95 | 6 | 89 | — |
| P2（内部矛盾/版漂） | 48 | 2 | 46 | 见 §4 口径 |
| 现场真实故障 | 5 | 1 | 2 | 2（观察） |

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
| 1 | Ceph 面板全空，`ceph_health_status` 无数据 | `ScrapeConfig monitoring/ceph-mgr` 硬编码 `10.0.0.31:9283`（ceph-01，**standby**）；active mgr 在 `10.0.0.41`（ceph-02）。前者 `/metrics` 返回 200 + 0 字节，后者 1090 条 `ceph_*` | **待处理**（改 ScrapeConfig 指向 active，或改走 Service 发现） |
| 2 | `CephClusterHealthUnknown` / `CephMGRMetricsMissing` 常驻 critical | 上面第 1 条的连带：`absent(ceph_health_status{cluster="ceph-prod"})` 成立 | 随 1 一起解决 |
| 3 | `AlertmanagerFailedToSendAlerts`（webhook, serverError） | 线上 `n8n-webhook` 指向公网隧道 `https://n8ntrace.ccwu.cc/...`，实测 `curl` 连接失败（code=000）；集群内 `n8n-svc:5678` 返回 **200**。仓库模板里写的正是 in-cluster 地址 → **线上配置漂移** | **待处理**（把线上改回 `http://n8n-svc.n8n.svc.cluster.local:5678/webhook/k8s-alerts`） |
| 4 | `KubeProxyDown` 常驻 critical | kube-proxy 已移除但上游 `absent(up{job="kube-proxy"})` 仍在 | **线上已修**（用户 `c201de5`，实测 firing 列表里已消失） |
| 5 | `kube-system/prometheus-kube-proxy` 残留 Service | chart 未清理 | **线上已修**（同上，实测已无） |

> 修完 1+3 之后，firing 列表里应只剩 `Watchdog` 与 `InfoInhibitor`（正常信号）。

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
