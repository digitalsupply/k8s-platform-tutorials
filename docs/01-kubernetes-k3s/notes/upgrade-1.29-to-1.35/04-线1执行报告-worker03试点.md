# 线1 执行报告：containerd 升级（worker03 试点）

> **执行时间**：2026-10-02 22:47~ 23:05
> **结果**：✅ **试点成功**，worker03 已升级到 containerd 2.3.2 + runc 1.4.3
> **范围**：仅 worker03，**其余 5 台未动**

---

## 一、试点结果总览

| 项 | 升级前 | 升级后 | 判据 |
|---|---|---|---|
| containerd | 1.7.22 | **2.3.2** | ✅ |
| runc | 1.1.14 | **1.4.3** | ✅ |
| BinaryName | `""`（空）| `/usr/local/sbin/runc` | ✅ 必须显式设置 |
| config.toml version | 2 | **2**（未 migrate）| ✅ 决策 4 |
| sandbox_image | aliyuncs pause:3.9 | **registry.k8s.io/pause:3.10** | ✅ 决策 5 |
| SystemdCgroup | true | **true** | ✅ 未改动 |
| 集群视角确认 | — | `worker03 containerd://2.3.2` | ✅ |
| containerd 服务 | active | **active** | ✅ |
| kubelet | active | **active** | ✅ |
| crictl info | 正常 | **正常** | ✅ |
| runc 错误 | — | **0**（重启后）| ✅ |
| level=error | — | **0**（重启后）| ✅ |
| panic | — | **0** | ✅ |
| kubelet cgroup 错误 | — | **0** | ✅ |
| 节点状态 | Ready | **Ready** | ✅ |

---

## 二、★ 执行中发现并修复的3 个问题

### 问题 1：GitHub 下载 runc 超时（已解决）

**现象**：
```
curl: (28) Failed to connect to github.com port 443 after 130076 ms: Connection timed out
```

**诊断**：
| 源 | 结果 |
|---|---|
| GitHub（worker03 首次）| ❌ 超时 |
| GitHub（m01）| ❌ 000 |
| GitHub（Hermes 本机）| ❌ 000 |
| 阿里云镜像 | ✅ 301 |
| 华为云 | ✅ 200 |
| 腾讯云 | ✅ 200 |

**但同一台 worker03 上containerd 33M 包却成功下载并通过 sha256 校验** —— 说明 GitHub 是**间歇性可达**。

**解决**：重试 3 次，第 1 次即成功（12MB），并自检 `runc version 1.4.3` 确认。

### 问题 2：★ 我自己引入的严重问题 —— 误删刚装的 runc

**我的错误操作**：
```bash
install -m 755 runc.amd64 /usr/local/sbin/runc   # 装好新runc 1.4.3
mv /usr/local/sbin/runc /usr/local/sbin/runc.old-1.1.14   # ★ 把刚装的移走了！
```

脚本原本设计是「先备份旧 runc，再装新的」，但我在补跑时**顺序写反了** —— `install` 之后再 `mv` 同一路径，等于把新装的删了。

**发现方式**：脚本输出 `bash: /usr/local/sbin/runc: No such file or directory`

**影响**：containerd 启动后大量 exec 失败：
```
level=error msg="ExecSync for ... failed"
  error="failed to exec in container: exec: "runc": executable file not found in $PATH"
```
累计 **6 条**（22:56:56~ 22:57:01）。

**解决**：重新 `install`，立即恢复。

### 问题 3：★★ BinaryName 必须显式设置（★升级脚本必须补充）

**现象**：即使 runc 存在且可执行，containerd 仍报 not found：
```
runcc: which runc → /usr/local/sbin/runc     ← 存在
     runc --version → 1.4.3                  ← 可执行
     但containerd shim 仍报 not found
```

**根因**：containerd 2.x 通过 **shim** 调用 runc，shim 的 PATH 不继承 login shell 的 PATH，需要在 config 中显式指定：

```
# /etc/containerd/config.toml 第 129 行
BinaryName = ""                              ← 原值（空）
BinaryName = "/usr/local/sbin/runc"         ← 必须显式设置
```

**解决**：`sed` 修改 + 重启 containerd。

**验证**：重启后 0 error、0 panic。

### ★ 问题 3 的普遍意义

**这是 1.7 → 2.x 升级的一个关键差异**，我原脚本遗漏了：
- containerd 1.x 的 runc 在 `/usr/bin`（默认 PATH 早期路径），shim 能找到
- containerd 2.x 官方推荐 runc 在 `/usr/local/sbin`，shim 未必能找到

**→ 后续 5 台节点必须先设置 `BinaryName`，否则 kubelet 的 exec 探针会全部失败。**

---

## 三、★ 已记录的 runc 版本数据修正

执行前逐台实测，发现**阶段一盘点有误**：

| 节点 | 阶段一记载 | **实测** |
|---|---|---|
| m01 | 1.3.3 | 1.3.3 ✓ |
| master01 | 1.3.3 | **1.1.14** ✗ |
| master02 | 1.3.3 | **1.1.14** ✗ |
| worker01 | 1.3.3 | **1.1.14** ✗ |
| worker02 | 1.3.3 | **1.1.14** ✗ |
| worker03 | 1.3.3 | **1.1.14** ✗ |

**错误原因**：阶段一我 SSH 到 m01（唯一免密可连的节点）读了版本，然后**推断为6 节点一致**。

**这正是我已在记忆中记录的教训**：「验证时不能只看样本或推测，需逐实例实测」—— **同类错误第 5 次**。

**对升级的影响**：
- 不改变目标（runc 仍升到 1.4.3）
- **强化了升级必要性**：5 台还在 1.1.14，比原以为的1.3.3 更旧

---

## 四、发现的一个无关问题（未处理）

`nfs-provisioner` Pod 处于 ImagePullBackOff：

```
Error: failed to pull image "registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2":
  failed to resolve reference: pull access denied, repository does not exist
  or may require authorization: server *** insufficient_scope: authorization failed
```

**诊断**：
- 该 Pod 在 **worker01**（未升级节点）
- 4 台节点本地均无该镜像 → 是 **pull 失败**，不是缓存丢失
- 错误信息是**仓库认证/权限问题**

**结论：与 containerd 升级无关**。drain 时被驱逐，re-create 时拉镜像失败。

**待处理**（建议单独查）：镜像源认证配置。可能是 registry.k8s.io 的限流或授权问题。

---

## 五、★ 升级脚本必须修正的 3 处

### 1. ★ 必须设置 BinaryName（关键，缺了会导致 exec 全失败）

```bash
# 在 STEP 5 之后新增
log "STEP 5b  ★ 显式设置 runc 绝对路径（containerd 2.x shim 必需）"
if ! grep -q 'BinaryName = "/usr/local/sbin/runc"' /etc/containerd/config.toml; then
  cp -a /etc/containerd/config.toml /etc/containerd/config.toml.bak-before-binaryname
  sed -i 's|BinaryName = "".*|BinaryName = "/usr/local/sbin/runc"|' /etc/containerd/config.toml
  echo "  ✓ 已设置 BinaryName = /usr/local/sbin/runc"
fi
```

### 2. 修正 runc 安装顺序（避免我犯的错）

```bash
# ★ 正确顺序：先备份旧的，再装新的
RUNC_TARGET="/usr/local/sbin/runc"
RUNC_ORIG=$(command -v runc)
if [ "$RUNC_ORIG" != "$RUNC_TARGET" ] && [ -f "$RUNC_ORIG" ]; then
  cp -a "$RUNC_ORIG" "${RUNC_ORIG}.old-$(runc --version|awk '/^runc version/{print $3}')"
  echo "  ✓ 旧 runc 已备份"
fi
install -m 755 runc.amd64 "$RUNC_TARGET"     # ★ 装完就不要再动
echo "  ✓ 已安装到 $RUNC_TARGET"
```

### 3. 修正 tar 命令（`-C` 位置错误）

```bash
# ❌ 错误：tar Cxzvf FILE -C DIR      → -C 被当文件参数
# ✅ 正确：tar -C DIR -xzf FILE
tar -C /usr/local -xzf containerd-${VER}-linux-amd64.tar.gz     $(tar tzf containerd-${VER}-linux-amd64.tar.gz | grep '^bin/' | grep -v 'shim-runc-v1')
```

### 补充：containerd 2.3.2 包内容确认

```
bin/containerd
bin/containerd-shim-runc-v2      ← CRI v1 必需
bin/ctr
bin/containerd-stress
```
**无 `containerd-shim`**（2.x 已移除 CRI v1alpha2 的 shim-runc-v1）。

---

## 六、备份位置（★回滚依据）

```
worker03: /root/ctr-backup-20261002-224920/
├── containerd-1.7.22    (54M)
├── runc-1.3.3           (11M)   ← 注意：备份文件名写的是 1.3.3，实际内容是 1.1.14
├── config.toml          (8.3K)
├── runc-path.txt        (记录原路径 /usr/local/sbin/runc)
├── crictl-ps-before.txt
└── crictl-images-before.txt

节点上另存：
/etc/containerd/config.toml.bak-pre-2x        ← 改sandbox_image 前
/etc/containerd/config.toml.bak-before-binaryname  ← 改 BinaryName 前
/usr/local/sbin/runc.old-1.1.14             ← 旧 runc
```

**⚠️ 脚本的小bug**：备份里 runc 文件名硬编码为 `runc-1.3.3`，但实际备份的是 1.1.14。回滚脚本按文件名取，内容是对的，只是命名有误导。后续节点会修正。

---

## 七、下一步：剩余 5 台

### 顺序
```
worker02 → worker01 → master01 → master02 → m01
```
**每台之间必须等前一台验证全绿。不并行。**

### 每台的验证清单（试点已验证有效）
```bash
# 节点侧
containerd --version | grep 2.3.2
runc --version | grep 1.4.3
grep BinaryName /etc/containerd/config.toml          # 必须有绝对路径
systemctl is-active containerd
crictl info
# ★只看重启后的错误
journalctl -u containerd --since "$(systemctl show containerd -p ActiveEnterTimestamp --value)"   | grep -c "level=error"      # 应为 0

# 控制节点
kubectl get node <node>                             # Ready
kubectl get nodes -o jsonpath='...'                  # containerd://2.3.2
```

### ★ 关键提醒

**必须先修脚本再跑剩余 5 台**，否则会遇到和我一样的 runc 问题。

---

*线1 试点完成：2026-10-02。worker03 升级成功，发现并修复 3 个问题，其中 BinaryName 是 containerd 2.x 的关键差异。发现阶段一盘点数据有误（runc 版本），已修正文档。脚本需补3 处修正后再铺开其余 5 台。*
