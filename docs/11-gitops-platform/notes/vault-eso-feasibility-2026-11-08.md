# Vault + ESO 在本集群的可行性、代价与落地建议

> 集群：kubeadm v1.35.9，6 节点
> 日期：2026-11-08
> 现状：Sealed Secrets v0.41.2 已安装；open-webui 3 个 Secret 已迁移
> 结论：**技术上可行，资源充足；真正的决策点是能否接受 Vault 的 unseal 运维，以及是否真的需要审计/动态凭据。**

---

## 0. 一句话结论

| 问题 | 结论 |
|---|---|
| 集群能跑 Vault + ESO 吗？ | **能**，资源、存储、cert-manager、S3 都具备 |
| 建议现在上吗？ | **看目标**：要审计/need-to-know/动态凭据 → 值得；只要“明文不进 Git” → Sealed Secrets 已够 |
| 最大坑是什么？ | **Unseal**：on-prem 无云 KMS 时，节点重启后需要人工解封 |
| Vault 许可？ | BUSL；介意的话评估 **OpenBao** |
| 推荐路径？ | 先做 Phase 1 POC（3 副本 Raft + ESO + 一个测试 Secret），再迁高价值凭据 |

---

## 1. 集群资源核算

### 1.1 节点容量与已分配 requests

| 节点 | 容量 | 已分配 requests | 余量判断 |
|---|---|---|---|
| worker01 | 6C / 9.7Gi | 1820m / 3794Mi（30% / 38%） | 充足 |
| worker02 | 6C / 9.7Gi | 1340m / 3024Mi（22% / 30%） | 充足 |
| worker03 | 4C / 7.75Gi | 2420m / 4974Mi（60% / 63%） | 约 1.5C / 2.8Gi |
| m01 | 4C / 5.5Gi | 控制面，已有 taint | 不建议跑 Vault |
| master01 | 4C / 5.8Gi | 控制面，已有 taint | 不建议跑 Vault |
| master02 | 4C / 3.8Gi | 控制面，已有 taint | 不建议跑 Vault |

### 1.2 Vault + ESO 资源估算

| 组件 | 副本 | requests | 存储 |
|---|---:|---|---|
| Vault（Raft HA） | 3 | 100m / 256Mi 每个 | 3 × 10Gi `ceph-rbd-sc` |
| ESO controller / webhook / cert-controller | 3 | 合计约 300m / 384Mi | 无 |
| Vault Agent Injector（可选） | 1 | 50m / 64Mi | 无 |
| **合计** | **6–7 Pod** | **约 600m / 1.2Gi** | **30Gi** |

### 1.3 其他前置条件

| 条件 | 现状 |
|---|---|
| 存储 | `ceph-rbd-sc`（Retain），33 个 PVC 在用，可用 |
| TLS | cert-manager 已安装；目前只有 namespace 级 self-signed Issuer，需要为 Vault 新建 Issuer/Certificate |
| 对象存储 | `http://10.0.0.31:7480`，CNPG 备份已验证可用，可做 Raft snapshot |
| 网络 | Calico，可配 NetworkPolicy |
| 监控 | kube-prometheus-stack，可加 ServiceMonitor |

**资源层面没有障碍。**

---

## 2. 推荐拓扑

```text
namespace vault
├── Vault StatefulSet × 3（Raft，反亲和到 worker01/02/03）
├── 3 × 10Gi ceph-rbd PVC
├── cert-manager selfsigned Issuer + Certificate（vault.vault.svc）
├── ServiceMonitor + audit device（stdout → Loki）
└── Raft snapshot CronJob → s3://vault-backups/

namespace external-secrets
├── ESO controller / webhook / cert-controller
└── ClusterSecretStore（Vault provider，Kubernetes auth）
```

设计要点：

- **Raft + 3 副本**，不要用 NFS 存 Raft；
- Vault 和 ESO 分别独立 namespace；
- Vault 只暴露 ClusterIP，不直接对公网；
- TLS 必须开，不要 `tlsDisable=true`；
- Vault 的 Kubernetes auth 绑定 ESO 的 ServiceAccount；
- NetworkPolicy 只允许 ESO 和授权应用访问 8200。

---

## 3. 最大代价：Unseal

Vault 每次 Pod 重启、节点重启、升级后都需要 **unseal**。这是 on-prem 自建 Vault 最大的运维负担。

| 方案 | 可行性 | 说明 |
|---|---|---|
| 手动 3-of-5 密钥 | ✅ 当前可用 | 每次重启人工执行，需要 runbook |
| 云 KMS 自动解封 | ❌ 本集群没有云 KMS | 除非有 AWS/GCP/Azure |
| HSM（PKCS#11） | ⚠️ 取决于硬件 | 有 HSM 才能自动解封 |
| Vault Transit 自动解封 | ⚠️ 需要另一套 Vault | 循环依赖，不推荐 |
| OpenBao + 云 KMS/HSM | ⚠️ 同样依赖外部 KMS | 开源替代，但解封问题一样 |

### 3.1 手动解封 Runbook（示意）

```bash
# 每个 Vault Pod 都需要 unseal
kubectl -n vault exec -it vault-0 -- vault operator unseal
# 输入 3 个不同的 unseal key（3-of-5）

kubectl -n vault exec -it vault-1 -- vault operator unseal
kubectl -n vault exec -it vault-2 -- vault operator unseal

kubectl -n vault exec -it vault-0 -- vault status
```

> unseal key 必须离线保存（纸质/保险柜/HSM），不能放 Git、不能放 K8s Secret、不能只放在某个人电脑上。

### 3.2 结论

**如果无法接受“节点重启后人工 unseal”，不建议在本地集群自建 Vault。** 这种情况更适合：

- 托管 Vault / 云 Secret Manager；
- 或继续用 Sealed Secrets + 严格 RBAC。

---

## 4. Vault vs OpenBao vs Sealed Secrets

| 能力 | Sealed Secrets | Vault + ESO | OpenBao + ESO |
|---|---|---|---|
| 明文不进 Git | ✅ | ✅ | ✅ |
| 自动注入 K8s | ✅ | ✅ | ✅ |
| 细粒度访问控制 | ❌ 靠 K8s RBAC | ✅ Vault policy | ✅ |
| 读取审计 | ❌ 靠 K8s audit | ✅ 原生 | ✅ |
| 动态凭据/租约 | ❌ | ✅ | ✅ |
| 自动轮换 | ❌ | ✅ | ✅ |
| 私钥单点风险 | ✅ 有 | Vault HA/HSM | 同 Vault |
| 运维复杂度 | 低 | 高 | 高 |
| 许可 | Apache-2.0 | BUSL | MPL-2.0 |

**Vault 从 2023 年起是 BUSL 许可**，商业使用要注意；**OpenBao** 是 API 兼容的开源 fork，介意许可时优先评估。

---

## 5. 决策矩阵

| 目标 | 建议 |
|---|---|
| 只是“明文不进 Git” | **Sealed Secrets 已足够**，不要为了 Vault 而 Vault |
| 要“谁能读、何时读、读了什么”的审计 | **Vault + ESO** |
| 要动态数据库凭据/短期租约 | **Vault + ESO**（PostgreSQL secrets engine） |
| 无法接受人工 unseal | 托管 Vault / 云 Secret Manager，或继续 Sealed Secrets |
| 介意 Vault 许可 | **OpenBao + ESO** |
| 团队没有 Vault 运维经验 | 先 POC，或先用 Sealed Secrets + 严格 RBAC |

---

## 6. 分阶段落地

### Phase 1：POC（1–2 天）

1. `vault` namespace 起 3 副本 Raft；
2. cert-manager 签 TLS；
3. 安装 ESO，配置 `ClusterSecretStore` + Kubernetes auth；
4. 在 Vault 写一个测试 secret，用 `ExternalSecret` 同步到测试 namespace；
5. 验证 ESO 能读、Pod 能挂载。

### Phase 2：迁移高价值凭据

优先迁移：

- `cicd/gitlab-auth`（同时轮换 GitLab token）
- `cnpg-system/pg-superuser-secret`
- `cnpg-system/pg-backup-s3-creds`
- `harbor-pull`（改用 Harbor robot account，不要用 admin）

低风险业务配置可以继续留在 Sealed Secrets，**混合模式完全合理**。

### Phase 3：动态凭据（可选）

用 Vault 的 PostgreSQL secrets engine 生成短期 DB 账号；需要和 CNPG 的用户管理协调，建议最后做。

---

## 7. POC 清单（示意，按实际 chart/CRD 版本调整）

### 7.1 Vault Helm values（HA Raft + TLS）

```yaml
global:
  enabled: true
  tlsDisable: false

injector:
  enabled: false   # 用 ESO 就不需要 Agent Injector

server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true
        listener "tcp" {
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_cert_file = "/vault/tls/tls.crt"
          tls_key_file  = "/vault/tls/tls.key"
        }
        storage "raft" {
          path = "/vault/data"
        }
        service_registration "kubernetes" {}

  dataStorage:
    enabled: true
    size: 10Gi
    storageClass: ceph-rbd-sc

  extraVolumes:
    - type: secret
      name: vault-tls
      path: /vault/tls
```

### 7.2 cert-manager Issuer + Certificate

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: vault-selfsigned
  namespace: vault
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vault-tls
  namespace: vault
spec:
  secretName: vault-tls
  issuerRef:
    name: vault-selfsigned
    kind: Issuer
  dnsNames:
    - vault.vault.svc
    - vault.vault.svc.cluster.local
    - vault-0.vault-internal
    - vault-1.vault-internal
    - vault-2.vault-internal
```

### 7.3 ESO 安装

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm upgrade -i external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --set installCRDs=true
```

### 7.4 Vault Kubernetes auth

```bash
kubectl -n vault exec -it vault-0 -- vault auth enable kubernetes

kubectl -n vault exec -it vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc"

kubectl -n vault exec -it vault-0 -- vault policy write eso-read - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
EOF

kubectl -n vault exec -it vault-0 -- vault write auth/kubernetes/role/eso \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=eso-read \
  ttl=1h
```

### 7.5 ClusterSecretStore + ExternalSecret

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: vault
spec:
  provider:
    vault:
      server: https://vault.vault.svc:8200
      path: secret
      version: v2
      caProvider:
        type: Secret
        name: vault-tls
        namespace: vault
        key: ca.crt
      auth:
        kubernetes:
          mountPath: kubernetes
          role: eso
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: gitlab-auth
  namespace: cicd
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault
    kind: ClusterSecretStore
  target:
    name: gitlab-auth
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: cicd/gitlab-auth
        property: username
    - secretKey: password
      remoteRef:
        key: cicd/gitlab-auth
        property: password
```

### 7.6 Raft snapshot 到 S3

```bash
# 在 vault pod 内
vault operator raft snapshot save /tmp/vault.snap
# 用 mc/aws-cli 上传到 s3://vault-backups/
```

建议做成 CronJob，保留 7/30 天，并定期做恢复演练。

---

## 8. 安全加固 Checklist

- [ ] Vault 只开 ClusterIP，不直接暴露公网
- [ ] TLS 必须开启，证书由 cert-manager 管理
- [ ] NetworkPolicy 只允许 ESO 和授权应用访问 8200
- [ ] Vault audit device 开启，日志进 Loki，保留 ≥ 90 天
- [ ] unseal key 离线保存，3-of-5，双人审批
- [ ] 不给所有 SRE `get secrets` 权限
- [ ] 不给所有 SRE Vault root token
- [ ] Vault root token 用完即 revoke
- [ ] 每个应用一个 Vault policy，最小权限
- [ ] 定期轮换：GitLab token、Harbor robot、DB 密码、S3 凭据
- [ ] Raft snapshot 每日备份 + 月度恢复演练
- [ ] 监控 Vault seal 状态、leader、存储、请求错误
- [ ] Vault 升级前先 snapshot，再逐副本升级
- [ ] 评估 OpenBao 许可替代

---

## 9. 成本估算

| 项目 | 估算 |
|---|---|
| Phase 1 POC | 1–2 天 |
| Phase 2 迁移 4–6 个高价值 Secret | 1–2 天 |
| 运维（每月） | 监控、备份、unseal runbook、升级 |
| 资源 | ~600m CPU / ~1.2Gi 内存 / 30Gi 存储 |
| 最大隐性成本 | unseal 运维 + Vault 学习曲线 |

---

## 10. 最终建议

1. **不要为了“用 Vault”而用 Vault。**
   - 如果目标只是“明文不进 Git”，Sealed Secrets 已经够；
   - Vault 的价值在审计、need-to-know、动态凭据、自动轮换。

2. **如果要做，先 Phase 1 POC**：
   - 3 副本 Raft + ESO + 一个测试 Secret；
   - 验证 unseal、TLS、备份、审计、监控；
   - 再决定是否迁移生产凭据。

3. **混合模式是合理的**：
   - 低风险业务配置 → Sealed Secrets；
   - 高价值/需要审计的凭据 → Vault + ESO。

4. **如果无法接受人工 unseal**：
   - 用托管 Vault / 云 Secret Manager；
   - 或继续 Sealed Secrets + 严格 RBAC + 审计。

5. **如果介意 Vault 许可**：
   - 评估 **OpenBao**（API 兼容，MPL-2.0）。

---

## 11. 相关文档

- P0-6 Sealed Secrets 落地：`/root/k8s-postmortem/2026-11-08-sealed-secrets-openwebui.md`
- P0 GitOps 执行日志：`/root/k8s-postmortem/2026-11-08-p0-gitops-execution-log.md`
- 当前 Secret 清单：`/root/gitops-p0/platform/secrets/README.md`
