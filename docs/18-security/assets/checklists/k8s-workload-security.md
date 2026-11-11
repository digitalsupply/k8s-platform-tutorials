# 工作负载安全评审清单

## Pod / 容器

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  runAsGroup: 10001
  fsGroup: 10001
  seccompProfile:
    type: RuntimeDefault
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
    # add: ["NET_BIND_SERVICE"] 仅在确有需要时
```

- [ ] 不使用 `privileged: true`
- [ ] 不使用 `hostNetwork` / `hostPID` / `hostIPC`
- [ ] 不挂载 hostPath（确需时只挂单文件/只读）
- [ ] 设置 `allowPrivilegeEscalation: false`（等价 no_new_privs）
- [ ] 设置 `seccompProfile: RuntimeDefault`
- [ ] 设置 `readOnlyRootFilesystem: true`，需要写的目录挂 emptyDir
- [ ] 不以 root 运行；镜像里创建非 root 用户
- [ ] 不把 Secret 通过 env 明文打印到日志

## Namespace / PSA

- [ ] namespace 打 `pod-security.kubernetes.io/enforce: restricted`
- [ ] 先 `warn`/`audit` 观察，再 `enforce`
- [ ] 例外 namespace（Ceph CSI、MetalLB、etcd-backup）单独评估并记录原因

## 网络

- [ ] 默认 deny ingress/egress
- [ ] 只放行必要 namespace/pod/端口
- [ ] 入口走统一网关，TLS 终止明确
- [ ] 服务间需要零信任时启用 mTLS（Cilium/Service Mesh/SPIFFE）

## 镜像 / 供应链

- [ ] 镜像来自私有 Harbor，固定 digest/SHA tag
- [ ] Trivy 扫描通过；高危/可修复漏洞有阻断或豁免记录
- [ ] 镜像签名（cosign/Notation）+ 部署侧验签
- [ ] 生成 SBOM（SPDX/CycloneDX）
- [ ] 基础镜像最小化、非 root、无 shell/包管理器（按需）

## Secret / 权限

- [ ] 不使用长期 AK/静态密码；优先短期凭据
- [ ] Secret 外部化（Vault/ESO）或 SealedSecret
- [ ] `automountServiceAccountToken: false`，除非需要访问 API
- [ ] ServiceAccount 最小 RBAC，不用 cluster-admin
- [ ] 定期轮换 token/证书/密钥

## 审计 / 运行

- [ ] apiserver audit policy + etcd 静态加密
- [ ] Falco/运行时检测（如已部署）
- [ ] 镜像/配置变更可追溯（GitOps）
- [ ] 有 NetworkPolicy/PSA/镜像扫描的 CI 门禁
