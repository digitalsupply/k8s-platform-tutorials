# su 与 sudo：权限切换命令全解（含无密码 SSH 登录 + 直接进 root 的原理）

## 0. 一句话先记住

- **su** = "切换用户"，验证的是**目标用户的密码**（想变成 root？给 root 的密码）。
- **sudo** = "以他人身份执行命令"，验证的是**你自己的密码 + /etc/sudoers 授权表**。
- **SSH 密钥登录** = 公钥密码学验证，**跟账号有没有密码毫无关系**。

---

## 1. 命令总览表

| 命令 | 效果 | 需要谁的密码 | 环境变量 |
|------|------|--------------|----------|
| `su` | 切换到 root（等价 `su root`） | root 的密码 | 保留原环境，只换用户 |
| `su root` | 切换到 root | root 的密码 | 保留原环境 |
| `su -` | 切换到 root（登录壳） | root 的密码 | 全新登录环境 |
| `su - root` | 同上 | root 的密码 | 全新登录环境 |
| `su - user` | 切换到任意用户（登录壳） | user 的密码 | 全新登录环境 |
| `sudo 命令` | 以 root 执行单条命令 | **你自己的密码** | 继承当前环境 |
| `sudo -s` | 进入 root shell（非登录壳） | 自己密码 / 免密 | 保留当前环境 |
| `sudo -i` | 进入 root shell（**登录壳**） | 自己密码 / 免密 | 全新登录环境 |
| `sudo su` | 借 sudo 之力执行 su | 自己密码 / 免密 | 保留原环境 |
| `sudo su -` | sudo 版 `su -` | 自己密码 / 免密 | 全新登录环境 |
| `sudo -u user 命令` | 以指定用户执行命令 | 自己密码 / 免密 | 指定用户身份 |

---

## 2. su 系列详解

核心思想：**su 是"变成谁，就要谁的密码"**，纯密码验证，不看任何授权表。

### 2.1 `su` vs `su -`（最关键的区别）

```bash
su        # 或 su root：只换人，不换环境
su -      # 或 su - root：换人 + 换环境，等于"重新登录一遍"
```

- `su`：只切换 UID/GID。**PATH、HOME、USER、LOGNAME 等环境变量还是原来的**。所以经常出现"su 上去后 `ls`、`vim` 都不见了"，因为 PATH 还是非 root 的。
- `su -`：登录式 shell（login shell）。会清空原环境，重新读目标用户的 `/etc/profile`、`~/.bash_profile`、`~/.bashrc`，把 HOME、PATH 都换成目标用户的（root 默认 PATH 含 `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`）。

结论：想要"真正变回目标用户"，用 `su -`。

### 2.2 su 的其它细节
- `su - user`：登录式切换到任意用户，需要 user 的密码。
- `whoami` 在 su 前后会变，`echo $HOME` 在 `su` 下不变、在 `su -` 下改变。
- 不知道 root 密码 → su 永远失败，和你有多少权限无关。

---

## 3. sudo 系列详解

核心思想：**sudo 是"授权表 + 你自己的密码"**。系统根据 `/etc/sudoers` 决定你是否被允许、以谁的身份、是否免密。

### 3.1 常用形式

```bash
sudo whoami        # 输出 root：瞬时提权执行单条命令
sudo -s            # 进入 root 的非登录 shell（保留你当前环境）
sudo -i            # 进入 root 的登录 shell（模拟完整登录，环境全新）
sudo su            # 用 sudo 拿到 root 资格后再执行 su
sudo su -          # 用 sudo 拿资格 + 完整登录环境
sudo -u hao cmd    # 以 hao 的身份执行命令（不限于 root）
sudo -l            # 列出"我"被授权的 sudo 权限清单 / 查看有没有 NOPASSWD
```

### 3.2 `sudo -i` 与 `sudo -s` 的区别

| 命令 | 是登录壳吗 | 环境 | 典型表现 |
|------|-----------|------|----------|
| `sudo -s` | 否 | 保留当前环境 | `~` 还是你自己家目录 |
| `sudo -i` | **是**（等价 `su -`） | 全新登录环境 | `~` 变成 `/root`，PATH 是 root 的 |

`sudo -i` 内部行为大致等于：以 root 身份执行一次登录 → 读 `/root/.bash_profile` 等 → 得到全新 root 环境。这解释了为什么 `sudo -i` 后你的工作目录、PATH、HOME 都"变成 root 的样子"。

### 3.3 `sudo su` 为什么不用 root 密码？

因为链路是：`sudo` 已经替你完成了权限提升（验证的是你自己的密码/免密），再执行 `su` 时，当前进程已是 root，su 的"验证目标用户密码"这一步被绕过了。所以就出现了"我用 sudo su 没输入 root 密码也进了 root"，本质是 sudo 兜底，不是 su 放行。

---

## 4. 为什么 hao 能直接 `sudo -i` 进 root？

直接看 `/etc/sudoers` 里 hao 的授权行即可。典型两种情况：

### 情况 A：hao 属于 sudo / wheel 组
```bash
# Debian/Ubuntu 默认组：sudo；RHEL/CentOS 默认组：wheel
%sudo   ALL=(ALL:ALL) ALL
```
组内成员输入**自己的密码**（非 root 密码）即可 sudo（含 `sudo -i`）。

### 情况 B：hao 被授了 NOPASSWD（免密）—— 你观察到的"直接进"
```bash
hao ALL=(ALL) NOPASSWD: ALL
```
或整组免密：
```bash
%wheel ALL=(ALL) NOPASSWD: ALL
```
此时 hao 敲 `sudo -i` **连密码都不弹**，直接进 root 登录 shell。

### 4.1 sudoers 授权行格式解读
```
谁能用    可从哪些主机    可切换成(用户:组)     [标记:]   可执行命令
hao      ALL              (ALL:ALL)          NOPASSWD:  ALL
```
- 第 2 段 `ALL`：来源主机；
- `(ALL:ALL)`：可切换为任意用户、任意组；
- `NOPASSWD:`：执行时免输密码；
- 末尾 `ALL`：可执行任意命令。

如果去掉 `NOPASSWD:` 就是"要输自己的密码"；把命令写成 `/usr/bin/systemctl` 之类就是最小权限授权。

### 4.2 怎么查 hao 到底有什么权限
```bash
sudo -l                       # 关键命令：列出 hao 的 sudo 授权（会显示 NOPASSWD 字样）
groups hao                    # 看 hao 在不在 sudo / wheel 组
sudo cat /etc/sudoers         # 看主文件
sudo grep -R "hao" /etc/sudoers.d/
```

### 4.3 反直觉的"漏洞"：`sudo passwd` 直接设置 root 密码

普通用户只要**有 sudo 权限**，无需知道 root 密码就能给 root 设一个新密码：

```bash
sudo passwd          # 等价于以 root 身份执行 passwd
sudo passwd root     # 显式写清楚也是设置 root
```

原理：`passwd` 不带参数时，修改的是**当前调用者的密码**。而 `sudo` 让命令以 root 身份运行，所以 `sudo passwd` = "root 执行 passwd" = **修改 root 自己的密码**。而 root 改任意用户密码都不需要知道旧密码，所以连旧密码都不用输，直接 `New password:` 设新的就能生效。

> 这解释了为什么"授权 sudo 就等于授权 root"：只要有 sudo 权限，用户完全可以 `sudo passwd root` 改掉 root 密码，甚至 `sudo passwd -d root` 删掉 root 密码，从而彻底接管系统。这也是为什么生产环境不建议轻易分配 `ALL` 级别的 sudo，以及很多管理员会用 `!root` 锁定 root，同时记住"sudo 本身就能解锁 root"。

---

## 5. SSH 密钥登录：没有密码也能登录

### 5.1 为什么可以"无密码"

SSH 密钥登录走的是**非对称加密**，与系统账号密码完全独立：

1. 客户端持**私钥**（`~/.ssh/id_ed25519`、`id_rsa` 等），私钥永不外传；
2. 服务器持**公钥**，存放在目标用户家目录 `~/.ssh/authorized_keys`；
3. 登录握手：服务器发随机挑战 → 客户端用私钥签名 → 服务器用公钥验签 → 通过即放行。

换句话说，验证的不是"你知道密码吗"，而是"你手里有这把私钥吗"。所以哪怕 hao 在 `/etc/shadow` 里**没有密码 / 空密码 / 被锁定（`!` 或 `*`）**，只要 `~hao/.ssh/authorized_keys` 有对应公钥，就能 `ssh hao@主机` 直接登录。

### 5.2 密码认证与密钥认证是两条不同的通道
- 密码认证：由 sshd 的 PAM 走 `/etc/shadow` 验证口令（`PasswordAuthentication yes`）。
- 密钥认证：纯拜耳公钥验证（`PubkeyAuthentication yes`）。
- 服务器若配置 `PasswordAuthentication no`，密码登录直接关闭，密钥是唯一入口。

所以"能密钥登录"≠"有密码"，"没密码"≠"不能登录"。两者互不影响。

### 5.3 关注的权限细节
```bash
ls -la ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys     # 权限过宽会被 sshd 拒绝
```

---

## 6. 连成一条线：hao 为什么"没密码还能 sudo -i 进 root"

完整链路：

1. **登录**：hao 用 SSH 密钥进（与密码无关）；
2. **提权**：hao 在 sudoers 里有 `NOPASSWD: ALL`（或属于免密组）；
3. `sudo -i` 触发授权表检查放行 → PAM 无需密码 → 进入 root 登录 shell。

### 重要澄清（易误解处）
- "hao 没有系统密码" **不等于** "hao 能免密 sudo"。若 sudoers 没有 NOPASSWD，sudo 仍会要求密码；而**空密码用户通常无法通过 sudo 的密码验证**（PAM 对空密码一般直接拒绝）。能直接 `sudo -i` 进去，几乎必然是写了 `NOPASSWD`。
- "能密钥登录" **不等于** "能 sudo"。两件事分别由 `authorized_keys` 和 `sudoers` 决定，彼此独立。
- 换句话说：无密码账号 + 密钥登录 + NOPASSWD 授权，三者叠加，才出现了"甚至不用任何口令直接变 root"的现象。

---

## 7. 安全检查与建议

```bash
sudo -l                           # 自查：我有什么权限 / 是否免密
# 编辑 sudoers 一定要用 visudo（带语法检查），别直接 vi 改导致文件坏掉
sudo visudo
```

- 能 sudo 就别共享 root 密码：sudo 有完整审计日志（`/var/log/auth.log` / `/var/log/secure`），su 无日志。
- 慎用 `NOPASSWD: ALL`：等于为免密敞开大门；配合 2FA 或强密钥策略才建议。
- 生产环境建议 `PermitRootLogin no`，禁止 root 直接 SSH，统一走普通用户密钥登录 + sudo，全程可审计。
- 小心 /etc/sudoers 被改坏：一旦语法错误，所有人都无法提权，所以用 `visudo` 而不是直接改文件。

---

## 8. 附录：环境变量差异快速验证

```bash
# 场景：普通用户 hao 下执行
sudo su -c 'echo $HOME:$PATH'     # NON-login，$HOME 还是 /home/hao
sudo -i -c 'echo $HOME:$PATH'     # login，$HOME 是 /root，PATH 是 root 的
su -c 'echo $HOME'                # 需要 root 密码
```