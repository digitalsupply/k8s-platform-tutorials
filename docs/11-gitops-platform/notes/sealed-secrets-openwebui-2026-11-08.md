# P0-6 Secret 管理闭环：Sealed Secrets + open-webui 迁移

> 执行日期：2026-11-08
> 范围：安装 Sealed Secrets Controller，迁移 open-webui 的 3 个明文 Secret，验证业务无数据差异
> 结果：**3 个 SealedSecret 全部 Synced，控制器创建的 Secret 数据哈希与迁移前完全一致**

---

## 0. 最终结果

| 项目 | 结果 |
|---|---|
| Sealed Secrets Controller | **v0.41.2**，`kube-system`，1/1 Running |
| `platform-sealed-secrets` App | `Synced / Healthy` |
| open-webui SealedSecret | **3 个**（`frp-token`、`harbor-pull`、`open-webui-config`） |
| 控制器创建的 Secret | **3 个**，ownerReference 指向对应 SealedSecret |
| 数据一致性 | 3 个 Secret 的 data 哈希与迁移前**完全一致** |
| `open-webui` App | `Synced / Healthy` |
| 仓库 HEAD 明文 Secret | **0 个** |
| Sealed Secrets 私钥备份 | `/root/k8s-postmortem/backup/sealed-secrets-key.yaml` |

---

## 1. 架构与流程

```text
Git (openwebui-gitops)
└── base/sealed-secrets.yaml   ← SealedSecret（加密后）
        │
        ▼
ArgoCD (open-webui app)
        │ apply
        ▼
SealedSecret CR
        │ 控制器用私钥解密
        ▼
Secret（open-webui namespace）
        │
        ├── harbor-pull         → ServiceAccount.open-webui.imagePullSecrets
        └── open-webui-config   → Deployment.open-webui.envFrom
```

- 私钥只在 `kube-system` 的 `sealed-secrets-key*` Secret 中；
- Git 里只有加密后的 `encryptedData`；
- 控制器负责创建/更新同名 Secret。

---

## 2. 安装 Sealed Secrets Controller（GitOps）

### 2.1 下载官方 controller manifest

```bash
curl -sSL -o sealed-secrets-controller.yaml \
  https://github.com/bitnami/sealed-secrets/releases/download/v0.41.2/controller.yaml
```

包含：

- CRD `sealedsecrets.bitnami.com`
- Deployment `sealed-secrets-controller`（`docker.io/bitnami/sealed-secrets-controller:0.41.2`）
- Service `sealed-secrets-controller` / `sealed-secrets-controller-metrics`
- RBAC

### 2.2 提交到 platform-gitops

```text
platform/secrets/sealed-secrets/controller.yaml
```

ArgoCD Application `platform-sealed-secrets`：

- wave `-20`
- destination `kube-system`
- `prune=false`
- `ServerSideApply=true`

验证：

```text
platform-sealed-secrets  Synced  Healthy
sealed-secrets-controller-...  1/1 Running
CRD sealedsecrets.bitnami.com  ESTABLISHED=True
```

---

## 3. 安装 kubeseal 并获取公钥

```bash
curl -sSL -o kubeseal.tgz \
  https://github.com/bitnami/sealed-secrets/releases/download/v0.41.2/kubeseal-0.41.2-linux-amd64.tar.gz
tar -xzf kubeseal.tgz -C /tmp
mv /tmp/kubeseal /usr/local/bin/kubeseal
chmod +x /usr/local/bin/kubeseal

kubeseal --fetch-cert \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  > /tmp/sealed-secrets-pub.pem
```

---

## 4. 迁移 open-webui 的 3 个 Secret

### 4.1 迁移前记录数据哈希

```bash
for s in harbor-pull frp-token open-webui-config; do
  kubectl -n open-webui get secret $s -o jsonpath='{.data}' | sha256sum
done
```

记录结果（用于迁移后比对）：

```text
harbor-pull       9529811cd8d25034f4dded7f01531ff04ac4641d9e300ff165b9cb83076c5b6d
frp-token         927d5840c7df936d62b336470bd265fec32770ae276bc9e32a935cacfc7359d8
open-webui-config c5494f6ece7afeae5b9dc12b57fa090270f46e6084c5a425a40287f1d1b650f5
```

### 4.2 密封

```bash
for s in harbor-pull frp-token open-webui-config; do
  kubectl -n open-webui get secret $s -o yaml \
    | kubeseal --format yaml --cert /tmp/sealed-secrets-pub.pem \
    > /tmp/$s.sealed.yaml
done
```

输出结构：

| SealedSecret | encryptedData key | template.type |
|---|---|---|
| `harbor-pull` | `.dockerconfigjson` | `kubernetes.io/dockerconfigjson` |
| `frp-token` | `token` | `Opaque` |
| `open-webui-config` | `WEBUI_SECRET_KEY` | `Opaque` |

### 4.3 清理模板中的 ArgoCD tracking 注解

`kubeseal` 会把原 Secret 的 `argocd.argoproj.io/tracking-id` 复制到 `spec.template.metadata.annotations`。这会让控制器创建的 Secret 被误认为 ArgoCD 跟踪资源，因此需要清理：

```python
ann.pop('argocd.argoproj.io/tracking-id', None)
labs.pop('app.kubernetes.io/managed-by', None)
```

清理后，`SealedSecret` 本身仍由 ArgoCD 跟踪，但控制器创建的 Secret 不带 tracking 注解。

### 4.4 修改 openwebui 仓库

删除明文 Secret：

- `base/00-namespace-and-secrets.yaml` → 删除 `Secret/harbor-pull`
- `base/frpc.yaml` → 删除 `Secret/frp-token`
- `base/10-open-webui.yaml` → 删除 `Secret/open-webui-config`

新增：

```text
base/sealed-secrets.yaml    # 3 个 SealedSecret
```

并在 `base/kustomization.yaml` 的 `resources` 中加入：

```yaml
  - sealed-secrets.yaml
```

校验：

```bash
kubectl kustomize overlays/prod > /tmp/openwebui-rendered.yaml
grep -E '^kind: (Secret|SealedSecret)' /tmp/openwebui-rendered.yaml
# 只应有 3 个 SealedSecret
```

### 4.5 提交并同步

```bash
git add base/
git commit -m "feat(secrets): migrate open-webui secrets to sealed-secrets"
git push origin main

kubectl -n argocd annotate application open-webui \
  argocd.argoproj.io/refresh=normal --overwrite
```

结果：

```text
open-webui  Synced  Healthy
```

---

## 5. 验证

### 5.1 SealedSecret 状态

```text
NAME                STATUS
frp-token           True
harbor-pull         True
open-webui-config   True
```

### 5.2 控制器创建的 Secret

```text
harbor-pull        owner=SealedSecret/harbor-pull
frp-token          owner=SealedSecret/frp-token
open-webui-config  owner=SealedSecret/open-webui-config
```

### 5.3 数据一致性

迁移后重新计算 data 哈希：

```text
harbor-pull       9529811cd8d25034f4dded7f01531ff04ac4641d9e300ff165b9cb83076c5b6d
frp-token         927d5840c7df936d62b336470bd265fec32770ae276bc9e32a935cacfc7359d8
open-webui-config c5494f6ece7afeae5b9dc12b57fa090270f46e6084c5a425a40287f1d1b650f5
```

**与迁移前完全一致。**

### 5.4 ArgoCD 资源归属

`open-webui` App 的 `status.resources` 中：

```text
SealedSecret frp-token          Synced
SealedSecret harbor-pull        Synced
SealedSecret open-webui-config  Synced
```

不再出现明文 `Secret`。

### 5.5 仓库 HEAD

```bash
git grep -n 'kind: Secret' HEAD -- base/
# none
```

---

## 6. 关键备份

| 文件 | 说明 |
|---|---|
| `/root/k8s-postmortem/backup/sealed-secrets-key.yaml` | **控制器私钥，必须妥善保存**；丢失后所有 SealedSecret 无法解密 |
| `/root/k8s-postmortem/backup/sealed-secrets-pub.pem` | 公钥证书，非敏感 |
| `/root/k8s-postmortem/backup/grafana.db` | 之前的 Grafana DB 备份（与本任务无关） |

> 建议把 `sealed-secrets-key.yaml` 放进 Vault/离线保险库，并限制访问。

---

## 7. 本次发现的其他风险（未在本闭环内修复）

### 7.1 `frpc-config` 里仍有明文 FRP token

`base/frpc.yaml` 的 `ConfigMap/frpc-config` 中：

```toml
auth.token = "<明文 token>"
```

这个 token 与 `frp-token` Secret 的值相同，仍在 Git 里明文保存。

建议修复：

```toml
auth.token = "{{ .Envs.FRP_TOKEN }}"
```

并在 `frpc` Deployment 中注入：

```yaml
env:
  - name: FRP_TOKEN
    valueFrom:
      secretKeyRef:
        name: frp-token
        key: token
```

由于当前 `frpc` 被 overlay 缩容到 0，修改后需要在恢复副本时验证 frpc 能正常连接。

### 7.2 `harbor-pull` 使用的是 Harbor admin 账号

`harbor-pull` 的 dockerconfigjson 里是 `admin` 用户。建议：

- 在 Harbor 创建 **robot account**，只授予 pull 权限；
- 用 robot account 重新生成 `harbor-pull` SealedSecret；
- 轮换 Harbor admin 密码。

### 7.3 Git 历史中仍有明文

虽然 HEAD 已经干净，但历史提交里仍有明文 Secret。处理方式二选一：

- **轮换所有相关凭据**（推荐，简单可靠）；
- 使用 `git filter-repo` 重写历史并 force-push（需协调 CI 和所有协作者）。

建议至少轮换：

- Harbor admin / robot token
- FRP token
- `WEBUI_SECRET_KEY`
- GitLab token（`gitlab-auth`，下一步迁移）

---

## 8. 回滚

### 8.1 回滚 open-webui 的 SealedSecret 迁移

```bash
# 在 openwebui-gitops 仓库
git revert <commit>
git push origin main
```

或手工恢复 3 个明文 Secret（不推荐，会重新引入明文）。

### 8.2 回滚 Sealed Secrets Controller

```bash
# 先暂停 auto-sync
kubectl -n argocd patch application platform-sealed-secrets \
  --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd delete application platform-sealed-secrets
```

> 控制器删除后，已有 Secret 不会被删除；但新的 SealedSecret 无法再解密。

---

## 9. 提交记录

### platform-gitops

```text
0becbbc feat(secrets): install sealed-secrets controller via gitops
```

### openwebui-gitops

```text
0fe3db0 feat(secrets): migrate open-webui secrets to sealed-secrets
```

---

## 10. 下一步（P0-6 剩余）

| 顺序 | Secret | 风险 | 说明 |
|---|---|---|---|
| 1 | `cicd/gitlab-auth` | 中 | 迁移时轮换 GitLab token |
| 2 | `cnpg-system/pg-secret` | 中 | 应用用户密码 |
| 3 | `cnpg-system/pg-superuser-secret` | 高 | 超级用户 |
| 4 | `cnpg-system/pg-backup-s3-creds` | 高 | 影响备份，先验证 S3 |

> 不要迁移 `cnpg-ca-secret`、`cnpg-webhook-cert`，它们是 CNPG Operator 自己管理的。
