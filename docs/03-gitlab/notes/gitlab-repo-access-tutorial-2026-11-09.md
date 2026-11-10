# GitLab 仓库获取教程：SSH、HTTPS PAT、Deploy Token 与 ArgoCD 凭据

> 环境：GitLab `192.168.67.201`，仓库 `digitalsupply/platform-gitops.git`
> 本机：Proxmox 宿主机 `teacher`（10.0.0.1），Git 2.39.5，root 用户
> 日期：2026-11-09
> 适用：人工克隆、脚本/CI 拉取、ArgoCD 纳管仓库

---

## 0. 一屏结论

Git 访问 GitLab 只有两种协议：

| 协议 | 地址形式 | 认证方式 | 适合场景 |
|---|---|---|---|
| HTTPS | `http://192.168.67.201/group/repo.git` | 用户名 + PAT / Deploy Token | 脚本、临时克隆、内网 HTTP |
| SSH | `git@192.168.67.201:group/repo.git` | SSH 公钥（个人 Key 或 Deploy Key） | 日常开发/运维、长期使用 |

**本机当前实际采用的方式：**

- 已存在工作副本 `/root/gitops-p0`；
- `origin` 是 HTTPS，URL 中直接内嵌了 `root:<TOKEN>@192.168.67.201/...`；
- 直接 `git fetch` / `git commit` / `git push` 成功；
- SSH 方式**没有配置成功**：`git@192.168.67.201: Permission denied (publickey)`。

> 安全提醒：当前 `.git/config` 里有明文 token。本文不记录 token 值。
> 建议尽快轮换该 token，并改用 SSH key 或 credential helper，不要把 token 写在 remote URL 里。

---

## 1. 需要哪些组件/凭据

### 1.1 基础组件

| 组件 | 作用 | 是否必需 | 本机现状 |
|---|---|---|---|
| Git | 克隆/提交/推送 | 必需 | 2.39.5 |
| 网络到 GitLab | 80/443（HTTP/HTTPS）或 22（SSH） | 必需 | HTTP 200，SSH 22 可达但认证失败 |
| GitLab 账号 | 项目成员权限 | 必需 | 已有可 push 的账号（root） |
| 项目路径 | group/repo | 必需 | `digitalsupply/platform-gitops.git` |
| 项目页面 | GitLab Web | 参考 | `http://192.168.67.201/digitalsupply/platform-gitops` |
| 默认分支 | 推送目标 | 参考 | `main` |

### 1.2 凭据（二选一）

| 凭据 | 生成位置 | 权限 | 适用 |
|---|---|---|---|
| **Personal Access Token (PAT)** | GitLab → User Settings → Access Tokens | `read_repository` / `write_repository`（或 `api`） | HTTPS 克隆/推送、脚本 |
| **SSH Key** | 本机 `ssh-keygen`，公钥加到 GitLab | 由账号权限决定 | SSH 克隆/推送 |
| **Deploy Key** | 项目 → Settings → Repository → Deploy keys | 默认只读，可勾选 write | 单仓库自动化 |
| **Deploy Token** | 项目 → Settings → Repository → Deploy tokens | `read_repository` / `write_repository` | 单仓库 HTTPS 自动化 |
| **Project/Group Access Token** | 项目/组 → Access Tokens | 细粒度 scopes | 机器人账号、多仓库自动化 |
| **CI_JOB_TOKEN** | GitLab CI 内置 | 流水线内 | CI 内拉取依赖仓库 |

### 1.3 推荐搭配

| 场景 | 推荐 |
|---|---|
| 人工日常操作 | SSH key + ssh-agent |
| 一次性/脚本克隆 | PAT + credential helper（或环境变量） |
| 只读自动化 | Deploy Key（只读）或 Deploy Token |
| 多仓库机器人 | Project/Group Access Token，最小权限 + 过期时间 |
| ArgoCD | 独立的 Repository Secret（只读 PAT 或 SSH Deploy Key） |

---

## 2. 方式一：HTTPS + Personal Access Token

### 2.1 创建 PAT

GitLab 页面：

```text
右上角头像 → Preferences / Settings → Access Tokens
```

填写：

- Name：例如 `teacher-gitops-cli`
- Expiration：建议 30–90 天
- Scopes：
  - 只拉取：`read_repository`
  - 需要 push：`write_repository`
  - 需要调用 GitLab API：`api`（权限更大，慎用）
- Role：按需，通常 Developer 即可 push 非保护分支

创建后只显示一次，立即保存到密码管理器。

### 2.2 克隆

方式 A：URL 内嵌 token（简单但不推荐长期使用）

```bash
git clone http://<USERNAME>:<TOKEN>@192.168.67.201/digitalsupply/platform-gitops.git
```

方式 B：交互输入（token 当密码）

```bash
git clone http://192.168.67.201/digitalsupply/platform-gitops.git
# Username: <USERNAME>
# Password: <TOKEN>
```

方式 C：credential helper（推荐）

```bash
# 只存内存 15 分钟
git config --global credential.helper 'cache --timeout=900'

# 或落盘到 ~/.git-credentials（记得 chmod 600）
git config --global credential.helper store

git clone http://192.168.67.201/digitalsupply/platform-gitops.git
# 第一次输入用户名 + token，之后自动复用
chmod 600 ~/.git-credentials
```

方式 D：`~/.netrc`

```text
machine 192.168.67.201
  login <USERNAME>
  password <TOKEN>
```

```bash
chmod 600 ~/.netrc
```

### 2.3 验证

```bash
git ls-remote http://192.168.67.201/digitalsupply/platform-gitops.git
git fetch origin
git push origin main
```

### 2.4 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `Authentication failed` / `HTTP 401` | token 错、过期、scope 不够 | 重新生成，确认 `read_repository`/`write_repository` |
| `remote: You are not allowed to push code to this project` | 账号角色不够 / 保护分支 | 找 Maintainer 授权，或走 MR |
| `could not read Username` | 非交互 shell，没 credential helper | 用 token URL、`.netrc` 或 helper |
| `repository not found` | URL/路径错，或账号无权限 | 核对 group/repo 和成员权限 |
| `SSL certificate problem` | 内网自签 CA | 配置 `http.sslCAInfo`，不要直接关校验 |

### 2.5 安全注意

- token 放在 URL 里会出现在：
  - `.git/config`
  - shell history
  - `ps` 进程列表
  - CI 日志
- 生产环境优先用 credential helper、环境变量或 GitLab CI 变量；
- 给 token 设置过期时间，定期轮换；
- 不要给 `api` 权限，除非确实要调 GitLab API。

---

## 3. 方式二：SSH Key

### 3.1 生成密钥

```bash
ssh-keygen -t ed25519 -a 100 \
  -C "root@teacher-gitlab" \
  -f ~/.ssh/id_ed25519_gitlab
```

生成：

```text
~/.ssh/id_ed25519_gitlab      私钥（chmod 600）
~/.ssh/id_ed25519_gitlab.pub  公钥
```

### 3.2 把公钥加到 GitLab

个人使用：

```text
GitLab → 头像 → Preferences → SSH Keys → Add new key
```

粘贴 `~/.ssh/id_ed25519_gitlab.pub` 的内容。

只给单个仓库使用（推荐机器人/CI）：

```text
项目 → Settings → Repository → Deploy keys → Add deploy key
```

- 默认只读；
- 需要 push 时勾选 `Grant write permissions to this key`；
- 一个 Deploy Key 默认只能用于一个项目。

### 3.3 配置 SSH（可选但推荐）

`~/.ssh/config`：

```text
Host gitlab-192-168-67-201
    HostName 192.168.67.201
    User git
    IdentityFile ~/.ssh/id_ed25519_gitlab
    IdentitiesOnly yes
```

如果 SSH 不是 22 端口：

```text
Host gitlab-192-168-67-201
    HostName 192.168.67.201
    Port 2222
    User git
    IdentityFile ~/.ssh/id_ed25519_gitlab
```

### 3.4 测试与克隆

```bash
ssh -T git@192.168.67.201
# 成功示例：Welcome to GitLab, @username!
```

首次连接会提示 host key，输入 `yes`；也可以预置：

```bash
ssh-keyscan -H 192.168.67.201 >> ~/.ssh/known_hosts
```

克隆：

```bash
git clone git@192.168.67.201:digitalsupply/platform-gitops.git
# 或使用 ~/.ssh/config 里的别名
git clone git@gitlab-192-168-67-201:digitalsupply/platform-gitops.git
```

如果使用 ssh-agent：

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519_gitlab
ssh-add -l
```

### 3.5 常见问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `Permission denied (publickey)` | 公钥没加到 GitLab / 用错 key / agent 没加载 | 检查 GitLab SSH Keys、`ssh -i`、`ssh-add -l` |
| `Host key verification failed` | known_hosts 没有该主机 | `ssh-keyscan` 或首次手动确认 |
| `Connection refused` | 端口不对 / SSH 未开 | 确认 22 或自定义端口 |
| `Please make sure you have the correct access rights` | 仓库路径/权限不对 | 核对 group/repo 和成员权限 |
| clone 时仍提示密码 | 用了 HTTPS URL | 改用 `git@host:group/repo.git` |

---

## 4. 方式三：Deploy Token / Project Access Token / CI Job Token

### 4.1 Deploy Token

位置：

```text
项目 → Settings → Repository → Deploy tokens
```

- 生成 username + token；
- scopes 选 `read_repository` / `write_repository`；
- 使用方式与 PAT 相同：

```bash
git clone http://<DEPLOY_TOKEN_USERNAME>:<DEPLOY_TOKEN>@192.168.67.201/digitalsupply/platform-gitops.git
```

适合：单仓库只读/读写自动化，不绑定个人账号。

### 4.2 Project / Group Access Token

位置：

```text
项目/组 → Settings → Access Tokens
```

- 生成一个 bot 用户；
- 可设置角色和 scopes；
- 适合多仓库自动化、长期服务账号。

### 4.3 CI Job Token

GitLab CI 内置：

```yaml
variables:
  GIT_STRATEGY: clone
```

在 Job 内可用 `CI_JOB_TOKEN` 拉取当前项目或允许的依赖项目。
不适合宿主机人工使用。

---

## 5. 本机实际采用的方法（真实记录）

### 5.1 现状

```bash
cd /root/gitops-p0
git remote -v
```

输出（token 已脱敏）：

```text
origin  http://root:<REDACTED>@192.168.67.201/digitalsupply/platform-gitops.git (fetch)
origin  http://root:<REDACTED>@192.168.67.201/digitalsupply/platform-gitops.git (push)
```

也就是说：

- 这个工作副本**之前已经克隆好**；
- remote 是 HTTPS；
- 用户名 `root`，密码是 GitLab PAT；
- 没有配置全局 credential helper，也没有 `.netrc`；
- token 直接存在 `.git/config` 的 remote URL 里。

### 5.2 实际执行的命令

```bash
cd /root/gitops-p0

# 1) 拉取远端最新
git fetch origin

# 2) 确认工作区状态
git status -sb

# 3) 修改文件并提交
git add platform/monitoring/values.yaml \
        platform/monitoring/README.md \
        platform/grafana/README.md
git commit -m "feat(monitoring): persist Ceph RBD storage values and migration runbook"

# 4) 推送
git push origin main
```

结果：

```text
18fa007 feat(monitoring): persist Ceph RBD storage values and migration runbook
15f6d43 docs(monitoring): record NFS cleanup after Ceph migration
```

`git ls-remote origin main` 返回：

```text
15f6d43...  refs/heads/main
```

说明 push 成功，token 至少具备 `write_repository` 权限。

### 5.3 为什么没有用 SSH

尝试：

```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=no -T git@192.168.67.201
```

结果：

```text
git@192.168.67.201: Permission denied (publickey).
```

本机检查：

- `~/.ssh/id_rsa` 存在，但**没有证据表明它已加到 GitLab**；
- `~/.ssh/config` 里没有 GitLab 的 Host 配置；
- `ssh-agent` 未运行（`Could not open a connection to your authentication agent`）；
- GitLab HTTP 登录页返回 200，网络可达。

所以没有走 SSH，而是复用已有 HTTPS remote。

### 5.4 这个方法的优缺点

| 优点 | 缺点 |
|---|---|
| 无需额外配置，立即可用 | token 明文存在 `.git/config` |
| 适合一次性/自动化操作 | token 会出现在 `ps`、history、日志 |
| push 权限直接生效 | token 泄露后影响整个账号权限 |
| 不依赖 SSH 端口/agent | 过期后需要手动更新 |

---

## 6. ArgoCD 的仓库凭据（独立组件）

ArgoCD **不使用**你本机的 `.git/config`。它有自己的 Repository Secret。

本机现状（只列元数据，不输出凭据）：

```text
Secret: platform-gitops-repo
  type: git
  url:  http://192.168.67.201/digitalsupply/platform-gitops.git
  username: present
  password: present
  sshPrivateKey: absent
```

检查命令：

```bash
kubectl -n argocd get secrets \
  -l argocd.argoproj.io/secret-type=repository

kubectl -n argocd get secret platform-gitops-repo \
  -o jsonpath='{.data.url}' | base64 -d; echo
```

### 6.1 HTTPS 方式注册仓库

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: platform-gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: http://192.168.67.201/digitalsupply/platform-gitops.git
  username: <USERNAME>
  password: <PAT>
```

### 6.2 SSH 方式注册仓库

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: platform-gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: git@192.168.67.201:digitalsupply/platform-gitops.git
  sshPrivateKey: |
    -----BEGIN OPENSSH PRIVATE KEY-----
    ...
    -----END OPENSSH PRIVATE KEY-----
```

### 6.3 验证

```bash
kubectl -n argocd get application platform-grafana \
  -o jsonpath='{.spec.source.repoURL}{"\n"}'

kubectl -n argocd get application platform-grafana \
  -o jsonpath='sync={.status.sync.status} health={.status.health.status}{"\n"}'
```

ArgoCD UI 也可以：

```text
Settings → Repositories → Connect Repo
```

注意：

- ArgoCD 建议用**只读**凭据（`read_repository` 即可）；
- 不要把个人 admin token 复用给 ArgoCD；
- 凭据建议放 Sealed Secret / Vault，而不是明文 YAML；
- ArgoCD 的 repo 凭据和你的 git CLI 凭据是两套，分别轮换。

---

## 7. 凭据选择决策表

| 需求 | 推荐凭据 | 备注 |
|---|---|---|
| 人工 clone/push | SSH key | 最省心，配合 ssh-agent |
| 临时脚本 clone | PAT | 设置过期时间 |
| 只读自动化 | Deploy Key / Deploy Token | 单仓库最小权限 |
| 多仓库机器人 | Group/Project Access Token | 独立 bot 账号 |
| ArgoCD 拉取 | Repository Secret + 只读 PAT/Deploy Key | 与个人凭据隔离 |
| GitLab CI 内拉依赖 | `CI_JOB_TOKEN` | 流水线内自动注入 |
| 内网自签 HTTPS | PAT + `http.sslCAInfo` | 不要用 `sslVerify=false` |

---

## 8. 常见错误速查

```text
Permission denied (publickey)
  → SSH 公钥没加到 GitLab / 用错 key / agent 未加载 / ~/.ssh/config 不对

Authentication failed
  → PAT 错、过期、scope 不够

remote: You are not allowed to push code to this project
  → 账号角色不够，或 main 是保护分支

fatal: could not read Username for 'http://...'
  → 非交互环境，没有 credential helper / .netrc / token URL

fatal: repository not found
  → URL 或 group/repo 路径错，或账号无权限

SSL certificate problem: unable to get local issuer certificate
  → 内网 CA 未信任：git config --global http.sslCAInfo /path/ca.crt

! [rejected] main -> main (non-fast-forward)
  → 远端有新提交：git pull --rebase origin main 再 push

remote: HTTP Basic: Access denied
  → 用了密码而不是 PAT，或 token 已被撤销
```

---

## 9. 安全检查清单

- [ ] 轮换当前 `.git/config` 里的明文 token（它已经在命令输出/日志中出现过）；
- [ ] 从 remote URL 移除 token：

```bash
git remote set-url origin http://192.168.67.201/digitalsupply/platform-gitops.git
```

- [ ] 改用 SSH key 或 credential helper；
- [ ] `chmod 600 ~/.ssh/id_*`、`~/.git-credentials`、`~/.netrc`；
- [ ] PAT 设置过期时间和最小 scope；
- [ ] 自动化使用独立 bot / Deploy Key，不用个人 admin token；
- [ ] ArgoCD 使用只读凭据，并存放在 Sealed Secret / Vault；
- [ ] 定期在 GitLab 审计 Access Tokens、Deploy Keys、Deploy Tokens；
- [ ] 不要把私钥、token、`.git-credentials` 提交到仓库。

---

## 10. 快速命令卡

```bash
# HTTPS + PAT（临时）
git clone http://<USER>:<TOKEN>@192.168.67.201/digitalsupply/platform-gitops.git

# HTTPS + credential helper
git config --global credential.helper store
git clone http://192.168.67.201/digitalsupply/platform-gitops.git
chmod 600 ~/.git-credentials

# SSH
ssh-keygen -t ed25519 -a 100 -C "root@teacher-gitlab" -f ~/.ssh/id_ed25519_gitlab
cat ~/.ssh/id_ed25519_gitlab.pub
# 加到 GitLab → Preferences → SSH Keys
ssh -T git@192.168.67.201
git clone git@192.168.67.201:digitalsupply/platform-gitops.git

# 已有工作副本
cd /root/gitops-p0
git remote -v
git fetch origin
git status -sb
git push origin main

# ArgoCD 仓库凭据检查
kubectl -n argocd get secrets -l argocd.argoproj.io/secret-type=repository
kubectl -n argocd get secret platform-gitops-repo -o jsonpath='{.data.url}' | base64 -d; echo

# 验证远端 HEAD
git ls-remote origin main
```

---

## 11. 本次操作的真实结论

1. 本机**没有**配置可用的 GitLab SSH key；`ssh -T git@192.168.67.201` 返回 `Permission denied (publickey)`。
2. 本机使用的是**已有工作副本 + HTTPS remote + 内嵌 PAT**，所以可以直接 `fetch/commit/push`。
3. push 成功说明该 token 至少有 `write_repository` 权限。
4. ArgoCD 侧使用独立的 `platform-gitops-repo` Secret（HTTPS + username/password），与 git CLI 凭据无关。
5. 当前 `.git/config` 中的明文 token 是安全风险，建议立即轮换并改用 SSH key 或 credential helper。
