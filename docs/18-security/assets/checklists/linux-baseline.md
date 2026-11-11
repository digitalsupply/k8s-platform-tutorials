# Linux 安全基线检查清单

## SSH

- [ ] `PermitRootLogin no`（或 `prohibit-password`）
- [ ] `PasswordAuthentication no`
- [ ] `AllowAgentForwarding no`（除非明确需要）
- [ ] `X11Forwarding no`
- [ ] `MaxAuthTries 3`
- [ ] 使用 SSH CA（`TrustedUserCAKeys`）而不是散落 authorized_keys
- [ ] 生产 SSH 统一堡垒机/ProxyJump，开启审计

## 提权

- [ ] `/etc/sudoers.d/` 最小命令白名单，避免 `NOPASSWD: ALL`
- [ ] 禁止 `vi/less/find/awk/python` 等可逃逸命令
- [ ] 通配符/环境变量（`LD_PRELOAD`、`PATH`）不可被低权用户控制
- [ ] 容器 `capabilities.drop: ALL` + 按需 add
- [ ] `allowPrivilegeEscalation: false` / `NoNewPrivs: 1`
- [ ] 禁止不必要的 setuid 文件

## 审计与完整性

- [ ] auditd 运行且有规则：passwd/shadow/sudoers/execve/setuid/登录
- [ ] audit 规则数量和性能可接受
- [ ] AIDE 建立基线并定期校验
- [ ] Falco/运行时检测（如已部署）
- [ ] 日志集中收集、保留 ≥6 个月（按合规要求）

## 账户 / PAM

- [ ] `pam_faillock` 登录失败锁定
- [ ] `pam_pwquality` 密码复杂度
- [ ] 密码/密钥有效期与轮换
- [ ] MFA（SSH/堡垒机/云控制台）
- [ ] `last`/`lastb` 可查，失败登录有告警

## 内核 / 基线

- [ ] `kernel.randomize_va_space=2`
- [ ] `kernel.kptr_restrict=1`
- [ ] `kernel.dmesg_restrict=1`
- [ ] `kernel.yama.ptrace_scope=1`
- [ ] SELinux/AppArmor 启用
- [ ] THP/overcommit/swappiness 按中间件要求配置
- [ ] CIS Benchmark / OpenSCAP 扫描，有豁免记录

## 补丁

- [ ] 安全更新订阅与资产匹配
- [ ] 优先远程利用/提权/有 EXP 的漏洞
- [ ] 灰度、验证、回滚；内核补丁考虑 livepatch
- [ ] K8s 节点 `cordon`/`drain`、PDB、分批重启
