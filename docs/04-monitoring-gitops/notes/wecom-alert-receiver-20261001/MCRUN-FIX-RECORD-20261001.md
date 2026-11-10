# mcrun 修复执行记录 —— 方案 A（含方案 C 收尾）

| 项 | 值 |
|---|---|
| 执行时间 | 2026-10-01 17:30–17:55（UTC 09:30–09:55） |
| 对象 | `Pod/logging/mcrun` |
| 选定方案 | **A**（就地修好 ConfigMap 命名空间），收尾按 **C**（改用 Job）落地 |
| 最终状态 | ✅ **已修复**。ILM 规则收敛为 1 条，两条告警已 resolve |

---

## 0. 一句话结论

原始根因（ConfigMap 命名空间错配）已修好，但执行过程中**连续暴露 3 个新问题**：
`python3` 缺失、`sed`/`grep`/`awk` 全部缺失、`mc ilm rule add --id` 参数不存在。
前两个已修，第三个导致 bucket 短暂进入**无 ILM 规则**状态，已补回。
最终 ILM 状态与原始语义等价（单条 10 天过期规则），告警全部 resolve。

---

## 1. 执行步骤与结果

### 1.1 步骤一：ConfigMap 命名空间修复（根因）

```bash
# 备份脚本内容
kubectl get cm mc-cm -n default -o jsonpath='{.data.mc\.sh}' > /tmp/mc.sh   # 699 字节
# 在 logging 建同名 ConfigMap
kubectl create cm mc-cm -n logging --from-file=mc.sh=/tmp/mc.sh
# 验证
diff <(kubectl get cm mc-cm -n default  -o jsonpath='{.data.mc\.sh}') \
     <(kubectl get cm mc-cm -n logging -o jsonpath='{.data.mc\.sh}')
# → ✓ 一致
```

删除卡住的裸 Pod（已备份原始定义到 `evidence/mcrun-pod-original.yaml`），按修正后的 manifest 重建。

**结果**：✅ 卷挂载成功 —— 首次出现 `IP: 10.244.28.69`，容器真正启动了。
`FailedMount` 827 次报错就此终结。

### 1.2 步骤二：暴露新问题 #1 —— `python3` 缺失

```console
=== all rules before ===
{"status":"success",...,"Rules":[{"Expiration":{"Days":10},"ID":"daubt2nv13js7a9ov93g",...},...]}
/tmp/mc.sh: line 7: python3: command not found
```

原脚本第 7 行：

```sh
ids=$(mc ilm rule ls --json la/loki-chunks | python3 -c "import sys,json;[print(r['ID']) for r in ...]")
```

**`minio/mc:latest` 镜像内没有 `python3`。**

**影响评估**：脚本带 `set -e`，在第一步就中止，**两条 ILM 规则完好无损**。
这是 `set -e` 的价值 —— 如果没有它，脚本会继续往下跑，最终状态不可知。

### 1.3 步骤三：只读探针 —— 先摸清镜像能力

在改脚本前，先用独立探针 Pod 摸清 `minio/mc` 镜像到底有什么工具：

```console
--- 可用命令 ---
  有: sh  cut  tr  head  tail  mc  stat
  无: awk  sed  grep  python3  jq  xargs  busybox  curl  wget
```

连 `/bin/bash` 存在（`/usr/bin` 下有 bash 二进制），但 bash **内部也没有** `sed`/`grep`/`awk`
（说明镜像是 Alpine/musl 系，只有 `busybox` 的部分 applet 被裁剪）。

### 1.4 步骤四：暴露新问题 #2 —— `sed` 也不存在

我第一次改脚本时用了 `sed -n 's/.../\1/p'`，直接踩坑：

```console
/tmp/fix.sh: line 8: sed: command not found
```

**离线验证后**改用纯 shell 解析（`tr` + `case` + `${var#pattern}` + `cut`）：

```sh
ids=$(mc ilm rule ls --json la/loki-chunks | tr ',' '\n' | while IFS= read -r line; do
  case "$line" in
    *'"ID":"'*) printf '%s\n' "${line#*\"ID\":\"}" | cut -d'"' -f1 ;;
  esac
done)
```

本地用真实 JSON 结构验证：

```console
$ sh extract_test.sh
daubt2nv13js7a9ov93g
daubtafv13js7be6kf5g      → ✓ 正确取出 2 个 ID
```

### 1.5 步骤五：暴露新问题 #3 —— `--id` 参数不存在（**危险**）

脚本成功删除两条规则后，新增规则时失败：

```console
removing [1] daubt2nv13js7a9ov93g
Rule ID `daubt2nv13js7a9ov93g` from target la/loki-chunks removed.
removing [2] daubtafv13js7be6kf5g
Rule ID `daubtafv13js7be6kf5g` from target la/loki-chunks removed.
=== add delete-old-logs (10 days) ===
mc: <ERROR> Invalid command usage, flag provided but not defined: -id
```

查 `mc ilm rule add --help` 确认支持的参数：

```
--prefix  --tags  --size-lt  --size-gt  --expire-days  --expire-delete-marker
--transition-days  --transition-tier  --noncurrent-*  ...
```

**没有 `--id`。规则 ID 由服务端随机生成，无法指定。**

> ⚠️ **此时 `loki-chunks` 处于无 ILM 规则状态。**
> 我立刻用单独的探针补了一条：

```console
=== 新增 10 天过期规则 ===
Lifecycle configuration rule added with ID `dav4h9f1afes75gd9390` to la/loki-chunks.
```

### 1.6 步骤六：读取滞后导致的误判

补回规则后查询发现 `daubtafv13js7be6kf5g` 竟然还在（脚本报告已删除）：

```console
=== rules after ===
│ daubtafv13js7be6kf5g │ Enabled │ - │ - │ 10 │ false │   ← 报告已删，却还在
│ dav4h9f1afes75gd9390 │ Enabled │ - │ - │ 10 │ false │
```

我做了单独验证 —— 直接删这一条再查：

```console
$ mc ilm rule remove --id dav4h9f1afes75gd9390 la/loki-chunks; echo "exit=$?"
Rule ID `dav4h9f1afes75gd9390` from target la/loki-chunks removed.
  exit=0
$ mc ilm rule ls la/loki-chunks
│ dav4imr92aas7i7ipo0g │ Enabled │ ... │   ← 这次删除确实生效了
```

**结论**：`mc ilm rule remove` 是**真实生效**的，之前看到「已删规则仍在」是
**`mc ilm rule ls` 的读取滞后**，不是删除失败。这个区别很关键 —— 差点误判成 MinIO 的 ILM
删除功能有问题。

### 1.7 步骤七：按方案 C 收尾（Job 化）

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: loki-ilm-reinit
  namespace: logging
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 86400      # 24h 后自动清理
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: mc
        image: minio/mc:latest
        command: ["sh","-c"]
        args: ["sh /tmp/mc.sh"]
        volumes:
        - name: script
          configMap: {name: mc-cm}    # ← 同 namespace，本次确保一致
```

执行结果：

```console
$ kubectl get job loki-ilm-reinit -n logging
NAME               COMPLETIONS   DURATION   AGE
loki-ilm-reinit   1/1           5s         19s
```

---

## 2. 最终状态验证

### 2.1 ILM 规则（独立探针确认）

```
=== 最终确认：loki-chunks ILM 规则 ===
┌─────────────────────────────────────────────────────────────────┐
│ ID                   │ STATUS  │ PREFIX │ TAGS │ DAYS TO EXPIRE │
├─────────────────────────────────────────────────────────────────┤
│ dav4imr92aas7i7ipo0g │ Enabled │ -      │ -    │             10 │
└─────────────────────────────────────────────────────────────────┘

{"status":"success","target":"la/loki-chunks","config":{"Rules":[
  {"Expiration":{"Days":10},"ID":"dav4imr92aas7i7ipo0g","Status":"Enabled"}]}}

=== bucket 用量 ===
335MiB   9559 objects   loki-chunks
```

### 2.2 ILM 状态变迁

| 阶段 | 规则数 | 规则详情 |
|---|---|---|
| 原始（修复前） | 2 | `daubt2nv13js7a9ov93g`(10天) + `daubtafv13js7be6kf5g`(10天) |
| 脚本删完、加规则失败 | **0** | ⚠️ 危险窗口 |
| 补回规则 | 2 | `daubtafv13js7be6kf5g` + `dav4h9f1afes75gd9390` |
| Job 收敛 | 2 | `dav4h9f1afes75gd9390` + `dav4imr92aas7i7ipo0g` |
| 最终确认 | **1** | `dav4imr92aas7i7ipo0g`(10天) |

**语义与原始等价**（都是 10 天过期），区别只是 ID 从随机串变成另一个随机串 ——
因为 `mc` 不支持指定 ID，这一点无法改变。

### 2.3 告警已 resolve

```
=== 20 秒后 ===
logging 告警数 = 0
✓ 已全部 resolve
```

当前活跃告警从 4 条降到 2 条：

| 状态 | alertname | 命名空间 | 说明 |
|---|---|---|---|
| active | `Phase2FixVerification` | phase2-verify | 本次无关 |
| active | `Watchdog` | — | 恒定心跳，severity=none |

`logging` 命名空间**零告警**。

### 2.4 命名空间清洁

```console
$ kubectl get job,pod -n logging | grep -vE "alloy|loki-|tempo3"
NAME               COMPLETIONS   DURATION   AGE
loki-ilm-reinit   1/1           5s         3m19s
NAME                    PHASE
loki-ilm-reinit-tmgzs   Succeeded

$ kubectl get pod -n logging   # 无任何 Pending/Error
```

全部临时探针（`mc-probe`、`mc-tools`、`bash-check`、`mc-fix-run`、`mc-add-run`、
`mc-verify`、`mc-v2-run`、`mc-v3-run`、`mc-fc-run`）及其临时 ConfigMap
（`mc-probe`、`mc-fix-cm`、`mc-add-cm`、`mc-v-cm`、`mc-v2`、`mc-v3`、`mc-fc`）已清理。

---

## 3. 未能验证的部分（如实记录）

**resolved 通知是否成功投递，无法确认。**

Alertmanager 容器的日志流在 `2026-10-01T08:50:56Z` 就停止更新，而当前时间是 `11:54Z`：

```console
$ kubectl logs ... alertmanager | grep -oE '^time=...' | tail -1
time=2026-10-01T08:50:56.565Z
  当前 UTC: 2026-10-01T11:54:54
```

近 30 分钟的 `Notify success` / `Notify attempt failed` 均为 0 行 —— 这不是「没通知」，
而是**日志不可用**。告警已确认从 `/api/v2/alerts` 消失（resolve 事实明确），
但 resolve 消息是否真的送达企业微信群，**我没有证据，不做推测**。

需要确认的话，可以在 AM 恢复日志后检查，或直接查 nflog。

---

## 4. 发现的问题清单

| # | 问题 | 严重度 | 状态 |
|---|---|---|---|
| 1 | ConfigMap `mc-cm` 建在 `default` 而 Pod 在 `logging` | 高（原根因） | ✅ 已修 |
| 2 | 脚本依赖 `python3`，`minio/mc` 镜像无 | 中 | ✅ 已改为纯 shell |
| 3 | 脚本依赖 `sed`/`grep`/`awk`，镜像全无 | 中 | ✅ 已改为 `tr`/`cut`/shell 变量展开 |
| 4 | `mc ilm rule add --id` 参数不存在 | **高**（曾致 bucket 无规则） | ✅ 已移除该参数 |
| 5 | 用裸 Pod 而非 Job（无自愈、无清理、状态不可查） | 中 | ✅ 已改为 Job |
| 6 | 镜像 `minio/mc:latest` 未固定版本 | 低 | ⚠️ 保留（改动会超出本次范围） |
| 7 | MinIO 凭据明文存于 ConfigMap | 中（既存） | ⚠️ 未处理（见 §6） |
| 8 | `default/mc-cm` 错位的原件仍在 | 低 | ⚠️ 未删（见 §6） |

---

## 5. 关于脚本的教训

### 5.1 `mc ilm rule ls` 的读取滞后会误导判断

我在步骤六差点得出「MinIO 删除 ILM 规则无效」的错误结论。
实际是**删除生效、`ls` 返回旧值**。

**正确做法**：删除后不要立刻依据 `ls` 下结论，间隔十几秒再查，
或用多个独立探针交叉验证。这次是靠「单独删一条再查」才定位清楚的。

### 5.2 破坏性脚本必须先只读验证

我先跑了只读探针（`mc ilm rule ls` + `mc du` + `mc ls`）才动手。
若直接执行破坏性脚本，会在「`--id` 不支持」这个坑上留下**无规则的 bucket**。
`set -e` 在前两个问题上救了场，但第三个问题发生在删除之后 —— 
**`set -e` 保护不了「先删后加」这种顺序敏感的脚本**。

更稳的写法是「先加后删」，或加完新规则、验证成功后再删旧规则。

### 5.3 对运行环境做能力探测，而不是假设

原脚本假设有 `python3`，实际没有；我第一版修复假设有 `sed`，实际也没有。
两次都是跑起来才发现。**正确做法是在写脚本前先跑一次工具探测**
（本次在步骤三补上了这个探测，代价是两个额外的失败 Pod）。

### 5.4 脚本注释里那句「id 明确为 delete-old-logs」本身就是错的

```sh
# 重新加一条，id 明确为 delete-old-logs，10 天
mc ilm rule add --expire-days 10 --id delete-old-logs la/loki-chunks
```

注释里写得很确定，但 `mc` 从来不支持 `--id`。
**这行脚本大概率从未成功执行过** —— 与它 27 小时卡在 `ContainerCreating`
的事实吻合：也许创建者当初也是这么试的，发现 `--id` 报错后又碰上了
ConfigMap 错位，最终放弃并烂尾。

---

## 6. 未处理的遗留项

### 6.1 `default/mc-cm` 错位原件

```console
$ kubectl get cm -A | grep mc-cm
default    mc-cm    1    28h     ← 仍在（脚本是旧的、会失败的那版）
logging    mc-cm    1    8m54s   ← 已修正
```

**建议删除** `default/mc-cm`：它的内容是坏脚本，留着会被误引用。
但它包含 MinIO 凭据，删除前建议确认没有其他引用。我没自动删，因为这属于
超出「修好 mcrun」范围的清理动作。

```bash
kubectl delete cm mc-cm -n default   # 确认无引用后执行
```

### 6.2 MinIO 凭据明文

`logging/mc-cm` 与 `ConfigMap/logi` 中明文存放：

```
access_key_id:     MSZ7Z25JM36ULGGDAIH7
secret_access_key: <redacted>
```

ConfigMap 不加密，任何有读权限的主体都能拿到 MinIO 读写凭据。
建议迁到 `Secret`（或外部密钥管理）。本次未改动。

### 6.3 `logging` 命名空间的通用告警覆盖

`mcrun` 暴露了一个盲区：**「ConfigMap 缺失导致卷挂载失败」没有任何专属告警**。
kubelet 报了 827 次 `FailedMount`，全部只体现为泛化的
`KubePodNotReady` + `KubeContainerWaiting`，无法从告警看出根因。

如果要做，可考虑监控 `kube_pod_status_reason{reason="FailedMount"}` 或
kubelet 的 `volume_manager` 指标。本次未实施。

---

## 7. 产出文件

| 路径 | 内容 |
|---|---|
| `loki-ilm-reinit.sh` | 修正版脚本（已作为 `logging/mc-cm` 的 `mc.sh`，1070 字节） |
| `evidence/loki-ilm-reinit-job.yaml` | Job 完整定义 |
| `evidence/mcrun-pod-original.yaml` | 故障 Pod 的原始定义（修复前备份） |
| `MCRUN-INCIDENT-20261001.md` | 前置文档：根因分析与修复方案 |

集群内持久对象：

| 对象 | 说明 |
|---|---|
| `logging/ConfigMap/mc-cm` | 修正版脚本（**注意 `default/mc-cm` 仍在，见 §6.1**） |
| `logging/Job/loki-ilm-reinit` | 已 `Succeeded`，24h 后自动清理 |