# 10 · Linux / Kubernetes / 云原生安全

> 这一章把安全域拆成可检查的项：提权、认证密钥、审计、PAM、补丁、基线、供应链、
> K8s 工作负载、零信任。每条尽量给本环境实测，再给标准和修法。
>
> 实测基线：Rocky 9.6 / Ubuntu 22.04.5、K8s v1.35.9、138 Pod、211 容器、
> 251 条告警、Harbor 5 个项目。
>
> 证据：[`assets/evidence/`](assets/evidence/README.md)。
> 清单：[`assets/checklists/`](assets/checklists/k8s-workload-security.md)。

## 0. 本环境安全基线（先看结论）

| 项 | 实测 | 风险 |
|---|---|---|
| SSH root 登录 | **yes** | 高危，应 no/prohibit-password |
| SSH 密码登录 | **yes** | 可被爆破，应 no |
| SSH Agent 转发 | **yes** | 跳板被入侵可借用身份 |
| SSH X11 转发 | **yes** | 无必要，应关闭 |
| SSH CA | **无** `TrustedUserCAKeys` | 散落 authorized_keys，难吊销/审计 |
| sudo | m01 `cloud-user NOPASSWD:ALL` | 等于 root，无最小权限 |
| auditd | m01 active 但 **0 条规则**；Ubuntu inactive | 无有效审计 |
| AIDE / oscap / lynis | **未安装** | 无完整性/合规基线 |
| Falco | **未部署** | 无运行时检测 |
| PAM faillock | **未配置** | 无登录失败锁定 |
| PAM pwquality | m01 有；Ubuntu **无** | 密码复杂度不一致 |
| SELinux | m01 **Disabled** | 无强制访问控制 |
| AppArmor | Ubuntu 22 profiles enforce；Pod 注解 **0** | 容器未使用 profile |
| 内核硬化 | m01 `dmesg_restrict=0`、`ptrace_scope=0` | 信息泄露/调试面 |
| 安全更新 | m01 **245**（4 critical/143 important）；Ubuntu 51 | 补丁滞后 |
| livepatch/kpatch | 无 | 内核 CVE 只能重启 |
| PSA 覆盖 | 25 个 ns **无 label**；1 restricted/1 baseline/2 privileged | 大部分工作负载无 PSA |
| privileged 容器 | **10** | 逃逸风险 |
| hostNetwork / hostPath | 35 Pod / 41 Pod | 网络/宿主暴露 |
| allowPrivilegeEscalation=false | 93 / 163 容器 | 仍有 70 个未设 |
| runAsNonRoot | 46 / 163 | 多数可能 root |
| readOnlyRootFilesystem | 89 / 163 | 可写根文件系统 |
| drop ALL | 99 / 163 | 64 个保留默认 caps |
| seccomp | 123 none / 39 RuntimeDefault / 1 Unconfined | 多数无 syscall 限制 |
| apiserver audit | **无** audit policy | 无 API 审计 |
| etcd 静态加密 | **无** encryption provider | Secret 明文落 etcd |
| Secret 数量 | 128；仅 Sealed Secrets，无 Vault/ESO | 轮换/审计弱 |
| SA token automount | 125 / 138 未关闭 | token 暴露面 |
| cluster-admin bindings | 3 | 含 dashboard SA |
| NetworkPolicy | 23；仅 1 个 namespace 有全选 ingress 隔离 | 无集群默认 deny |
| mTLS | Cilium `mesh-auth-enabled=false`，无 Istio/Linkerd/SPIRE | 无服务间身份 |
| 镜像扫描 | compassio 开、deeptutor 开、openwebui **关** | 有未扫描镜像 |
| 高危漏洞阻断 | **无** `prevent_vul` | 扫描只展示不拦截 |
| 镜像签名/SBOM | **无** cosign/notation/syft/trivy | 无供应链验签 |
| Harbor immutable tag | **0** | tag 可覆盖 |

> 一句话：**Linux 基线偏弱、K8s 安全上下文覆盖不全、供应链只“扫”不“拦”。**

## 1. 提权与最小权限

### 1.1 sudo 精细化

标准做法：

```text
/etc/sudoers.d/<team>-<purpose>
  ops ALL=(root) NOPASSWD: /usr/bin/systemctl restart nginx
```

不要：

```text
cloud-user ALL=(ALL) NOPASSWD:ALL
```

本环境实际：

```text
/etc/sudoers.d/90-cloud-init-users:
  cloud-user ALL=(ALL) NOPASSWD:ALL
```

这就是“云镜像默认用户 = root”，没有最小权限。

命令白名单绕过要警惕：

| 命令 | 绕过方式 |
|---|---|
| `vi` / `vim` | `:!sh` |
| `less` / `more` | `!sh` |
| `find` | `-exec sh -c ...` |
| `awk` | `system()` |
| `python` / `perl` | `os.system()` |
| `tar` | `--checkpoint-action=exec` |
| 通配符 | 参数注入、路径替换 |
| 环境变量 | `LD_PRELOAD`、`PATH`、`BASH_ENV` |

原则：白名单要限制**命令 + 参数 + 目标路径**，不能只限制命令名；
能用 systemd unit/受限 API 就不要给 shell。

### 1.2 capability 裁剪

本环境：

```text
compassio-backend:
  CapEff = 00000000a80425fb
  -> chown, dac_override, fowner, fsetid, kill, setgid, setuid,
     setpcap, net_bind_service, net_raw, sys_chroot, mknod,
     audit_write, setfcap
```

这是 Docker 默认 caps，仍包含 `CAP_NET_RAW`、`CAP_MKNOD`、`CAP_SETUID`。
容器统计：

```text
163 个常规容器：drop ALL 99 个
10 个 privileged 容器（Ceph CSI 等）
```

建议：

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
    add: ["NET_BIND_SERVICE"]   # 只在确需绑定 <1024 端口时
```

`CAP_SYS_ADMIN` 几乎等于 root，禁止随意添加；Ceph CSI/网络插件等例外要单独评估。

### 1.3 no_new_privs

`no_new_privs=1` 后，进程及子进程不能通过 setuid/setgid/file capability 提权。
K8s 里对应：

```yaml
securityContext:
  allowPrivilegeEscalation: false
```

本环境：

```text
allowPrivilegeEscalation=false: 93 / 163 容器
compassio-backend /proc/1/status:
  NoNewPrivs: 0
Ceph CSI ctrlplugin:
  NoNewPrivs: 0
CapEff: 0000000000000000
```

所以“写了 securityContext 的容器”不等于“默认都有 NNP”；
要用 `/proc/1/status` 验证，而不是只看 YAML。

## 2. 认证与密钥

### 2.1 SSH 现状

```text
PermitRootLogin yes
PasswordAuthentication yes
AllowAgentForwarding yes
X11Forwarding yes
MaxAuthTries 6
TrustedUserCAKeys: 无
authorized_keys 文件: 2（每节点 root/home）
```

风险：

- root 直接登录 + 密码认证 → 爆破面；
- agent forwarding → 跳板/目标机可借用本地私钥；
- X11 forwarding → 不必要攻击面；
- 没有 SSH CA → 发出去的 key 难吊销、难审计。

### 2.2 SSH CA 方案

```text
CA 私钥离线保管
  -> 给用户签 user cert（principal、有效期、permit-*
  -> 给主机签 host cert
sshd_config:
  TrustedUserCAKeys /etc/ssh/ca_user.pub
  HostCertificate /etc/ssh/ssh_host_ed25519_key-cert.pub
```

优点：有效期、吊销（KRL）、按 principal 授权、审计统一。
配套：

- `PermitRootLogin no`；
- `PasswordAuthentication no`；
- `AllowAgentForwarding no`；
- `X11Forwarding no`；
- 生产 SSH 统一堡垒机/`ProxyJump`，开启录屏/命令审计。

### 2.3 密钥轮换

- SSH key：90 天或按项目；CA 短 TTL（小时/天）；
- AccessKey：优先 STS/短期凭据，长期 AK 90 天轮换；
- ServiceAccount Token：K8s 1.24+ 默认 projected token，有 TTL；仍要关闭不必要的 automount；
- Secret：数据库密码/Token 定期轮换，优先 Vault/ESO 动态凭据；
- 轮换要可自动、可回滚，不要靠人记日历。

## 3. 审计与入侵检测

### 3.1 auditd

本环境：

```text
m01: auditd active，但 auditctl -l = No rules
Ubuntu worker: auditd inactive，auditctl 不存在
```

等于**没有有效审计**。建议至少：

```bash
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k privilege
-w /etc/sudoers.d/ -p wa -k privilege
-w /etc/ssh/sshd_config -p wa -k ssh
-a always,exit -F arch=b64 -S execve -k exec
-a always,exit -F arch=b64 -S setuid -S setgid -k privilege
-a always,exit -F arch=b64 -S ptrace -k debug
```

注意：

- `execve` 全量审计量很大，要配合 `-F auid!=unset`/关键用户；
- 规则太多会丢事件/影响性能；
- audit 日志要集中收集，保留 ≥6 个月（等保常见要求）。

### 3.2 AIDE

本环境未安装 AIDE。做法：

```bash
aide --init
cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
aide --check
```

排除 `/proc`、`/sys`、`/run`、`/var/log`、容器可写层等高频变化目录；
先基线、后告警，否则每天都是噪声。

### 3.3 Falco

本环境未部署 Falco。Falco 基于 syscall/eBPF，适合检测：

- 容器内起 shell；
- 读取 `/etc/shadow`；
- `ptrace`/`setns`/`mount` 异常；
- 提权、写敏感目录、反弹 shell。

没有运行时检测时，K8s 里“Pod 被入侵后执行命令”只能靠审计日志/事后排查。

## 4. 账户与 PAM

本环境：

```text
m01: pam_pwquality 有；pam_faillock 无
Ubuntu: pam_pwquality/pam_faillock 都无（grep 为空）
lastb: 仅 btmp 头，无有效失败记录
```

建议：

```text
/etc/security/faillock.conf:
  deny = 5
  unlock_time = 900
  fail_interval = 900
pam_faillock in auth/account
pam_pwquality: minlen=12, minclass=3, maxrepeat=3
chage: 密码/账户有效期按制度
```

注意：NIST 800-63B 不推荐强制频繁改密；重点是 MFA、泄露检测、长度。
但等保/行业规范可能仍要求定期更换，按合规要求落地。

登录审计：

```bash
last        # 成功登录
lastb       # 失败登录
# Rocky: /var/log/secure；Ubuntu: /var/log/auth.log
journalctl -u sshd --since today
```

## 5. 补丁与漏洞

本环境：

```text
Rocky m01: 245 安全更新
  4 critical / 143 important / 89 moderate / 9 low
Ubuntu worker01: 51 个可升级包；unattended-upgrades enabled
内核: 5.14.0-570 / 5.15.0-202
kpatch / canonical-livepatch: 未安装
K8s reboot orchestrator: 无
```

风险：

- 245 个安全更新未打，含 4 个 critical；
- 内核 CVE 只能重启，且没有 livepatch；
- 没有自动 drain/reboot 编排。

建议：

```bash
# Rocky
dnf updateinfo list security
dnf update --security
# Ubuntu
unattended-upgrade --dry-run
apt list --upgradable
```

CVE 优先级：

1. 远程可利用（网络服务）；
2. 本地提权；
3. 已有公开 EXP；
4. 影响面大/无缓解措施。

K8s 节点补丁流程：

```text
cordon -> drain（PDB/优雅退出）-> 打补丁/重启 -> uncordon
-> 验证节点/业务 -> 下一批
```

livepatch/kpatch 只能顶关键内核 CVE，**不能替代完整升级和重启窗口**。

## 6. 基线合规：CIS / OpenSCAP / 等保 / 国密

### 6.1 CIS Benchmark

本环境未安装 OpenSCAP/lynis，也没有正式 CIS 扫描。  
从实测看，至少这些 CIS 项不达标：

- SSH root 登录/密码认证/agent forwarding；
- auditd 无规则；
- sudo NOPASSWD ALL；
- 内核 `dmesg_restrict=0`、`ptrace_scope=0`；
- 密码策略不一致；
- 容器 privileged/hostPath/无 seccomp。

### 6.2 OpenSCAP

```bash
dnf install openscap-scanner scap-security-guide
oscap xccdf eval --profile cis \
  --results /tmp/cis.xml \
  /usr/share/xml/scap/ssg/content/ssg-rhel9-ds.xml
```

注意：

- 先 `--remediate` 在测试环境验证；
- 规则可能影响业务（如 SSH 算法、挂载选项）；
- 误报要记录豁免，不要直接全量修。

### 6.3 等保 2.0 三级

常见控制点：

```text
身份鉴别：唯一身份、复杂度、登录失败处理、远程管理防窃听
访问控制：最小权限、默认拒绝、权限分离
安全审计：覆盖每个用户、审计记录保护、留存 ≥6 个月
入侵防范：最小服务、漏洞修补、恶意代码、外联管控
数据备份：本地/异地、恢复演练
管理制度：安全策略、人员、变更、应急预案
```

### 6.4 国密

国密不是“把 RSA 换成 SM2”：

- 算法：SM2（非对称）、SM3（哈希）、SM4（对称）；
- 证书链/CA、TLS 密码套件、VPN、密钥管理系统都要支持；
- 应用/中间件/客户端要适配，性能/兼容性要验证；
- 合规改造通常需要国密证书、国密网关、密码机。

本环境没有国密改造；本章只给方法，不假装已实现。

## 7. 供应链安全

### 7.1 本环境 Harbor 实测

| 项目 | auto_scan | prevent_vul | immutable tags |
|---|---|---|---|
| compassio | ✅ | ❌ | 0 |
| deeptutor | ✅ | ❌ | 0 |
| openwebui | ❌ | ❌ | 0 |
| china-study-free | 未开 | ❌ | 0 |
| library | 未开 | ❌ | 0 |

镜像扫描：

```text
compassio/frontend  total=0
deeptutor/deeptutor total=1740
  Critical=2, High=288, Medium=547, Low=880, Unknown=23, fixable=41
openwebui/open-webui scan=None（auto_scan 关闭）
```

风险：

- 有 2 个 critical/288 个 high 的镜像仍可被拉取；
- `prevent_vul` 未开，扫描只是“展示”，没有门禁；
- 没有 immutable tag 规则，tag 可覆盖；
- 没有 cosign/Notation 签名，没有部署侧验签；
- 没有 syft/trivy SBOM，没有 SLSA provenance。

### 7.2 建议

```text
构建：Trivy/Grype 扫描 + SBOM（SPDX/CycloneDX）+ 签名（cosign）
仓库：Harbor 自动扫描 + prevent_vul + immutable tag + robot account
部署：Kyverno/OPA 验签 + 只允许固定 digest
流程：SLSA 来源证明 + 构建隔离 + 可重现构建
```

Harbor 的“扫描”与“拦截”是两件事：
**扫描告诉你有什么，prevent_vul/验签才决定能不能进集群。**

## 8. Kubernetes 侧安全

### 8.1 PSA

本环境 namespace label：

```text
25 个 namespace 无 pod-security label
1 个 restricted（tekton-pipelines）
1 个 baseline（china-study-free）
2 个 privileged（etcd-backup、metallb-system）
```

大多数工作负载没有 PSA 约束。建议：

```yaml
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/warn: restricted
```

先 `warn`/`audit` 观察，再 `enforce`；Ceph CSI/MetalLB/etcd-backup 等例外单独 namespace。

### 8.2 securityContext

本环境 163 个常规容器：

```text
allowPrivilegeEscalation=false   93
runAsNonRoot=true                46
readOnlyRootFilesystem=true      89
capabilities.drop ALL            99
seccomp RuntimeDefault           39
seccomp none                    123
seccomp Unconfined                1
```

推荐：

```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop: ["ALL"]
```

### 8.3 seccomp

123 个容器没有 seccomp，等于允许全部 syscall。
`RuntimeDefault` 是低成本基线；自定义 profile 适合高风险工作负载。
`Unconfined` 只应在明确兼容性测试后使用。

### 8.4 Secret 加密与外部化

本环境：

```text
kube-apiserver 无 --encryption-provider-config
/etc/kubernetes/encryption-config.yaml 不存在
Secret 128 个
Sealed Secrets controller 1 个
Vault / ESO：未部署
```

etcd 静态加密只是底线；推荐 Vault + External Secrets Operator：

- 短期凭据/动态数据库账号；
- 审计谁在何时取了哪个 Secret；
- 自动轮换；
- 避免 Secret 长期落在 etcd/Pod env。

### 8.5 RBAC 与 ServiceAccount

```text
cluster-admin bindings: 3
ServiceAccount: 131
Pod 未关闭 automountServiceAccountToken: 125 / 138
```

`cluster-admin` 包括 dashboard 的 `admin-user` SA；如果 Dashboard 不需要写权限，应删除/降权。
默认 SA token 挂载应关闭：

```yaml
automountServiceAccountToken: false
```

### 8.6 NetworkPolicy

```text
NetworkPolicy: 23
只有 tekton-pipelines 一个 namespace 有空 podSelector 的 ingress 隔离
CiliumNetworkPolicy: 0
Cilium mesh-auth-enabled: false
```

Cilium 支持 NetworkPolicy，但“支持”不等于“已配置”。
建议：

- 每个 namespace 先 default deny ingress/egress；
- 再按 DNS/入口/依赖逐条放行；
- 用 Hubble 验证 flow，不要一次性全 deny。

## 9. 零信任

### 9.1 mTLS

本环境没有 Istio/Linkerd/SPIRE，Cilium `mesh-auth-enabled=false`，
所以服务间没有 mTLS 身份。

方案：

- Cilium mutual auth（SPIFFE identity）；
- Service Mesh（Istio/Linkerd）自动 mTLS；
- SPIFFE/SPIRE 给工作负载发短期 SVID；
- 入口 mTLS + 内部 mTLS，证书短 TTL、自动轮换。

### 9.2 身份联邦

本环境是 on-prem，无云 IRSA/Workload Identity。  
云上原则：

```text
K8s ServiceAccount -> OIDC -> 云 IAM Role
避免长期 AK；用短期 STS
按 namespace/SA 限制 trust policy
```

对应：

- AWS IRSA；
- GCP Workload Identity；
- Azure Workload Identity。

## 10. 面试 30 秒

```text
提权：sudo 白名单防 vi/find 绕过；capabilities drop ALL；
      allowPrivilegeEscalation=false = no_new_privs。

认证：SSH CA 替代 authorized_keys；禁 root/密码/agent forwarding；
      短 TTL + 轮换；堡垒机审计。

审计：auditd 规则（passwd/shadow/sudoers/execve）、AIDE 基线、Falco 运行时。

补丁：CVE 分级；dnf/apt 安全更新；livepatch 只顶内核 CVE；
      K8s 节点 cordon/drain 分批。

K8s：PSA restricted；securityContext 四件套；seccomp RuntimeDefault；
     Secret 加密+外部化；NetworkPolicy 默认拒绝；mTLS/SPIFFE。

供应链：Trivy+SBOM+cosign；Harbor prevent_vul+immutable tag；
       部署侧验签，不能只“扫”不“拦”。
```

## 11. 一页命令

```bash
# Linux
sshd -T | grep -E 'permitrootlogin|passwordauthentication|allowagentforwarding'
auditctl -l
lastb
getenforce || aa-status
sysctl kernel.randomize_va_space kernel.kptr_restrict kernel.dmesg_restrict kernel.yama.ptrace_scope
dnf updateinfo list security        # Rocky
apt list --upgradable               # Ubuntu

# K8s
kubectl get ns -o json | jq '.items[] | {name:.metadata.name, labels:.metadata.labels}'
kubectl get pods -A -o json | jq '[.items[] | select(.spec.hostNetwork or (.spec.containers[]?.securityContext.privileged==true))] | length'
kubectl auth can-i --list
kubectl get networkpolicy -A
kubectl -n kube-system get cm cilium-config -o yaml | grep mesh-auth

# 供应链
trivy image <image>
cosign verify <image>
syft <image> -o spdx-json
```
