# 19 · 仓库自审（2026-11-11）

这一章不是环境教程，是对**本仓库前 18 个分类**的一次审计：把文档里写的版本、数量、拓扑、命令，逐条拿去和当时还在跑的集群对。

## 当时的情况

仓库在 2026-11-10/11 两天里快速并入了十几篇新文档（IaC、SRE、安全、中间件、KVM、容器），所有分类都宣称"来自真实环境"。但过程记录（`notes/`）横跨 2026-09 到 2026-11，中间集群经历了三次大改：

- CNI：Calico `v3.27.4` → Cilium `1.20.4`（KPR，kube-proxy 移除）；
- Kubernetes：`v1.29.8` → `v1.35.9`（逐级 7 跳），etcd `3.5.12` → `3.6.6`；
- 存储/交付：Ceph 从"疑似 Tentacle"核实为 `18.2.8 reef`；GitLab `19.4.2` → `19.5.0`；构建器 Kaniko → BuildKit。

结果是：同一事实在仓库里有两种甚至三种写法，而且**都标着"实测"**。

## 主要概念与原理

### 1. 文档漂移的三种形态

| 形态 | 例子 | 危害 |
|---|---|---|
| 版本漂移 | GitLab 写 19.4.2，实际 19.5.0 | 按旧版本行为排障 |
| 数量漂移 | PrometheusRule 写 41（实为单命名空间；全集群 44） | 基线算错 |
| 拓扑/机制漂移 | notes 仍按 Calico + kube-proxy 写排障步骤 | 命令跑不通、方向错 |

### 2. 为什么"历史记录"会变成"错误"

`notes/` 本身没问题——它记录当时发生了什么。问题在于它和"当前状态"平铺在同一层，读者无法判断哪篇是现状。审计里最典型的一条：13 章 README 写 GitLab OIDC，5 篇 notes 却还在教 Keycloak 接入。

### 3. 审计口径

- **只以实测为准**：`kubectl`/`ceph`/`curl` 的输出高于文档里的任何断言；
- **不因"版本没见过"判错**：这套环境跑的是未来版本（k8s 1.35、Cilium 1.20、Prometheus 3.11），只报能用证据证明的问题；
- **区分"能不能跑"和"数字对不对"**：前者是 P0，后者是 P1。

## 踩坑点（审计过程中踩到的）

1. **脱敏会破坏可执行性**：126 处 `<redacted>` 里有 13 个脚本，`wecom/apply.sh` 被改到 `bash -n` 都过不了，而且把 StatefulSet 名也替换了。
2. **子 agent 的结论必须回验**：行号会偏、会把"作者已自我纠正的待核项"当成错误。
3. **"监控正常"要用运行态验**：`ALERTS{alertstate="firing"}` 里 4 条是假告警——组件删了但 `absent()` 规则还在；`up==1` 但指标为空则说明 target 指向了 standby 实例。
4. **同一台机器两个 IP**：PVE `10.0.0.1` 与 `192.168.67.156` 靠证书指纹确认是同一台，不是两台。

## 修复结果（2026-11-11）

- **P0 12/12 已修**：Cilium 安装参数、kube-vip env 名、`--target-ram-mb`、JSON Patch 成员、脱敏脚本、AM 抑制模板、rule 标签、GitLab nginx 键、CNPG 恢复字段。每条都有可复现验证（`bash -n` / `helm template` / 线上配置文件）。
- 作者先修了 2 条（burn-rate 与 SLO 模板、kube-proxy 残留），本轮沿用其「修复状态」写法，不覆盖原文。
- 顺带修了 6 条 P1：VXLAN 开销 76→50 字节、Traefik GET 301/非 GET 308、etcd quota 2GiB、etcd 恢复改 `etcdutl` + 三节点、GitLab 19.5.0、PM/SM 口径。
- **第四轮（唯一数字源）**：新增 `assets/collect_current_state.py` 与结构化 `current-state.md`（§1–§12，7 个小节由脚本生成）；删掉根 README 与 `04-current-state.md` 里的重复状态表（原来 44 规则/27 SM 是错的，实际 43/26），改 21 处引用；同时修正"oauth2-proxy 保护 ArgoCD"的误述 —— ArgoCD 与 Grafana 走各自原生 OIDC。见 fix-log §11。
- **第二轮（当前状态 vs 历史记录）**：17 处当前值改成实测（TIME_WAIT/conntrack/Deployment/SM-PM/证书/etcd keys）、15 处技术错误修正（PromQL offset、CNI 覆盖规则改 Cilium、Cilium 不是 privileged、GitLab 端口表、下线顺序）、**17 个历史文档加统一状态头**（Calico 时代 5 篇、1.29 时代 2 篇、Keycloak 已作废 10 篇）；同时撤回 4 条我自己的误判（Sidekiq 端口、cookie secret、Ceph 20.2.0 待核项、YAML 检查器缺 PyYAML 导致的假 0 错误）。
- **GitOps 覆盖度审计（2026-11-12）**：[gitops-coverage-20261112.md](gitops-coverage-20261112.md) —— 以 ArgoCD `status.resources` 为口径（31 app / 586 对象），列出"该纳管却没纳管"的组件：Cilium/Loki/Tempo/n8n/kube-vip 等 5 个 P0，另有 7 个 P1、5 个 P2，附落地顺序；第 1 批（values 入库）、第 2 批（n8n/runner/buildkitd/nfs/otel 纳管）、第 3 批（Alloy/Loki/Tempo/cert-manager + S3 凭据 SealedSecret 化）、第 3.5 批（Cilium：35 个对象纳管，3 个非幂等 TLS Secret 排除在外）已于 2026-11-12 完成，记录见该文 §7.1–§7.4。收尾态：**41 个 Application / 764 个对象全部 Synced + Healthy**（审计时 31/586）。并在 §1.1 / §6.5 区分**自举层（Tier 0，ArgoCD 之前必须有：kube-vip → CNI → CSI → ArgoCD）**与可 adopt 的 Tier 0.5。
- **第三轮（按模块清 backlog）**：06 Ceph 12 处（Ceph 版本 20.2.0→18.2.8、PV 18→17、`radosgw-admin caps` 语义、Released PV 顺序、CLOG 8KB→256KB、CVE 归因删除）、12 Proxmox 7 处（PE 4M、扩容补 lv/fs 两步、switchover→`cnpg promote`、q35 无 IDE）、05 Linux 9 处（SELinux 未启用、sudo `env_reset`、`fs.nr_open`、cgroup 无磁盘配额、setgid `r-s`）、04 监控 11 处（Prometheus 15d/25GiB 不是 5d、RGW 不是 MinIO、通知渠道是 webhook 不是邮件、两条 PromQL 修语法）、13 SSO 2 处（Grafana 角色映射对齐线上、oauth2-proxy 反代模式）。同时撤回 3 条误判（Kafka 堆大小、cnpg 复盘的 Calico 属当时事实）。
- **集群侧**：Ceph `ScrapeConfig` 改为抓 ceph-01+ceph-02（`ceph_*` 序列回到 1090、两条 critical 假告警消失）；n8n webhook 在 `platform-gitops` 改回 in-cluster（AM 已重载）；CNI 覆盖规则也从 `calico-node` 改成 `cilium-*`（`742e8e8`，Prometheus 规则求值 0 错误）。

## 修复关键

见报告第 7 节的四个批次。最有价值的两条工程化建议：

- 给 `notes/` 统一加 `状态: 历史快照 | 与现状一致 | 已作废`、`采集时间`、`对应集群版本` 三个字段；
- CI 里对脚本跑 `bash -n`/`shellcheck`，对安装命令跑 `helm template`，对 YAML 跑 `kubectl --dry-run=server` —— 本次三个 P0（`kubeProxyReplacement=strict`、废弃 CIDR 键、JSON Patch `values`）都能被拦住。

## 文档

| 文件 | 内容 |
|---|---|
| [audit-report.md](audit-report.md) | 主报告：结论、P0 12 条、P1 事实错误、内部矛盾清单、现场真实故障、修复批次 |
| [fix-log.md](fix-log.md) | 修复台账：P0 12/12 逐条改动与验证命令、现场故障根因、对报告自身的 3 处更正 |
| [findings/g1-overview-k8s.md](findings/g1-overview-k8s.md) | 00 全景 + 01 K8s（24 条） |
| [findings/g2-cilium-networking.md](findings/g2-cilium-networking.md) | 02 Cilium + 07 网络（25 条） |
| [findings/g3-gitlab-cicd-sso.md](findings/g3-gitlab-cicd-sso.md) | 03 GitLab + 10 CI/CD + 13 SSO（23 条） |
| [findings/g4-monitoring.md](findings/g4-monitoring.md) | 04 可观测性（24 条） |
| [findings/g5-linux-container-security.md](findings/g5-linux-container-security.md) | 05 Linux + 14 容器 + 16 中间件 + 18 安全（17 条） |
| [findings/g6-storage-pve.md](findings/g6-storage-pve.md) | 06 存储/Ceph + 12 PVE（20 条） |
| [findings/g7-ha-gitops-sre.md](findings/g7-ha-gitops-sre.md) | 08 控制面 HA + 09 生命周期 + 11 GitOps + 17 SRE（20 条） |
| [findings/g8-cheatsheet-readme.md](findings/g8-cheatsheet-readme.md) | 15 面试速查 + README/当前状态快照交叉核对（16 条） |
| [assets/ground-truth.md](assets/ground-truth.md) | 审计时的实测基准（节点、CNI、组件版本、Ceph、GitLab/Harbor、静态检查） |
| [assets/static-findings.txt](assets/static-findings.txt) | 静态检查原始输出（py/yaml/json/sh/链接/围栏） |

## 复现

审计是只读的，任何一步都可以重跑：

```bash
git clone <repo> && cd k8s-platform-tutorials
kubectl get nodes -o wide
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data}' | python3 -m json.tool
curl -s http://192.168.67.201/api/v4/version      # 需要 token
ceph -s && ceph osd tree
kubectl get prometheusrules,servicemonitors -A --no-headers | wc -l
kubectl -n monitoring exec prometheus-prometheus-prometheus-0 -c prometheus -- \
  wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=ALERTS%7Balertstate%3D%22firing%22%7D'
```

- **凭据面收敛（2026-11-12）**：[security-hardening-20261112.md](security-hardening-20261112.md) —— 集群里 15 处 `glpat-` 明文（含 2 个 root/admin、`scope=api` 的 PAT，以及 `last-applied-configuration` 注解里的原文）全部收敛：ArgoCD 改每仓 deploy token（只读）、CI 改 group token（仅仓库读写）、cicd 7 个 Secret 全 SealedSecret 入库、旧 token 已 revoke（401 验证）。附 4 个迁移坑。
