# G3 · GitLab / CI-CD / SSO 审计发现

审计范围：`docs/03-gitlab/`、`docs/10-cicd-delivery/`、`docs/13-sso-oidc/`（含 `assets/`、`notes/`、`scripts/` 下的 md / yaml / sh）。
基准：[`../assets/ground-truth.md`](../assets/ground-truth.md) + 只读实测（curl GitLab/Harbor、kubectl get）。未改仓库、未改任何 GitLab/Harbor 配置。
共 23 条，按严重度排序。

---

### [高] `gitlab_rails['nginx']['listen_port']` 不是有效配置键，整条端口排障链的前提是错的
- 位置: docs/03-gitlab/gitlab-19.4-install.md:166（同错见 docs/03-gitlab/gitlab-fix-port80.md:89,91、docs/03-gitlab/gitlab-port80-cleanup-final.md:24、docs/03-gitlab/gitlab-port80-explanation.md:35、docs/03-gitlab/gitlab-port-80-troubleshooting.md:136-153,519-520,575）
- 原文: 「`gitlab_rails['nginx']['listen_port'] = 8088`」
- 问题: Omnibus 的 `gitlab.rb` 里没有 `gitlab_rails['nginx']` 这一层，写进去不报错但完全不生效。真正决定 nginx 监听端口的是 `external_url` 里的端口（作为默认值）或显式的 `nginx['listen_port']`。因此文档反复讲的因果「改了 external_url，但 listen_port 还是 8088，所以端口没变」是反的：本项目端口能从 80 变成 8088，恰恰是因为 `external_url` 里带了 `:8088`（见 notes/install-and-port.md:32）。更直接的证据是 gitlab-19.4-install.md:100 的 `external_url "http://192.168.67.201"` 并没有端口——若那条 `gitlab_rails['nginx']['listen_port']` 真生效，端口应停在 80，不可能观测到 `0.0.0.0:8088`（同文档 :179）。
- 证据/正确说法: 同仓库 notes/install-and-port.md:33 用的就是正确写法 `nginx['listen_port'] = 8088` 并明确写「`nginx['listen_port']` 才决定 nginx 实际监听端口」；GitLab Omnibus nginx 文档中主站监听由 `external_url` + `nginx['listen_port']` / `nginx['listen_addresses']` 控制，不存在 `gitlab_rails['nginx']`。5 处文档 + 831 行排障时间线都建立在错误键上，需要整体更正。

### [高] 组件—端口对应表错：把 Sidekiq 写成监听 8082/8092，KAS/Exporter 也与同仓库另一文档冲突
- 位置: docs/03-gitlab/gitlab-port-80-troubleshooting.md:79,111；docs/03-gitlab/gitlab-19.4-install.md:152-153
- 原文: 「sidekiq       127.0.0.1:8082 / 8092」/「`127.0.0.1:8082` - GitLab KAS」「`127.0.0.1:8092` - GitLab Exporter」
- 问题: Sidekiq 是纯后台 worker（只出站连 Redis/PostgreSQL），**不存在任何监听端口**，把它列成 8082/8092 会把排障引向「端口没起来」这种不存在的现象。KAS 与 gitlab-exporter 的端口两篇文档各写一套：troubleshooting.md:112-113 写 `gitlab-kas = 8150–8155`、`gitlab-exporter = 9168`，install 文档写 8082 / 8092，两张表至少一张是错的，而排障时正是靠这张表判断「哪些进程正常」。
- 证据/正确说法: Omnibus 默认 KAS 监听 `127.0.0.1:8150`（内部 API 8153），gitlab-exporter 指标端口 9168，postgres_exporter 9187、redis_exporter 9121、workhorse 指标 9229、gitaly 9236——troubleshooting.md:112-117 那半张表与默认值一致，install 文档另半张不一致。实测该主机 `curl http://192.168.67.201:8060/nginx_status` 有响应（403），说明 status 端口确实是 `*:8060` 对外，这与「8082/8092 是服务端口」无任何支持关系。

### [高] 把 127.0.0.1:80 超时归因到一条显式排除 `lo` 的 nft 规则
- 位置: docs/03-gitlab/gitlab-port80-explanation.md:20-23
- 原文: 「`-A CILIUM_PRE_mangle ! -o lo -m socket --transparent ... -j MARK --set-xmark 0x200/...`」「该规则使用 `-m socket --transparent`（透明代理），会拦截某些本地 socket 流量并打上 mark，可能导致回环（127.0.0.1）到 80 端口的 TCP 连接在内核 netfilter/eBPF 路径中被处理异常，表现为 SYN 包"消失"（tcpdump 抓不到）并最终连接超时。」
- 问题: `! -o lo` 的含义是「出接口**不是** lo」，而访问 127.0.0.1 的出接口正是 lo，这条规则在语义上永远不会命中回环流量，用它解释 127.0.0.1:80 超时自相矛盾。文档据此把根因定为「Cilium 残留规则」，并据此选择长期 8088 方案，属于错误归因。
- 证据/正确说法: iptables/nft 中 `! -o lo` = 仅匹配非回环出接口；同系列文档 gitlab-port80-cleanup-final.md:18 又记录「清理 eBPF 后 `127.0.0.1:80` 返回 RC:0（已恢复）」，:30 则记录「LISTEN 但立即 ECONNREFUSED」——三种现象（超时 / 恢复 / 拒绝）互相排斥，说明真实根因（更可能是 nginx `listen` 与 `external_url`/IPv6 绑定的不一致，或本机 OUTPUT 链 DNAT）并未定位，而文档把未收敛的猜测写成了结论。

### [中] 收紧 8060 的修复方案会把整个 GitLab 主站搬到 8060
- 位置: docs/03-gitlab/gitlab-port-80-troubleshooting.md:702-712
- 原文: 「**修复方式**：`nginx['listen_port'] = '127.0.0.1:8060'`，然后 `gitlab-ctl reconfigure`。」
- 问题: `nginx['listen_port']` 控制的是 GitLab 主站（external_url 对应站点的 server 块），不是 `nginx-status.conf` 那个 status vhost。按此改会把整个 GitLab 只绑到 127.0.0.1:8060（外部全部不可达），同时 status 页还占着 `*:8060`，两者抢同一端口。这是把「暴露一个状态页」修成「站点下线」。
- 证据/正确说法: Omnibus 正确写法是 `nginx['status'] = { "listen_addresses" => ["127.0.0.1"], "fqdn" => ..., "options" => {...} }`（GitLab omnibus nginx 文档），或用 `nginx['custom_nginx_config']` 覆盖该 server 块；`listen_port` 只应改主站端口。

### [中] 同一份历史文档里「当前是 80」与「最终保留 8088」并存，全仓库对当前端口有三种说法
- 位置: docs/03-gitlab/notes/install-and-port.md:1 vs :13,:18
- 原文: 「> 历史记录：本文写于 GitLab 19.4.2 / 8088 时期；当前实例已是 19.5.0 / 80。」 vs 「- 最终选择保留 8088，并在 80 上做重定向。」
- 问题: 文档头说当前是 80，正文却仍以「最终保留 8088」作为结论；而 gitlab-port80-cleanup-final.md:34-78 的「最终解决方案」是「8088 + NAT 80→8088 重定向」，README.md:37 与 accounts-roles.md:8 又直接写「端口 80 / external_url http://192.168.67.201」。读者无法判断线上到底是 80、8088，还是 80 跳 8088——这直接决定 webhook/回调/issuer 该写哪个端口。
- 证据/正确说法: 实测 `http://192.168.67.201/` 可达（OIDC discovery 与 API 均在 80 上可用），说明「80 直达」是当前事实；应统一为「当前 external_url = http://192.168.67.201（80），8088/NAT 重定向是历史状态」。

### [中] 安装文档以 19.4.2 为现状，实测 19.5.0；「15 个核心服务」清单不完整
- 位置: docs/03-gitlab/gitlab-19.4-install.md:3,121-136,214
- 原文: 「本文档记录了在 Ubuntu 24.04 上安装 GitLab CE 19.4.2 的完整过程」「**运行中的服务（15个核心服务）：**」
- 问题: 实测 `/api/v4/version` 为 19.5.0 CE（GROUND-TRUTH）。文首没有「版本已漂移」的提示（要翻到 03/README.md:122 才知道），而本文里「15 个服务都在跑 = 正常」是被当作验收标准用的。该清单缺 `sshd`（gitlab-shell）与 `mailroom`，这两个在 Omnibus 默认部署里必然存在，照单核对会把正常实例判成「服务缺失」。
- 证据/正确说法: GROUND-TRUTH「GitLab：http://192.168.67.201，/api/v4/version 返回 19.5.0，Community Edition」；同仓库 README.md:37 亦写 19.5.0。Omnibus 默认 runit 服务集包含 sshd 与 mailroom。

### [中] 03 README 仍把 Kaniko 写成当前构建器
- 位置: docs/03-gitlab/README.md:26,117（另 :93）
- 原文: 「Tekton（cicd ns）→ Kaniko → Harbor（192.168.67.202:8443）→ GitOps tag → ArgoCD」「**CI/CD 链路**：GitLab → Runner → Tekton → Kaniko → Harbor」
- 问题: 实测 `cicd/compassio-build-push` 的 step 镜像是 `compassio/buildkit:v0.20.2-rootless`，Kaniko 自 2026-10-20 起只是回滚路径。03 分类的链路图却还把 Kaniko 画成现役，与 10-cicd-delivery/README.md:25-26（「仓库里写的是 BuildKit」）以及 buildkit-troubleshooting 的结论矛盾；跨分类阅读会得出两种构建器。
- 证据/正确说法: `kubectl -n cicd get task compassio-build-push -o jsonpath='{.spec.steps[0].image}'` → `192.168.67.202:8443/compassio/buildkit:v0.20.2-rootless`（实测）。

### [中] Ceph 版本写成 17.2.8 Quincy，实测是 18.2.8 Reef
- 位置: docs/13-sso-oidc/notes/01-sso-overview.md:48；docs/13-sso-oidc/notes/03-phase2-argocd-harbor-ceph.md:18
- 原文: 「| Ceph Dashboard | 17.2.8 Quincy | ⛔ 阻塞 | Quincy 只有 SAML 2.0；需要 Keycloak 等 SAML IdP |」
- 问题: 集群实测 Ceph 18.2.8 reef，同仓库 13-sso-oidc/README.md:384 也写「实际集群是 **Ceph 18.2.8 Reef**」。两份 notes 把阻塞结论安在一个集群里并不存在的版本上；若有人按 Quincy 的 `ceph dashboard sso setup saml2` 差异去排障会白跑。
- 证据/正确说法: `ceph -s` → 18.2.8 reef（GROUND-TRUTH 存储段）；README.md:384 自证。SSO 结论本身（Reef 只提供 SAML 2.0，OAuth2/OIDC 要 Tentacle+）与 docs.ceph.com 一致，错的是版本号。

### [中] 部署策略统计 54 与实测 51 不符，五类合计 75 而全集群只有 74 个 Deployment
- 位置: docs/10-cicd-delivery/10-pipeline-release-artifacts.md:343-349
- 原文: 「RollingUpdate 25%/25%   54 个 Deployment / Recreate 12 个 / RollingUpdate 0/1 5 个 / RollingUpdate 25%/1 3 个 / RollingUpdate 25%/0 1 个（metrics-server）」
- 问题: 实测（`kubectl get deploy -A`，共 74 个）：25%/25% = 51、Recreate = 12、0/1 = 5、25%/1 = 3、25%/50% = 1、25%/0 = 1、1/1 = 1。文档既把 25%/25% 多算 3 个，又漏掉 `25%/50%` 与 `1/1` 两类，合计 75 > 74，用它做「本集群现状」的基线会算错容量（maxUnavailable 分布）。
- 证据/正确说法: 实测统计输出如上；`Argo Rollouts CRD 未安装`这一条是对的（`kubectl get crd | grep rollout` 无输出），仅数字部分需要按实测更正。

### [中] TriggerTemplate 仍把 CI Pod 硬钉 worker03，README 却把「去掉硬钉」列为已修
- 位置: docs/10-cicd-delivery/assets/tekton/03-trigger.yaml:56-61（README.md:178-183 声称已修）
- 原文: 「podTemplate: / nodeSelector: / kubernetes.io/hostname: worker03 / tolerations: / - key: node-role.kubernetes.io/control-plane / operator: Exists」
- 问题: 集群实测的 `compassio-template` 里 `nodeSelector` 仍是 `worker03`，即「坑 5：CI Pod 硬钉 worker03」从未修掉，README 写在「修复」段落是错的。另外给一个 worker 节点 selector 配 control-plane 容忍逻辑上无意义（容忍只在节点带对应 taint 时才起作用），照抄会让人以为已经考虑了控制面调度。
- 证据/正确说法: `kubectl -n cicd get triggertemplate compassio-template -o jsonpath='{.spec.resourcetemplates[0].spec.taskRunTemplate}'` → `{"podTemplate":{"imagePullSecrets":[...],"nodeSelector":{"kubernetes.io/hostname":"worker03"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists"}]},"serviceAccountName":"pipeline"}`（实测）。

### [中] BuildKit「rootless 无特权」的描述与实测 privileged: true 不符，且三处参数各写一套
- 位置: docs/10-cicd-delivery/assets/tekton/06-buildkit.yaml:71-82（README.md:198-202）
- 原文: 「image: 192.168.67.202:8443/compassio/buildkit:v0.20.2-rootless … securityContext: seccompProfile: type: Unconfined / runAsGroup: 1000 / runAsNonRoot: true」（清单中**没有** privileged）
- 问题: 实测 buildkitd 容器 `securityContext = {"privileged": true, "runAsGroup": 1000, "seccompProfile":{"type":"Unconfined"}}`。也就是说线上是特权 Pod，「rootless」只体现在镜像 tag 上；把 06-buildkit.yaml 原样 apply 回去得不到同样状态（缺 privileged，rootlesskit 起不来）。同时参数三处不一致：max-parallelism 清单 4 / 实测 2；内存 limit 清单 4Gi / notes/openwebui-ops-runbook.md:1075 写「4 CPU / 8 GiB」/ 实测 4 CPU、4Gi。
- 证据/正确说法: `kubectl -n cicd get deploy buildkitd -o jsonpath='{.spec.template.spec.containers[0].securityContext}'` 与 `get cm buildkitd-config`（实测：`max-parallelism = 2`，`gcpolicy keepBytes 8GB`）。安全结论「rootless 因此不需要特权」在该集群不成立，应改为「镜像为 rootless 变体，但 Pod 以 privileged 运行」。

### [中] 运维手册仍以已删除的 `cicd-cleanup` CronJob 和 Tekton v1.6.0 为现役
- 位置: docs/10-cicd-delivery/notes/ci-cd-operations-manual.md:144,163（同 docs/10-cicd-delivery/notes/ci-cd-pipeline-end-to-end.md:805）
- 原文: 「`cicd/cicd-cleanup` CronJob 每天 03:00 删除 **7 天前已结束**的 run」「该 Tekton 版本（v1.6.0）不支持 `spec.ttlSecondsAfterFinished`，所以用 CronJob 实现。」
- 问题: 2026-11-07 迁到 Operator 后旧 CronJob 已删除，`cicd` 命名空间实测**没有任何 CronJob**，当前保留策略是 `TektonConfig.spec.tektonpruner`（ttl 2592000 / 成功 200 / 失败 100，job-based pruner 已 disabled），Pipelines 为 v1.15.5。手册里的 `kubectl get cronjob cicd-cleanup`、`kubectl create job --from=cronjob/cicd-cleanup`、`kubectl label pipelinerun cleanup=keep` 全都会 NotFound 或不做任何事。
- 证据/正确说法: `kubectl -n cicd get cronjob` → `No resources found`；`kubectl get tektonconfig config -o jsonpath='{.spec.tektonpruner}'` → `ttlSecondsAfterFinished:2592000, successfulHistoryLimit:200, failedHistoryLimit:100`；controller 镜像 `…/pipeline:v1.15.5`。运维手册属于「照着做」的文档，这一条会直接让人在故障时执行失效命令。

### [中] BuildKit 排障文档标为「已落地修复」的 YAML 仍是 root 客户端，与同一文档的结论冲突
- 位置: docs/10-cicd-delivery/notes/buildkit-troubleshooting.md:96,98
- 原文: 「- { name: DOCKER_CONFIG,  value: /root/.docker }」「securityContext: { runAsUser: 0 }」
- 问题: 同一文档 :236 写「去掉 `securityContext.runAsUser: 0`」、:248 表格写「非 root 客户端…Task pod 无 runAsUser: 0」，ci-cd-architecture-and-gitops.md:119 与 ci-cd-operations-manual.md:136 也都写「已非 root、`DOCKER_CONFIG=/home/user/.docker`」。仓库真实 Task（assets/tekton/01-tasks.yaml:116-122）确实用 `/home/user/.docker` 且无 runAsUser。§五 这段被标为「修复（已落地）」的代码是旧版本，照抄会以 root 构建并覆盖凭据路径，正好违背该文自己的安全结论。
- 证据/正确说法: docs/10-cicd-delivery/assets/tekton/01-tasks.yaml:116-122（`DOCKER_CONFIG=/home/user/.docker`，无 securityContext）。

### [中] 「GitLab 是 OIDC/SAML 的 SP」是概念错误
- 位置: docs/13-sso-oidc/README.md:392（同错 docs/13-sso-oidc/notes/03-phase2-argocd-harbor-ceph.md:368-369、docs/13-sso-oidc/notes/04-keycloak-basicauth-forwardauth.md:60）
- 原文: 「GitLab 是 OIDC/SAML 的 **SP**，不是 SAML IdP」
- 问题: 在 OIDC 里 GitLab 是 **OP / Authorization Server**（本仓库 README.md:60、notes/02:46 的表格就是这样写的），SP 是 Grafana/ArgoCD/Harbor/oauth2-proxy；只有 SAML 场景 GitLab 才是 SP。写成「OIDC 的 SP」会让读者以为接 OIDC 还得另找 IdP，而这套平台恰恰是拿 GitLab 当 OIDC IdP 用的。
- 证据/正确说法: 同文档 README.md:60「Authorization Server | GitLab」；GitLab 官方文档 "GitLab as an OAuth2/OIDC provider"（`/oauth/authorize`、`/.well-known/openid-configuration` 即 OP 端点，本文 :66 自证）。

### [中] cookie secret 长度单位写错，且与「这条命令会报错」自相矛盾
- 位置: docs/13-sso-oidc/README.md:164 与 :501-513（同 docs/13-sso-oidc/notes/02-sso-ops-tutorial.md:254）
- 原文: 「cookie secret 必须是 **16/24/32 字节**，本平台统一用 `openssl rand -hex 16`（32 字符）」/「`openssl rand -hex 16`    # 32 个字符，对应 16 字节」/「报错：`cookie_secret must be 16, 24, or 32 bytes`」
- 问题: `-hex 16` 输出 16 字节的随机数，编码成 32 个十六进制字符，存进 Secret 的字符串长度是 **32 字节**，正好命中 oauth2-proxy 的 32 字节要求，不会报错；「32 个字符对应 16 字节」是把字符数当字节数。真要 16 字节得 `openssl rand -hex 8`（或 `-hex 16` 就明确写「32 字节，合法」）。同一篇文档一处说「统一用该命令」，一处说「该命令报错」，读者无法判断哪个成立。
- 证据/正确说法: oauth2-proxy 校验的是 cookie secret 字符串的**字节长度** ∈ {16,24,32}；32 个 ASCII 字符 = 32 字节 → 合法。

### [中] Runner/helper 镜像停在 v17.8.3，与 GitLab 19.5.0 跨两个大版本
- 位置: docs/03-gitlab/cicd-gitops.md:39；docs/03-gitlab/assets/gitlab-runner-config.yaml:14；docs/10-cicd-delivery/notes/openwebui-cicd-gitops.md:204-205
- 原文: 「Helper image | `192.168.67.202:8443/openwebui/gitlab-runner-helper:x86_64-v17.8.3`」
- 问题: GitLab 的兼容策略是 Runner 与 GitLab 同版本、最多落后 3 个 minor；v17.8 对 19.5 落后两个 major，属不受支持组合（新版服务端新增的 job payload/协议特性、`glrt-` token 行为都可能不匹配）。文档把 v17.8.3 当现役配置写进「实际值」表，且在同一分类里专门讲了「GitLab 19 用 glrt token」，却没提 runner 需要跟着升。
- 证据/正确说法: 实测 Deployment 镜像即 `openwebui/gitlab-runner:alpine-v17.8.3`；GitLab Runner 官方 "Runner version compatibility"（同 major，落后不超过 3 个 minor）。

### [低] 多平台构建示例超出本环境 builder 的能力
- 位置: docs/10-cicd-delivery/10-pipeline-release-artifacts.md:189-195
- 原文: 「docker buildx build --platform linux/amd64,linux/arm64 --cache-from type=registry,ref=$REG/cache:web …」
- 问题: 同文档 :159 引用的 `docker buildx inspect` 输出里 Platforms 只有 `linux/amd64, linux/amd64/v2, linux/amd64/v3, linux/386`，既没有 arm64 也没有 binfmt/qemu。照抄这条命令会在 arm64 阶段失败（`no match for platform in manifest`），而文中没有任何「需要先注册 qemu 或加 arm64 节点」的前置说明。
- 证据/正确说法: 同文档引用的 evidence/buildx-remote.txt 平台列表；在纯 amd64 builder 上构建 arm64 需要 `tonistiigi/binfmt` 或原生 arm64 节点。

### [低] Grafana 管理员组映射两处不一致，且都是「当前配置」
- 位置: docs/13-sso-oidc/README.md:273 vs docs/13-sso-oidc/notes/05-grafana-sso.md:154
- 原文: 「`contains(['root'], nickname) && 'GrafanaAdmin' || contains(groups[*], 'digitalsupply') && 'GrafanaAdmin' || 'Viewer'`」 vs 「`contains(groups[*], 'digitalsupply/devops') && 'GrafanaAdmin' || 'Viewer'`」
- 问题: 一个按顶层组 `digitalsupply` 提升管理员，一个按子组 `digitalsupply/devops`，授权范围差一个量级（前者等于整个 GitLab 组的成员都是 Grafana 超级管理员）。GitLab 的 `groups` claim 返回组的完整路径，两条表达式不会同时命中，读者无法判断线上到底哪个生效。
- 证据/正确说法: 两份文档都以「实际配置」口吻给出；应以集群里 `platform/monitoring/values.yaml` 与 Grafana ConfigMap 渲染结果为准，并统一为最小授权的那条（子组）。

### [低] oauth2-proxy 的接入模式在 README 与 notes/资产注释里相反
- 位置: docs/13-sso-oidc/README.md:148-155 vs docs/13-sso-oidc/notes/04-keycloak-basicauth-forwardauth.md:187-190；docs/13-sso-oidc/assets/oauth2-proxy/values.yaml:1
- 原文: 「本平台最初试了 ForwardAuth，但 oauth2-proxy 未登录时返回 401 + Location … 最终改成**反向代理**」；values.yaml 首行仍是「# oauth2-proxy for Traefik ForwardAuth」
- 问题: README 已记录 ForwardAuth 方案被放弃（401 不自动跳转），但概念文档 notes/04 与资产注释仍把方案描述成「把 OIDC 登录翻译成 Traefik 的 ForwardAuth 检查」。实际部署（deployment.yaml 有 `--upstream` + `--reverse-proxy=true`）确实是反向代理。注释/概念文与实现不一致，会让后来者按 ForwardAuth 去排查 `/oauth2/auth` 的 401。
- 证据/正确说法: docs/13-sso-oidc/assets/oauth2-proxy/deployment.yaml:45,49（`--reverse-proxy=true`、`--upstream=…`）；反向代理模式下不存在 Traefik ForwardAuth middleware。

### [低] Kaniko 上游已归档，仍被当作「应急回滚路径」且未标注 EOL
- 位置: docs/10-cicd-delivery/notes/ci-cd-architecture-and-gitops.md:99,166；docs/10-cicd-delivery/notes/ci-cd-operations-manual.md:140
- 原文: 「构建备选 | Kaniko | `v1.23.2` | `cicd/99-kaniko-tasks.yaml.bak` | 应急回滚路径」
- 问题: `GoogleContainerTools/kaniko` 已于 2025-06-03 被作者归档为只读（维护由 Chainguard fork 接手），v1.23.2 属归档前最后一批发布。把「回滚到 Kaniko」写成首选应急路径，等于故障时退回一个不再出安全修复、且参数是 `--skip-tls-verify --insecure-pull` 的构建器，文档没有一句 EOL 提示。
- 证据/正确说法: GitHub 仓库页标注「This repository was archived by the owner on Jun 3, 2025」；Chainguard 已 fork 接手。建议回滚路径改为「固定 digest 的 BuildKit daemon」或注明 Kaniko EOL 与 fork 名称。

### [低] Harbor OIDC 配置清单漏了 `primary_auth_mode`，导致「本地 admin 仍可登录」缺少依据
- 位置: docs/03-gitlab/harbor-accounts-registry.md:61-72
- 原文: 「| `auth_mode` | `oidc_auth` |」（表格中无 `primary_auth_mode`）
- 问题: 实测 `/api/v2.0/systeminfo` 除 `auth_mode=oidc_auth` 外还返回 `primary_auth_mode: false`、`self_registration: false`。Harbor 2.x 用 `primary_auth_mode` 决定登录页默认走哪套认证；文档在 13-sso-oidc/README.md:333 断言「Harbor 明确允许本地 admin 在 OIDC 模式下继续登录」，其前提正是 `primary_auth_mode=false` + 本地 admin 账号存在，但配置表里没有这一项，读者无法复现「break-glass 还在」。
- 证据/正确说法: 实测 `curl -sk https://192.168.67.202:8443/api/v2.0/systeminfo` → `{"auth_mode":"oidc_auth","oidc_provider_name":"GitLab","primary_auth_mode":false,"self_registration":false}`；另 192.168.67.202:8080 实测 308 跳 8443（「8080 只做跳转」成立）。

### [低] webhook 表把 HTTP 目标的「SSL 校验」写成「默认（开启）」
- 位置: docs/03-gitlab/tokens-webhooks.md:92-96
- 原文: 「| `digitalsupply/ChinaStudyFree` | `http://10.0.0.252/china-study-free-hook` | push | 有 | 默认 |」
- 问题: 目标是明文 `http://`，`enable_ssl_verification` 对它完全不适用；写成「默认（=开启）」会让读者以为这条 hook 有 TLS 校验。真正该暴露的风险是：这条链路上 **webhook secret 以明文 `X-Gitlab-Token` 传输**，而文档「坑 4：SSL 校验关闭」只讨论了自签证书场景，没有指出明文 HTTP 下 token 可被嗅探（同一网段即可伪造 push 触发构建）。
- 证据/正确说法: GitLab 文档：`enable_ssl_verification` 仅作用于 HTTPS 目标；对 HTTP 目标该列应写「不适用」，并补一句「内网明文 hook 的 secret 需按可泄露处理」。

### [低] SSO 脚本的用法示例指向一个不存在的文件名
- 位置: docs/13-sso-oidc/scripts/gitlab-create-oauth-app.sh:8
- 原文: 「#   ./scripts/gitlab-create-grafana-oauth-app.sh」
- 问题: 实际文件名是 `gitlab-create-oauth-app.sh`，头注释给的调用路径不存在；脚本正文又用 `APP_NAME/SEALED_OUT` 支持任意应用，与「只创建 Grafana」的注释不符。照文档执行会直接 `No such file or directory`。
- 证据/正确说法: 目录列表只有 `scripts/gitlab-create-oauth-app.sh`；用法行应改为 `./scripts/gitlab-create-oauth-app.sh`，并把注释里的 Grafana 专用描述改成「默认 APP_NAME=grafana」。

---

## 复核说明（未构成发现的核对项）

- Tekton `PipelineRun.spec.ttlSecondsAfterFinished` 不存在的说法正确（`kubectl explain` 无该字段），Operator Pruner 版本矩阵（Pipelines v1.15.5 / Triggers v0.37.2 / Dashboard v0.71.0 / Pruner v0.4.4 / Operator v0.81.3）与实测一致。
- EventListener 的 GitLab interceptor 写法正确：`secretRef{secretName, secretKey}` + `eventTypes: ["Push Hook"]`，与集群里 `compassio-listener` 实测 spec 完全一致；「interceptor 拦截失败仍返回 202」也正确。
- Runner 注册方式正确：用 `POST /api/v4/user/runners` 取 `glrt-` token，没有继续教 registration token。
- Harbor 公开项目「可被匿名拉取」成立（`/api/v2.0/projects` 匿名返回 200，`library`/`deeptutor` 的 `metadata.public=true`，匿名 token 端点会签发 pull token）；`/v2/` 返回 401 只是 registry 的常规 auth challenge，不是匿名被拒。
- Ceph「Quincy/Reef 只提供 SAML 2.0」与 docs.ceph.com 一致（Quincy 文档已含 `ceph dashboard sso setup saml2`），错的是版本号而非协议结论。
