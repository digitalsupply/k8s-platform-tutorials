# 13 · Linux / Kubernetes / 云原生安全面试题

> 详细证据：[18 安全](../18-security/10-linux-k8s-security.md)。

## 1. sudo 精细化

**一句话**：用 `/etc/sudoers.d` 做“命令+参数+路径”白名单，避免 `NOPASSWD: ALL`。

**本环境**：m01 `cloud-user ALL=(ALL) NOPASSWD:ALL`，等于 root。

## 2. sudo 白名单怎么被绕过

**一句话**：`vi/less/find/awk/python/tar` 都能起 shell；通配符、`LD_PRELOAD`、`PATH` 也可利用。

**本环境**：没有细粒度白名单，直接全权限。

## 3. capability 裁剪

**一句话**：容器默认 `drop: ALL`，按需 add；`CAP_SYS_ADMIN` 近似 root。

**本环境**：99/163 drop ALL；10 个 privileged；backend 保留 14 个默认 caps（含 NET_RAW/MKNOD）。

## 4. no_new_privs

**一句话**：`allowPrivilegeEscalation:false` 对应 NNP=1，阻止 setuid/setgid/file cap 提权。

**本环境**：93/163 设置 false；backend `/proc/1/status` 仍是 `NoNewPrivs: 0`。

## 5. SSH 证书

**一句话**：SSH CA 签发用户/主机证书，支持 TTL、吊销、principal、审计，替代散落 authorized_keys。

**本环境**：无 `TrustedUserCAKeys`；每节点 2 个 authorized_keys。

## 6. 密钥轮换

**一句话**：SSH key/AK/SA token/Secret 定期轮换，优先短期凭据与自动化。

**本环境**：无统一轮换；128 个 Secret，仅 Sealed Secrets。

## 7. ssh-agent 转发风险

**一句话**：`ssh -A` 把本地 agent 暴露给跳板/目标机，跳板被入侵可借用身份。

**本环境**：`AllowAgentForwarding yes`，且 root/密码登录都开着。

## 8. 堡垒机

**一句话**：生产 SSH 统一入口，带审计/录屏/权限回收；OpenSSH 可用 ProxyJump，但企业优先堡垒机。

**本环境**：没有统一堡垒机，直接 SSH 节点 IP。

## 9. auditd

**一句话**：审计 passwd/shadow/sudoers/execve/setuid/登录；规则要少而关键，注意性能。

**本环境**：m01 auditd active 但 0 规则；Ubuntu inactive，auditctl 都没有。

## 10. AIDE

**一句话**：文件完整性基线；先 init，再定期 check，排除高频变化目录。

**本环境**：未安装 AIDE。

## 11. Falco

**一句话**：基于 syscall/eBPF 的运行时检测，抓逃逸、异常 shell、敏感文件读取、提权。

**本环境**：未部署 Falco。

## 12. pam_faillock

**一句话**：登录失败 N 次锁定，防爆破；配合密码策略、审计、告警。

**本环境**：未配置 faillock。

## 13. 密码策略

**一句话**：`pam_pwquality` 控复杂度，`chage` 控有效期；但频繁改密不一定更安全，重点 MFA/防泄露。

**本环境**：m01 有 pwquality；Ubuntu 没有。

## 14. 登录审计

**一句话**：`last` 成功、`lastb` 失败；Rocky 看 `/var/log/secure`，Ubuntu 看 `/var/log/auth.log`。

**本环境**：lastb 仅 btmp 头，无有效失败记录；日志未集中。

## 15. CVE 追踪

**一句话**：订阅 CVE、匹配资产、按远程利用/提权/EXP/影响面分级。

**本环境**：m01 245 个安全更新（4 critical/143 important）；Ubuntu 51 个可升级。

## 16. 自动补丁

**一句话**：Rocky `dnf updateinfo`/`dnf update --security`；Ubuntu `unattended-upgrades`；生产灰度/验证/回滚。

**本环境**：Ubuntu unattended enabled；Rocky 未自动打。

## 17. 内核热补丁

**一句话**：kpatch/kgraft/livepatch 能不重启修关键内核 CVE，但不能替代完整升级/重启。

**本环境**：kpatch/livepatch 未安装。

## 18. 重启编排

**一句话**：cordon → drain（PDB/优雅退出）→ 补丁/重启 → uncordon，分批节点池。

**本环境**：无 reboot orchestrator CRD。

## 19. CIS Benchmark

**一句话**：系统/SSH/审计/权限/内核参数基线，可加固、扫描、合规审计。

**本环境**：无 OpenSCAP/lynis；SSH/auditd/sudo 多项不达标。

## 20. OpenSCAP

**一句话**：自动化合规扫描/修复，可对接 CIS/等保；注意误报和业务兼容。

**本环境**：未安装。

## 21. 等保 2.0 三级

**一句话**：身份鉴别、访问控制、安全审计、入侵防范、恶意代码、备份、日志留存、制度。

**本环境**：审计/日志留存/备份/制度均有缺口。

## 22. 国密

**一句话**：SM2/SM3/SM4 覆盖证书/TLS/VPN/KMS/应用，不是简单替换算法名。

**本环境**：未做国密改造。

## 23. 镜像扫描

**一句话**：Trivy/Grype 扫 OS 包和语言依赖；仓库可配高危阻断。

**本环境**：compassio/deeptutor 开扫描；deeptutor 1740 漏洞（2 critical/288 high）；openwebui 未扫描。

## 24. SBOM

**一句话**：SPDX/CycloneDX 物料清单，用于漏洞影响分析、资产盘点、合规。

**本环境**：无 SBOM 工具/产物。

## 25. 镜像签名

**一句话**：cosign/Notation 签名，部署侧验签，防篡改/替换/投毒。

**本环境**：cosign/notation 未安装，无验签。

## 26. SLSA

**一句话**：供应链成熟度模型：可重现构建、来源证明、构建隔离、防篡改发布。

**本环境**：无 provenance/SLSA。

## 27. Harbor

**一句话**：私有仓库 + 扫描 + 漏洞门禁 + 签名验证 + RBAC + 项目隔离 + robot account。

**本环境**：auto_scan 部分开；`prevent_vul` 全无；immutable tag 0。

## 28. PSA

**一句话**：namespace label 实施 privileged/baseline/restricted；PSP 已在 1.25 移除。

**本环境**：25 个 ns 无 label；1 restricted/1 baseline/2 privileged。

## 29. securityContext

**一句话**：`runAsNonRoot`、`readOnlyRootFilesystem`、`allowPrivilegeEscalation:false`、`drop: ALL`。

**本环境**：163 容器：46/89/93/99，覆盖不足。

## 30. seccomp

**一句话**：`RuntimeDefault` 或自定义 profile，限制 syscall，降低逃逸/内核漏洞利用。

**本环境**：123 个 none、39 RuntimeDefault、1 Unconfined。

## 31. Secret 加密与外部化

**一句话**：etcd 静态加密只是底线；Vault+ESO 提供短期、审计、轮换。

**本环境**：无 encryption provider；128 Secret；仅 Sealed Secrets，无 Vault/ESO。

## 32. NetworkPolicy

**一句话**：依赖 CNI；Calico/Cilium 支持；先 default deny，再逐条放行。

**本环境**：23 条；仅 1 个 namespace 有全选 ingress 隔离；无 Cilium 策略。

## 33. mTLS

**一句话**：服务间双向 TLS + 工作负载身份（SPIFFE/SPIRE/Service Mesh）。

**本环境**：Cilium `mesh-auth-enabled=false`；无 Istio/Linkerd/SPIRE。

## 34. 身份联邦

**一句话**：K8s SA → OIDC → 云 IAM Role，避免长期 AK；AWS IRSA/GCP WI/Azure WI。

**本环境**：on-prem，无云身份联邦。

## 35. 30 秒总回答

```text
提权：sudo 白名单防 vi/find 绕过；capabilities drop ALL；
      allowPrivilegeEscalation=false = no_new_privs。
认证：SSH CA 替代 authorized_keys；禁 root/密码/agent forwarding；短 TTL + 轮换。
审计：auditd 关键规则、AIDE 基线、Falco 运行时。
补丁：CVE 分级；dnf/apt 安全更新；livepatch 只顶内核 CVE；节点 cordon/drain。
K8s：PSA restricted；securityContext 四件套；seccomp；Secret 加密/外部化；
     NetworkPolicy 默认拒绝；mTLS/SPIFFE。
供应链：Trivy+SBOM+cosign；Harbor prevent_vul+immutable；部署侧验签。
```

## 一句话总表

| 题 | 一句话 |
|---|---|
| sudo | 白名单，禁 NOPASSWD ALL |
| 绕过 | vi/find/awk/python/通配符/环境变量 |
| capabilities | drop ALL，按需 add |
| no_new_privs | allowPrivilegeEscalation=false |
| SSH CA | 短期证书 + 吊销 |
| 轮换 | 短 TTL + 自动 |
| agent 转发 | 默认关闭 |
| 堡垒机 | 统一入口 + 审计 |
| auditd | 关键文件/execve/setuid |
| AIDE | 完整性基线 |
| Falco | 运行时 syscall/eBPF |
| faillock | 失败锁定 |
| 密码策略 | 复杂度 + MFA |
| 登录审计 | last/lastb/secure/auth.log |
| CVE | 远程/提权/EXP 优先 |
| 自动补丁 | dnf/apt + 灰度 |
| livepatch | 只顶内核 CVE |
| 重启 | cordon/drain/分批 |
| CIS | 基线扫描 |
| OpenSCAP | 自动合规 |
| 等保 | 身份/审计/备份/制度 |
| 国密 | SM2/3/4 全链路 |
| 镜像扫描 | Trivy/Grype |
| SBOM | SPDX/CycloneDX |
| 签名 | cosign/Notation + 验签 |
| SLSA | 来源/可重现/隔离 |
| Harbor | 扫描+门禁+签名+RBAC |
| PSA | restricted |
| securityContext | 四件套 |
| seccomp | RuntimeDefault |
| Secret | 加密+外部化 |
| NetworkPolicy | 默认拒绝 |
| mTLS | SPIFFE/Service Mesh |
| 身份联邦 | IRSA/WI，避免长期 AK |
