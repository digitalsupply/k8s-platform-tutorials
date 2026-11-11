# 安全证据：本环境实测

对应教程：[`../../10-linux-k8s-security.md`](../../10-linux-k8s-security.md)。

## 文件

| 文件 | 内容 |
|---|---|
| `linux-baseline.txt` | Rocky/Ubuntu 的 SSH、sudo、auditd、PAM、SELinux/AppArmor、内核硬化、工具 |
| `k8s-security.txt` | apiserver flags、audit/encryption、anonymous、kubelet、RBAC/SA/Secret |
| `pod-security.txt` | PSA 分布、138 Pod/211 容器、privileged/hostNetwork/hostPath、SC/seccomp、CapEff/NNP |
| `network-identity.txt` | NetworkPolicy、默认 deny、Cilium mesh-auth、Service Mesh |
| `supply-chain.txt` | Harbor auto_scan/prevent_vul/immutable、镜像漏洞、签名/SBOM 工具 |
| `patching.txt` | Rocky/Ubuntu 安全更新、内核、livepatch、重启编排 |

## 关键数字

```text
SSH: root yes / password yes / agent forwarding yes / no CA
sudo: cloud-user NOPASSWD:ALL
auditd: m01 active 0 rules；Ubuntu inactive
PSA: 25 none / 1 baseline / 2 privileged / 1 restricted
Pods 138 / containers 211
privileged 10（ceph-csi 9 + buildkit 1）
hostNetwork 35；hostPath 41
allowPrivilegeEscalation=false 93/163
seccomp none 123/163
apiserver: no audit policy / no encryption config
Secret 128；cluster-admin 3；SA automount 125/138
NetworkPolicy 23；Cilium mesh-auth=false
Harbor: deeptutor 1740 漏洞（2 critical/288 high）；openwebui 未扫描
```

## 安全说明

- 只读采集；未修改 SSH/sudo/auditd/PSA/NetworkPolicy；
- Harbor 证据只输出项目配置和漏洞汇总，不含账号/密码；
- 所有凭据未落盘到仓库。
