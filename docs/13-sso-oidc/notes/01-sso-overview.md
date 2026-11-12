# 平台统一认证（SSO）总体方案

> **状态：已作废（Keycloak 时代的 SSO 方案）**
> 这套设计没有落地：平台最终用 **GitLab CE 作为 OIDC IdP**（Grafana/ArgoCD/Harbor 原生 OIDC，
> Traefik/Hubble/Alloy/Tekton 走 oauth2-proxy）。本文里的 `sso.k8s.local`、Keycloak realm、SAML 流程**都不是当前配置**。
> 当前方案见 [13 章 README](../README.md)。



> 目标：让 k8s 周边 Web UI 共用一套身份，减少独立账号和 basicAuth 密码
> 范围：Grafana、ArgoCD、GitLab、Ceph Dashboard、Harbor、Traefik/Hubble/Tekton 等
> 最后更新：2026-11-10

## 1. 先厘清概念

| 名词 | 是什么 | 备注 |
|---|---|---|
| **SSO** | 多个系统信任同一个身份提供方（IdP），登录一次即可访问 | 是一种效果，不是协议 |
| **LDAP** | 目录访问协议，存用户/组/邮箱；AD 本质是 LDAP + Kerberos | 应用可直接 bind LDAP，也可以由 IdP 联邦 |
| **OIDC / OAuth2** | 基于 HTTP 的认证协议，IdP 签发 token，应用读取 `email`/`groups` 等 claim | 新系统首选 |
| **SAML** | 企业常用 SSO 协议，基于 XML 断言 | Grafana OSS 不支持；Ceph Quincy 只支持这个 |
| **ForwardAuth** | 由反向代理把每个请求交给认证代理校验 | 给“本身没有登录体系”的 UI 用 |

**SSO 只统一“认证”，不统一“授权”。** 同一个账号在 Grafana 可以是 Admin，
在 ArgoCD 可以是只读，权限仍由各系统的组/角色映射决定。

## 2. 统一之后是什么体验

```text
访问 grafana.k8s.local
  → 302 到 sso.k8s.local（IdP）
  → 输入一次账号密码 + MFA
  → 回跳 Grafana，进入
再访问 argocd.devops.com
  → 已有 SSO 会话，直接进入
```

## 3. 服务不在 k8s 里能不能接？

**能。** IdP 只关心：

1. 应用是否支持 OIDC / SAML / LDAP；
2. 浏览器和服务端能否访问 IdP；
3. 回调 URI、client secret、组映射是否配对。

应用跑在物理机、VM、其他集群都可以，GitLab 就是现成例子。

## 4. 当前环境评估（2026-11-10 实测）

| UI | 版本 / 状态 | 能否统一登录 | 接入方式 |
|---|---|---|---|
| Grafana | 12.4.3 OSS | ✅ 已接入 | 原生 OIDC（`auth.generic_oauth`） |
| ArgoCD | 3.5.3 | ✅ 已接入 | 原生 OIDC（`argocd-cm`），Helm bootstrap |
| GitLab | 外部 `http://192.168.67.201`，OIDC discovery 可用 | ✅ | 当前作为 IdP；也可作为 Keycloak 的客户端 |
| Ceph Dashboard | 17.2.8 Quincy | ⛔ 阻塞 | Quincy 只有 SAML 2.0；需要 Keycloak 等 SAML IdP |
| Harbor | 2.14.5，`https://192.168.67.202:8443` | ✅ 已接入 | 原生 OIDC，`auth_mode=oidc_auth` |
| Traefik / Hubble / Tekton / Alloy | 无原生登录 | ✅ 已接入 | `oauth2-proxy` 反向代理 + GitLab OIDC |

结论：

- **Grafana、ArgoCD、GitLab、Harbor**：改配置即可；
- **Ceph**：走 SAML，需要 mgr 节点安装 `python3-saml`；
- **Traefik / Hubble / Tekton / Alloy**：已通过 `oauth2-proxy` 反向代理接入 GitLab OIDC，
  旧的 basicAuth 资源保留用于回滚。

## 5. 目标架构

```text
                    ┌── Grafana      (OIDC)
                    ├── ArgoCD       (OIDC)
浏览器 ──> Keycloak ─┼── Harbor       (OIDC)
           (IdP)    ├── GitLab       (OIDC client)
                    ├── Ceph         (SAML)
                    └── Traefik/Hubble/Tekton
                          └── oauth2-proxy ForwardAuth
```

- **根 IdP**：有 AD 就让 Keycloak 联邦 AD；没有就用 Keycloak 本地用户；
- **GitLab 的定位**：短期可以作为 IdP，长期建议由 Keycloak 做根，GitLab 变为客户端，
  否则以后换 IdP 会把 GitLab 变成单点；
- **不支持 OIDC 的 UI**：统一用 `oauth2-proxy` 做 ForwardAuth，而不是继续发 basicAuth 密码。

## 6. 分阶段落地

### 阶段 1：Grafana 接 GitLab OIDC（已完成）

- 零新增组件；
- 在 GitLab 创建 OAuth Application；
- client secret 存 SealedSecret，配置写 `platform/monitoring/values.yaml`；
- ArgoCD 自动同步；
- 保留本地 `admin` 作为 break-glass。

详细步骤见 `platform/monitoring/GRAFANA-SSO.md` 第 3 节。

### 阶段 2：ArgoCD / Harbor 接 GitLab OIDC（已完成）；Ceph 阻塞

- **ArgoCD**：`platform/argocd/values.yaml` + Helm bootstrap，已接入 GitLab OIDC；
- **Harbor**：外部 2.14.5，`auth_mode=oidc_auth`，本地 admin 保留；
- **Ceph**：Quincy 只支持 SAML 2.0，GitLab 不是 SAML IdP，需要 Keycloak；
- 详细过程见 `platform/sso/PHASE2-ARGOCD-HARBOR-CEPH.md`。

### 阶段 3：部署 Keycloak，收编剩余系统（待做）

- CNPG PostgreSQL + Keycloak Deployment + Traefik IngressRoute；
- 联邦 AD/OpenLDAP（如果有）；
- Ceph Dashboard 用 Keycloak SAML client 接入；
- Traefik / Hubble / Tekton / Alloy 用 `oauth2-proxy` 反向代理（已实施）；
- 可选：把 Grafana/ArgoCD/Harbor 逐步迁移到 Keycloak，GitLab 变为客户端。

> 如果暂时不接 Ceph，也可以让 `oauth2-proxy` 直接对接 GitLab OIDC，
> 不引入 Keycloak。两条路线的对比见 `KEYCLOAK-BASICAUTH-EXPLAINED.md`。

## 7. 前提条件与改造建议

1. **统一 DNS**：`sso.k8s.local`、`grafana.k8s.local`、`argocd.devops.com` 必须能被客户端解析；
2. **可信证书**：Traefik 默认自签只能“能用”，ArgoCD 等严格校验 issuer 证书的应用会直接失败，
   建议用 cert-manager 建内部 CA；
3. **GitLab 目前是 HTTP**：OAuth secret 会在内网明文传输，建议加 TLS；
4. **网络策略**：放行 Grafana/ArgoCD → IdP，以及浏览器 → IdP；
5. **Sealed Secrets 私钥离线备份**：丢失后所有 client secret 都无法恢复；
6. **break-glass**：任何阶段都保留本地 admin，防止 IdP 故障导致全部锁死；
7. **不要让 Grafana 同时开 LDAP 和 OIDC**，容易出现同名用户和角色冲突。

## 8. 风险与回滚

| 风险 | 影响 | 回滚 |
|---|---|---|
| OIDC 配置错误 | 登录页报错，但本地 admin 仍可用 | `auth.generic_oauth.enabled=false`，推送 |
| Grafana Pod 重启 | 短暂不可用（RWO PVC，Recreate） | 等待就绪；必要时回滚 values |
| GitLab 不可用 | OIDC 用户无法登录 | 使用本地 admin |
| 组映射错误 | 用户全部 Viewer | 修正 `role_attribute_path` 或手工提权 |
| 证书不受信 | 浏览器告警；后端 token 交换失败 | 内网 token API 走 http，或配置 CA |

## 9. 相关文档

- `platform/monitoring/GRAFANA-SSO.md`：Grafana 三种接入方案的完整命令与清单
- `platform/monitoring/GRAFANA-PASSWORD-ROTATION.md`：admin 密码轮换
- `platform/sso/PHASE2-ARGOCD-HARBOR-CEPH.md`：ArgoCD/Harbor 接入过程与 Ceph 阻塞分析
- `platform/sso/KEYCLOAK-BASICAUTH-EXPLAINED.md`：Keycloak、basicAuth、ForwardAuth 概念与区别
- `platform/sso/SSO-OPS-TUTORIAL.md`：SSO 运维与基础概念完整教程
- `platform/argocd/README.md`：ArgoCD Helm bootstrap 与 OIDC/RBAC
- `platform/secrets/README.md`：Sealed Secrets 约定与私钥备份
- `scripts/gitlab-create-grafana-oauth-app.sh`：创建 GitLab OAuth Application 并生成 SealedSecret

## 10. 执行记录（2026-11-10）

### 阶段 1 已完成：Grafana 接入 GitLab OIDC

#### 10.1 先修复 GitLab 实例

首次尝试 `POST /api/v4/applications` 返回 500，排查发现是 GitLab 自身问题：

| 检查项 | 结果 |
|---|---|
| GitLab 版本 | 19.5.0（CE） |
| 异常 | `PG::UndefinedTable: relation "oauth_application_granular_scopes" does not exist` |
| 未执行迁移 | 196 条 |
| 根分区 | 100% 满（仅剩约 100M） |

处理过程：

1. 清理 `/root/.npm`、`/root/.cache` 等可再生缓存，确认根分区有充足余量；
2. 备份：
   - `1794285804_2026_11_10_19.5.0_gitlab_backup.tar`（725M）
   - `gitlab.rb`、`gitlab-secrets.json` 复制到 `/var/opt/gitlab/backups/`
3. 执行 `gitlab-rake db:migrate`；
4. `gitlab-rake db:migrate:status | grep '  down '` 返回 0 条；
5. 确认 `oauth_application_granular_scopes` 表已存在，GitLab Web/API 正常。

#### 10.2 创建 OAuth Application

```bash
GITLAB_TOKEN=<admin token> \
  ./scripts/gitlab-create-grafana-oauth-app.sh
```

结果：

| 项目 | 值 |
|---|---|
| Application name | `grafana` |
| client_id | `78775c9be6d3f46e0ddc9f2d47cded07deb11e032ff3f1e0cf9af4097e098228` |
| redirect_uri | `https://grafana.k8s.local/login/generic_oauth` |
| scopes | `openid profile email`（**空格分隔，不能写逗号**） |
| client secret | SealedSecret `monitoring/grafana-oauth` |

#### 10.3 纳入 GitOps

| 文件 | 变更 |
|---|---|
| `platform/monitoring/values.yaml` | `envValueFrom` 注入 client secret；`grafana.ini` 开启 `auth.generic_oauth`；本地 admin 保留 |
| `platform/monitoring/stack/sealedsecret-grafana-oauth.yaml` | 新增 SealedSecret |
| `platform/monitoring/stack/kustomization.yaml` | 把新 SealedSecret 加入 `resources` |

ArgoCD `platform-monitoring-stack` 同步结果：`Synced / Healthy`。

验证：

```bash
# 登录页出现 GitLab 按钮
kubectl -n monitoring exec deploy/prometheus-grafana -c grafana -- \
  sh -c 'curl -s http://127.0.0.1:3000/login | grep -o GitLab | head -1'

# GitLab 接受 client_id 与回调地址（302 到登录页）
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  "http://192.168.67.201/oauth/authorize?client_id=78775c9be6d3f46e0ddc9f2d47cded07deb11e032ff3f1e0cf9af4097e098228&redirect_uri=https%3A%2F%2Fgrafana.k8s.local%2Flogin%2Fgeneric_oauth&response_type=code&scope=openid%20profile%20email&state=test"

# 本地 admin 仍可登录（break-glass）
kubectl -n monitoring exec deploy/prometheus-grafana -c grafana -- \
  sh -c 'curl -s -o /dev/null -w "%{http_code}\n" -u admin:<密码> http://127.0.0.1:3000/api/user'
```

#### 10.4 两个必须记住的坑

1. **`kustomization.yaml` 必须显式列出新 SealedSecret**
   ArgoCD 对 `platform/monitoring/stack` 走 Kustomize；只提交 `sealedsecret-*.yaml`
   不加到 `resources`，资源不会下发。本次就因此出现“Deployment 等 Secret、
   Secret 等同步”的死锁。

2. **GitLab OAuth scopes 用空格分隔**
   `scopes=openid profile email` 正确；`openid,profile,email` 会被当作一个 scope，
   报 `scopes doesn't match those configured on the server`。

#### 10.5 遗留事项

- Grafana 当前临时固定在 `worker02`（`nodeSelector`），因为该节点已缓存
  `grafana:12.4.3`，避免在其他节点拉取超时。等所有 worker 都缓存镜像后可移除。
- 还需要用一个真实 GitLab 用户走一遍浏览器登录，确认 `groups` claim 和
  `role_attribute_path` 的角色映射符合预期。
- Ceph 需要 Keycloak 等 SAML IdP；ArgoCD/Harbor 已经用 GitLab OIDC 完成。

#### 10.6 第二阶段（2026-11-10）

| 系统 | 结果 | 关键配置 |
|---|---|---|
| ArgoCD 3.5.3 | ✅ | GitLab OIDC，`platform/argocd/values.yaml`，RBAC admin=digitalsupply/root email |
| Harbor 2.14.5 | ✅ | `auth_mode=oidc_auth`，`oidc_endpoint=http://192.168.67.201`，本地 admin 保留 |
| Ceph 17.2.8 | ⛔ | Quincy 仅 SAML 2.0，GitLab 不是 SAML IdP；需要 Keycloak + `python3-saml` |
| Traefik/Hubble/Tekton/Alloy | ✅ | oauth2-proxy 反向代理 + GitLab OIDC，basicAuth 保留回滚 |

完整过程、验证命令和回滚方式见 `platform/sso/PHASE2-ARGOCD-HARBOR-CEPH.md`。

ArgoCD 首次登录还遇到 `invalid_client` 和 `data length is less than nonce size`，
根因分别是 Secret 缺少 `app.kubernetes.io/part-of: argocd` 标签、以及旧 OIDC
state cookie；修复过程见 `PHASE2-ARGOCD-HARBOR-CEPH.md` 第 2.8 节。

#### 10.7 路线 A：oauth2-proxy 接入 Traefik/Hubble/Tekton/Alloy（2026-11-10）

| 项目 | 内容 |
|---|---|
| 模式 | oauth2-proxy 反向代理（不是 ForwardAuth） |
| 实例 | hubble / alloy / tekton / traefik，各一个 Deployment + Service |
| 认证 | GitLab OIDC，每个 host 独立 OAuth Application |
| cookie | 每个实例独立 32 字节 cookie secret，SealedSecret 管理 |
| 路由 | `*.xyz` 的 IngressRoute 指向对应 oauth2-proxy |
| Traefik | `providers.kubernetesCRD.allowCrossNamespace=true` |
| Traefik API | `--api=true` + `--api.insecure=true`（`traefik-api` 仅 ClusterIP）；`/` 重定向到 `/dashboard/` |
| 回滚 | 旧 basicAuth Middleware/Secret 保留，改回 IngressRoute 即可 |

验证结果：四个 host 均返回 `302` 到 GitLab `/oauth/authorize`。

遗留：需要真实 GitLab 用户走一遍浏览器登录，确认 oauth2-proxy 能正确代理到
Hubble / Alloy / Tekton / Traefik 后端。

完整运维手册见 `platform/sso/SSO-OPS-TUTORIAL.md`。
