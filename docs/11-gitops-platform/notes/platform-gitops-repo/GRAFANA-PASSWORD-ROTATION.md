# Grafana admin 密码轮换手册

> 适用对象：`monitoring/prometheus-grafana`（Grafana 12.4.3，kube-prometheus-stack 83.7.0）
> Secret 方案：Sealed Secrets v0.41.2，controller 位于 `kube-system/sealed-secrets-controller`
> 最后更新：2026-11-10

## 0. 先理解：密码存在两个地方

| 位置 | 作用 | 修改方式 |
|---|---|---|
| Secret `monitoring/prometheus-grafana-admin`（由 SealedSecret 生成） | 注入 `GF_SECURITY_ADMIN_USER` / `GF_SECURITY_ADMIN_PASSWORD`，用于**首次初始化**和应急重置 | 修改 Git 里的 SealedSecret |
| Grafana 数据库 `grafana.db` 的 `user` 表 | 运行时真正校验的密码哈希 | `grafana cli admin reset-admin-password` |

**关键结论：只改 Secret 不会改变已存在 admin 账号的登录密码。**
Grafana 只在首次初始化时用环境变量创建 admin，之后以数据库里的哈希为准。
因此一次完整轮换必须同时做“改 Secret”和“改数据库”两步。

当前 Secret 结构：

```text
monitoring/prometheus-grafana-admin
├── admin-user       (admin)
├── admin-password   (运行时密码)
└── ldap-toml        (LDAP 配置，当前为空)
```

引用关系：

- Helm values `grafana.admin.existingSecret: prometheus-grafana-admin`
- Grafana Operator 的 external `Grafana` CR 也引用同一个 Secret（用于 Datasource/Dashboard 调 API）

## 1. 前置检查

```bash
# SealedSecret 与 Secret 都在
kubectl -n monitoring get sealedsecret,secret prometheus-grafana-admin

# Secret 确实由 SealedSecret 控制器管理
kubectl -n monitoring get secret prometheus-grafana-admin \
  -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
# 期望输出：SealedSecret

# ArgoCD App 正常
kubectl -n argocd get application platform-monitoring-stack

# 本地 kubeseal 可用，且能连到控制器
kubeseal --version
```

如果 `kubeseal` 提示无法获取证书，先确认控制器：

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=sealed-secrets
```

## 2. 生成新密码

使用十六进制，避免 `!`、`$`、`/` 等字符在 shell / YAML / URL 中被转义：

```bash
NEW_PASSWORD="$(openssl rand -hex 16)"
echo "$NEW_PASSWORD"
```

> 建议同时记录到团队密码库（Vault / 1Password / 纸质封存），不要只留在终端历史里。

## 3. 重新生成 SealedSecret

推荐用 `--merge-into`，它会原地更新密文，同时保留文件里已有的 `sync-wave` 注解和 `template` 标签：

```bash
cd /path/to/platform-gitops

kubectl -n monitoring create secret generic prometheus-grafana-admin \
    --dry-run=client -o yaml \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$NEW_PASSWORD" \
    --from-literal=ldap-toml='' \
| kubeseal \
    --merge-into platform/monitoring/stack/sealedsecret-grafana-admin.yaml \
    --controller-name sealed-secrets-controller \
    --controller-namespace kube-system
```

如果文件被误删，可以用下面的命令从零生成（会丢失原有的注解/标签，需要手工补回）：

```bash
kubectl -n monitoring create secret generic prometheus-grafana-admin \
    --dry-run=client -o yaml \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$NEW_PASSWORD" \
    --from-literal=ldap-toml='' \
| kubeseal \
    --namespace monitoring \
    --name prometheus-grafana-admin \
    --controller-name sealed-secrets-controller \
    --controller-namespace kube-system \
    --format yaml \
> platform/monitoring/stack/sealedsecret-grafana-admin.yaml
```

检查 diff，确认只有 `admin-password` 的密文变化：

```bash
git diff -- platform/monitoring/stack/sealedsecret-grafana-admin.yaml
```

## 4. 提交并让 ArgoCD 同步

```bash
git add platform/monitoring/stack/sealedsecret-grafana-admin.yaml
git commit -m "chore(monitoring): rotate grafana admin password"
git push
```

ArgoCD 会自动同步 `platform-monitoring-stack`（`selfHeal: true`）。也可以手动触发：

```bash
kubectl -n argocd annotate application platform-monitoring-stack \
  argocd.argoproj.io/refresh=normal --overwrite
kubectl -n argocd get application platform-monitoring-stack -w
```

确认 Secret 已更新（注意 `resourceVersion` 变化）：

```bash
kubectl -n monitoring get secret prometheus-grafana-admin \
  -o jsonpath='{.metadata.resourceVersion}{"\n"}'
kubectl -n monitoring get secret prometheus-grafana-admin \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

此时 Pod 里的环境变量可能还是旧值（env 不会热更新）。如果只是轮换登录密码，不需要重启；
如果还要让新 Pod 使用新 env，执行：

```bash
kubectl -n monitoring rollout restart deploy/prometheus-grafana
kubectl -n monitoring rollout status deploy/prometheus-grafana
```

> 注意：Grafana 使用 `Recreate` 策略，重启会有一个短暂中断（RWO PVC 不能双挂）。

## 5. 同步数据库里的密码（必做）

Grafana 12 支持从 stdin 读密码，避免密码进入 shell history 和进程列表：

```bash
printf '%s' "$NEW_PASSWORD" | kubectl -n monitoring exec -i \
  deploy/prometheus-grafana -c grafana -- \
  grafana cli admin reset-admin-password --password-from-stdin
```

如果该版本不支持 `--password-from-stdin`，退化为：

```bash
kubectl -n monitoring exec -it deploy/prometheus-grafana -c grafana -- \
  grafana cli admin reset-admin-password "$NEW_PASSWORD"
```

> 这一步只改数据库，不会改 Secret。两步都做才算闭环。

## 6. 验证

在 Pod 内直接调 API：

```bash
kubectl -n monitoring exec deploy/prometheus-grafana -c grafana -- \
  sh -c 'curl -s -o /dev/null -w "%{http_code}\n" \
    -u "admin:NEW_PASSWORD_HERE" http://127.0.0.1:3000/api/user'
```

期望 `200`。再用浏览器登录 `https://grafana.k8s.local/login` 确认。

同时确认 Grafana Operator 的 external 连接没有报错：

```bash
kubectl -n grafana-operator logs deploy/grafana-operator --tail=50 | grep -i -E "auth|401|403"
```

## 7. 回滚

密码轮换没有“自动回滚”。若新密码不可用：

```bash
# 方案 1：用上一个密码重新 reset
kubectl -n monitoring exec -it deploy/prometheus-grafana -c grafana -- \
  grafana cli admin reset-admin-password '<旧密码>'

# 方案 2：从 Git 回到上一个 SealedSecret 版本，推送后再 reset
git revert <commit>
git push
```

数据库里的密码以最后一次 `reset-admin-password` 为准，回滚 Secret 不会自动回滚数据库。

## 8. 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `kubeseal` 报 `no key could decrypt secret` | 控制器证书不匹配（换了集群 / 私钥丢失） | 确认 `kubeseal --fetch-cert` 能取到证书；私钥备份见 `platform/secrets/README.md` |
| 改了 Secret，登录还是旧密码 | 没做第 5 步 | 执行 `grafana cli admin reset-admin-password` |
| ArgoCD 一直 OutOfSync | 有人直接 `kubectl apply` 过 SealedSecret | 以 Git 为准，`kubectl -n argocd app sync platform-monitoring-stack` |
| 新 Pod 起不来 / 迁移失败 | 两个 Pod 同时挂 RWO PVC | 确认 `deploymentStrategy: Recreate`，先删旧 Pod |
| 忘记密码且 Pod 起不来 | 无法 exec | 查看 PVC 里的 `grafana.db`，挂到临时 Pod 用 `grafana cli` 处理 |

## 9. 安全建议

1. `ChangeMe_Prod` 这类默认口令必须尽快替换；
2. 不要让 `admin` 账号日常使用，接入 SSO 后把个人账号设为 `Admin`，`admin` 仅作 break-glass；
3. 轮换后检查外部系统是否引用了旧密码（n8n、告警链接、脚本、CI 变量）；
4. Sealed Secrets 私钥必须离线备份，否则集群重建后所有 SealedSecret 都无法解密；
5. 更长期的方案是接入 Keycloak/GitLab OIDC，见 `GRAFANA-SSO.md`。
6. 2026-11-10 已启用 GitLab OIDC；本地 `admin` 仅作为 break-glass，
   密码轮换流程不变（仍然要同时改 SealedSecret 和数据库）。
