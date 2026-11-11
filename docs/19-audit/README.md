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

## 修复关键

见报告第 7 节的四个批次。最有价值的两条工程化建议：

- 给 `notes/` 统一加 `状态: 历史快照 | 与现状一致 | 已作废`、`采集时间`、`对应集群版本` 三个字段；
- CI 里对脚本跑 `bash -n`/`shellcheck`，对安装命令跑 `helm template`，对 YAML 跑 `kubectl --dry-run=server` —— 本次三个 P0（`kubeProxyReplacement=strict`、废弃 CIDR 键、JSON Patch `values`）都能被拦住。

## 文档

| 文件 | 内容 |
|---|---|
| [audit-report.md](audit-report.md) | 主报告：结论、P0 12 条、P1 事实错误、内部矛盾清单、现场真实故障、修复批次 |
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
