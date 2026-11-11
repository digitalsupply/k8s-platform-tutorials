# 18 · Linux / Kubernetes / 云原生安全

> 安全不是“装个 Falco/Trivy”，而是把**提权面、身份、审计、补丁、基线、供应链、
> 工作负载、零信任**逐项落到配置和验证。
>
> 详细章节：[`10-linux-k8s-security.md`](10-linux-k8s-security.md)。
> 一句话版本：[15 面试速查 13-security](../15-interview-cheatsheet/13-security.md)。

## 本环境结论

| 域 | 实测 | 风险 |
|---|---|---|
| SSH | root 登录 yes、密码 yes、agent forwarding yes、无 CA | 爆破/身份借用 |
| sudo | `cloud-user NOPASSWD:ALL` | 等于 root |
| auditd | m01 active 0 规则；Ubuntu inactive | 无审计 |
| AIDE/Falco/oscap/lynis | 未安装/未部署 | 无完整性/运行时/合规 |
| PAM | m01 pwquality；Ubuntu 无；无 faillock | 无锁定/策略不一致 |
| SELinux/AppArmor | SELinux disabled；AppArmor 22 profiles；Pod 注解 0 | 无强制访问控制 |
| 补丁 | m01 245 security（4 critical）；Ubuntu 51 | 补丁滞后 |
| PSA | 25 ns 无 label；1 restricted/1 baseline/2 privileged | 大部分无约束 |
| privileged | 10（Ceph CSI 9 + BuildKit 1） | 逃逸风险 |
| hostNetwork/hostPath | 35 / 41 Pod | 宿主暴露 |
| SC | NNP false 93/163；seccomp none 123 | 覆盖不足 |
| apiserver | 无 audit policy、无 etcd 加密 | 无 API 审计/Secret 明文 |
| Secret | 128；Sealed Secrets；无 Vault/ESO | 轮换/审计弱 |
| RBAC | 3 cluster-admin；125/138 自动挂 SA token | 权限过大 |
| NetworkPolicy | 23；仅 1 个全选隔离 | 无默认 deny |
| mTLS | Cilium mesh-auth=false；无 mesh/SPIRE | 无服务身份 |
| 供应链 | 扫描有、拦截无、签名无；deeptutor 1740 漏洞 | 供应链风险 |

## 目录

```text
18-security/
├── README.md
├── 10-linux-k8s-security.md
└── assets/
    ├── evidence/
    │   ├── linux-baseline.txt
    │   ├── k8s-security.txt
    │   ├── pod-security.txt
    │   ├── network-identity.txt
    │   ├── supply-chain.txt
    │   └── patching.txt
    └── checklists/
        ├── linux-baseline.md
        └── k8s-workload-security.md
```

## 怎么用

1. 先看 [`10-linux-k8s-security.md`](10-linux-k8s-security.md) 的基线表；
2. 用 [`assets/checklists/linux-baseline.md`](assets/checklists/linux-baseline.md) 查宿主；
3. 用 [`assets/checklists/k8s-workload-security.md`](assets/checklists/k8s-workload-security.md) 评审工作负载；
4. 用 [`assets/evidence/`](assets/evidence/README.md) 复现/对比本环境。
