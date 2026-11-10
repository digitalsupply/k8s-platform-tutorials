# tempo3 → RGW 写入失败：根因、兼容层代理设计与待确认变更

> ## ⚠️ 本文档状态（2026-09-29 更新）
>
> **本问题已彻底根治，且根因结论已被后续证据推翻。**
>
> - 最终结论：缺陷在 **Ceph RGW 17.2.8 服务端**（0 字节 aws-chunked 终止块签名校验拿 seed 当签名比对），
>   **minio-go 客户端无责**（帧与签名逐字节合法）。quincy 分支永久无修复。
> - 根治动作：**Ceph 17.2.8 → 18.2.8 (reef) 全量升级**（三节点滚动，~40 分钟），修复位于 18.2.5+。
> - 兼容层代理（本文档 §3 的主角）**已退役删除**，自部署起从未接入流量。
> - 完整升级与验证证据见 **§12 诊断反转与根治**。§0–§11 为当时的过程记录，保留供参考。

- **报告时间**：2026-09-29
- **触发问题**：本轮排查中发现 `pg16-ceph-2` 频繁重启，修复过程中顺带发现 tempo3 的 trace block **完全无法落盘**，至今没有任何可查询的 trace
- **当前状态**：
  - PG 侧：**已修复完成**（§7）
  - S3 侧：根因已定位；兼容层代理**已部署但处于惰性状态**（无任何流量经过），tempo3 的写入配置**尚未改动**，线上行为与今天开始时完全一致
- **凭据指纹**（本报告不回显任何明文）：tempo-admin AK = `5f3d45561ed2`，SK = `1545d6ac455a`
- **备份目录**：`/root/observability-upgrade-backup-20260929-111055-pg-s3-incident/`

---

## 0. 一句话回答「为什么要多一个 Deployment、还要改第 206 行」

tempo3 3.0.3 自带的 S3 客户端在上传**恰好 0 字节**的对象时，发出的 HTTP 请求体在协议层就是非法的，Ceph RGW 必然拒绝。而 `nocompact.flg` 这个 block 标记文件**永远是 0 字节**，所以它 100% 失败，导致整个 block 永远写不完、`meta.json` 永远不生成、block 永远进不了 blocklist。

这个缺陷**在 tempo 侧无法用配置绕过**（§2.4），**也无法通过换镜像解决**（§2.5）。
唯一不动 tempo 二进制、不动 RGW 的办法，是在 tempo3 和 RGW 中间插一层**只修这一个请求、其余全部原样透传**的代理 —— 这就是 `Deployment/tempo3-s3-compat` 的来历。

而改第 206 行，是**把 tempo3 的写入地址从 RGW 指向这层代理**。两者必须配套：只有代理没有改指向 = 代理空转；只有改指向没有代理 = tempo3 全部写入失败。

---

## 1. 发现的现象

### 1.1 日志（截取自 `tempo3-block-builder-2`，仍在持续发生）

```
level=error ts=2026-09-29T06:46:19.750969221Z caller=blockbuilder.go:239
  msg="consumeCycle failed"
  err="error copying block from local to remote backend: error writing object to s3 backend,
       object single-tenant/ffb96215-e286-5b9b-a82d-64e6cceff80c/nocompact.flg:
       The provided 'x-amz-content-sha256' header does not match what was computed."

level=info ts=2026-09-29T06:46:29.760555021Z caller=partition_writer.go:99
  msg="flushing tenant" tenant=single-tenant
```

关键点：**`consumeCycle failed` → 整个 flush 循环中断 → 同一个 block 10 秒后从头重来**。

### 1.2 量化影响

| 指标 | 数值 | 说明 |
|---|---|---|
| 失败速率 | ~428 次 PUT/分 | 抓包 75 秒内 535 次 |
| `tempo_ingest_storage_reader_read_errors_total` | bb-0 = **131409**<br>bb-2 = **7052** | 仍在增长（起始时 45134 / 5860） |
| `ALERTS{Tempo3BlockFlushFailing}` | **firing** on `tempo3-block-builder-0` | 告警正确触发 |
| 桶内 `meta.json` 数量 | **0** | block 从未进入 blocklist |
| 可查询 trace block | **0 个** | |
| 桶内对象数 | 9 个（无 `meta.json`） | |

> 该指标名 `tempo_ingest_storage_reader_read_errors_total` 名不副实，实为 S3 **写**失败计数。`tempo_live_store_local_*` 系列全为 0，若只看它们会误判成「没有失败」。

### 1.3 为什么只有 1 个对象失败，其它 3 个成功

一个 block 目录写 4 个对象，只有 `nocompact.flg` 失败：

| 对象 | 大小 | 结果 |
|---|---|---|
| `bloom-0` | 102424 字节 | ✅ 成功 |
| `data.parquet` | 29780 字节 | ✅ 成功 |
| `index` | 42 字节 | ✅ 成功 |
| **`nocompact.flg`** | **0 字节** | ❌ **必然失败** |

`nocompact.flg` 语义上就是「本 block 未压缩」的**空标记文件**，永远是 0 字节。
→ **触发条件是「对象大小为 0」，与 trace 内容、block 大小、租户都无关。**

> 顺带：另 3 个对象虽成功，但被反复重传（7 次/秒量级），是纯粹的**写放大浪费**，不是数据丢失。

---

## 2. 根因

### 2.1 逐层排除（全部为实测，非推断）

| 怀疑项 | 排除方式 | 结论 |
|---|---|---|
| 凭据错误 | 同 key `aws s3api list/put/head/multipart` | 全部 200 ✅ |
| 权限不足 | 同上，含 0 字节与 multipart | 全部 200 ✅ |
| 端点不可达 | 直连 `10.0.0.31:7480` 正常 | ✅ |
| 桶策略限制 | `put-object` 0 字节可写 | ✅ |
| RGW 版本缺陷 | aws-cli 写 0 字节对象成功 | RGW 无问题 ✅ |
| 配额/容量 | WAL、桶容量均无压力 | ✅ |

**→ 不是配置问题、不是权限问题、不是 RGW 问题。是 tempo 客户端发出的字节本身非法。**

### 2.2 抓包逐字节证据

抓取 tempo3 → RGW 的真实 TCP 流，按 seq 重组，还原出的请求体**原样 97 字节**：

```python
b'56\r\n0;chunk-signature=60f6ed4f109cebb35f7e5206048b2720376cb989217655151adfe8934089dfb5\r\n\r\n\r\n0\r\n\r\n'
```

对照 AWS 流式签名 v4（`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`）要求的合法结构：

| # | 位置 | 实际字节 | 问题 |
|---|---|---|---|
| 1 | 首个 chunk 长度头 | `56\r\n`（**裸长度，无 `;chunk-signature=`**） | ❌ 签名缺失 |
| 2 | 紧随其后的 86 字节 | `0;chunk-signature=60f6ed4f...\r\n` | ❌ **这是「终止块的签名行」，被当成了数据块的载荷** |
| 3 | 之后 | `\r\n0\r\n\r\n` | ✅ 这才是真正的终止块 |
| 4 | 请求头 | `X-Amz-Decoded-Content-Length: 0` | ❌ 声明载荷长度为 0 |

客户端信息：`UA = MinIO (linux; amd64) minio-go/v7.0.98`（tempo 3.0.3 内置）

**矛盾点**：请求头声明载荷 **0 字节**，但 RGW 按 HTTP 分帧实际读到的数据算出的是 **86 字节**。
→ 两者不一致 → RGW 返回 `XAmzContentSHA256Mismatch`。

### 2.3 为什么「重帧」修不好 → 必须重新签名

我实测了 3 种「不改签名、只重组字节」的修法：

| 变体 | 结果 |
|---|---|
| 剥离 `56\r\n`，把终止块签名行还原成真正的终止块 | ❌ 400 `XAmzContentSHA256Mismatch` |
| 剥离 `56\r\n`，整段丢弃签名行，只发 `0\r\n\r\n` | ❌ 400 `XAmzContentSHA256Mismatch` |
| 保留原有 `chunk-signature` 不动 | ❌ 400 `XAmzContentSHA256Mismatch` |

**3/3 全部失败。** 原因：那 86 字节的 chunk 签名**本身就是按「这 86 字节是数据」算出来的**。
只要数据还对不上，签名就对不上。**在客户端侧无解，必须重新签名。**

### 2.4 为什么不能用配置绕过

| 尝试 | 结果 |
|---|---|
| `s3.Config` 是否有 `signature_version2` 字段 | ❌ **该字段不存在**（离线 `tempo -config.verify` 证伪） |
| `tempo.yaml` 全文搜索关闭流式签名的开关 | ❌ 无任何相关配置项 |
| RGW 侧放宽校验 | ❌ 需要改 Ceph 服务端配置，风险远大于问题本身 |

### 2.5 为什么不能升级镜像

```
docker.io / registry-1.docker.io  →  HTTP 000（不可达）
quay.io / ghcr.io                →  HTTP 401
```

**集群无外网。** 无法拉取修复了此缺陷的 tempo 镜像。

### 2.6 结论

> **【2026-09-29 已由后续升级推翻】** 本表基于 17.2.8 环境、且当时误判为"minio-go 帧畸形"写出。
> 诊断反转后证实缺陷在 RGW 服务端、且 quincy 分支永远无修复；最终通过 Ceph 大版本升级
> （17.2.8 → 18.2.8 reef）根治，代理退役。详见 §12。

| 路径 | 可行性（17.2.8 当时） |
|---|---|
| 改 RGW 配置 | ❌ 需改 Ceph 服务端（无开关，源码确认） |
| 改 tempo 配置 | ❌ 无可用开关 |
| 升级 tempo 镜像 | ❌ 当时无外网（与本次无关） |
| **中间加兼容层代理** | ✅ **当时唯一可行（已退役）** |

---

## 3. `Deployment/tempo3-s3-compat` 是什么

### 3.1 设计原则

> **只修那一个请求，其余全部逐字节原样透传。**

代理**不缓存、不合并、不重排、不改写响应体内容**。它是纯转发层，唯一的行为分歧就是「0 字节 PUT」。

### 3.2 触发条件（三个条件必须同时满足，`proxy.py:201 needs_fix()`）

```python
def needs_fix(method, headers):
    if method != "PUT":                                    return False
    if "chunked" not in (headers.get("Transfer-Encoding") or "").lower(): return False
    v = headers.get("X-Amz-Decoded-Content-Length")
    if v is None:                                          return False
    try:    return int(v.strip()) == 0
    except ValueError:                                     return False
```

判定条件来自实际抓包，**不是猜测**。tempo3 只有 0 字节 PUT 会命中。

### 3.3 命中后的处理

1. 完整读掉畸形 body（解析 chunked 分帧，仅用于消费字节）
2. **丢弃**该 body
3. 剔除全部原签名相关头（`Authorization`、`Date`、所有 `x-amz-*`）
4. 改用 **SigV2** 重新签名
5. 以 `Content-Length: 0` 发送空 body

### 3.4 为什么用 SigV2 而不是 SigV4

- SigV4 的流式分块签名链实现复杂、易错（我此前手写 SigV4 连续两次 403 `SignatureDoesNotMatch`）
- SigV2 只是一次 **HMAC-SHA1**，逻辑简单可穷举验证
- **已实测本 RGW 接受同一凭据的 SigV2 请求**（0 字节 put 返回 ETag `d41d8cd9…`）

### 3.5 透传保证

- 非目标请求**不修改任何字节、不重新签名**
- `Host` 头原样保留（SigV4 对 host 参与签名，动了必然 403）
- 唯一允许的转换：chunked 响应体 → 等价 `Content-Length` 分帧（**字节内容不变**）
- `HEAD` 响应的 `Content-Length` 保留上游原值（见 §6 纠错 #2）
- 凭据只从环境变量读取，**日志中只打印 AK 的 SHA256 前 12 位**

### 3.6 源码与资源清单

源码：`proxy.py`，**352 行**，Python 3 标准库，零第三方依赖
线上副本与本地 SHA256 一致：`4e4c25e3c98a616156af288d81ea83305edb5f3f662d2d276f97de6141a63fa3`

| 资源 | 规格 |
|---|---|
| `ConfigMap/tempo3-s3-compat` | 挂载 `proxy.py`（11290 字节），只读 |
| `Secret/tempo3-s3-compat-creds` | `S3_ACCESS_KEY` / `S3_SECRET_KEY`（复用 tempo3 同一凭据） |
| `Service/tempo3-s3-compat` | ClusterIP `10.103.93.45:7481` |
| `Deployment/tempo3-s3-compat` | replicas=1，镜像 `10.0.0.41/library/python:3.11-slim`（**内部镜像源，离线可用**） |

安全上下文：`runAsNonRoot=true`、`runAsUser=65534`、`readOnlyRootFilesystem=true`、`drop ALL capabilities`
资源：`requests 20m/48Mi`，`limits 300m/128Mi`
探针：readiness + liveness（tcpSocket/7481）

### 3.7 镜像选择依据

无外网环境下逐个实测：

| 候选 | 结果 |
|---|---|
| `10.0.0.41/library/python:3.11-slim` | ✅ **stdlib 齐全，集群在用，内部源** |
| `python:3-alpine` | ✅ 可用（3.14.7） |
| `nicolaka/netshoot` | ✅ 可用（3.14.5），但镜像过大 |

选内部源镜像，离线可靠性最高。

> **【2026-09-29 已退役】** 兼容层代理已于 Ceph 升级到 18.2.8 后退役删除（Deployment/Service/CM/Secret 四件套全部移除，备份存于
> `/root/observability-upgrade-backup-20260929-111055-pg-s3-incident/manifests/`）。
> 代理自部署起从未接入流量（tempo3 始终直连 `10.0.0.31:7480`），RGW 服务端缺陷根除后它失去存在意义。
> 详细过程见 §12「诊断反转与根治」。本段留存仅为记录代理设计时的技术选型。

---

## 4. 为什么要改 `tempo3-config` 第 206 行

**这是把 tempo3 的写入地址从 RGW 切到代理。两者必须配套。**

`ConfigMap/logging/tempo3-config` → `data['tempo.yaml']` 第 206 行，缩进感知定位（避免误改其它 `endpoint`）：

```diff
@@ -203,7 +203,7 @@
     s3:
       access_key: <REDACTED>
       bucket: tempo-traces
-      endpoint: 10.0.0.31:7480
+      endpoint: http://tempo3-s3-compat.logging.svc.cluster.local:7481
       forcepathstyle: true
       insecure: true
       region: us-east-1
```

**变更行数 = 1。** 已用 YAML parser 复核结构完好（`backend`/`bucket`/`forcepathstyle`/`insecure`/凭据字段均未受影响）。

为什么用 Service DNS 而不是 Pod IP：滚动更新时 Pod IP 会漂移，Service ClusterIP 稳定。已实测从 `logging` ns 内 Pod 解析该 DNS → `10.103.93.45` 且 7481 端口可连。

---

## 5. 验证结果

全部测试目标为 **Service ClusterIP**（避免 Pod IP 漂移），并在每轮前后比对代理计数器，**确认流量确实经过代理**后才采信结论。

### 5.1 签名器单测

| 用例 | 结果 |
|---|---|
| 0 字节对象 | ✅ 200 |
| 0 字节 + Content-Type | ✅ 200 |
| 16 字节对象 | ✅ 200 |
| 真实目标 key `.../nocompact.flg` | ✅ 200，ETag `d41d8cd9…` |

### 5.2 端到端

| 编号 | 测试 | 结果 |
|---|---|---|
| **A** | **抓包还原的真实畸形请求** | 直连 RGW = **400 `XAmzContentSHA256Mismatch`**<br>经代理 = **200 OK** ✅ |
| B1 | HEAD 静态对象（70KB） | `ContentLength` / `ETag` / `ContentType` 与直连**完全一致** ✅ |
| B2 | GET 大对象逐字节 | 原始 / 直连 / 经代理 md5 **三方一致** ✅ |
| B3 | 列举（list-objects-v2） | 9 个对象，key/size/etag **完全一致** ✅ |
| D | multipart 全流程 | create + 5MB part1 + 3MB part2 + complete + **8MB 回读逐字节一致** ✅ |
| E | 0 字节 PUT / DELETE 透传 | ✅ |
| F | 错误响应保真 | 不存在的 key，代理与直连返回**相同状态码** ✅ |

### 5.3 并发压力

| 场景 | 结果 |
|---|---|
| 30 线程齐发 × 180 | 180/180 成功，0 异常，145 req/s |
| 30 线程 × 300（每次间隔 20ms，贴近实际） | 300/300 成功，0 异常，141 req/s |
| 60 线程 × 600（2 倍实际负载） | 600/600 成功，0 异常，137 req/s |

**吞吐余量**：实测 ~140 req/s vs tempo3 实际 7 req/s = **20×**

### 5.4 代理运行计数

```
[tempo3-s3-compat] start listen=:7481 upstream=10.0.0.31:7480 ak=5f3d45561ed2...
[tempo3-s3-compat] stats fix=1261 pass=16 err=0
```

`err=0`。启动日志只含 AK 指纹，无明文。

### 5.5 副作用检查

| 项 | 状态 |
|---|---|
| 桶内对象数 | **9**（与变更前完全一致） |
| 未完成 multipart upload | **0**（我的测试残留已全部 abort） |
| 探针对象 | 全部已删（`.lgmt-*` 前缀） |
| `nocompact.flg` | 仍为 **0 字节**，未被测试污染 |

---

## 6. 本轮自检纠错记录

> 全部是**我自己的测量工具或代码出错**，不是系统故障。逐条记录以免重犯。

| # | 错误 | 真相 | 教训 |
|---|---|---|---|
| 1 | 代理「无响应」（DELETE 连接超时、计数全 0） | 我用了 `.items[0].status.podIP`，滚动更新期间取到**正在终止的旧 Pod**（`10.244.19.72`），真实地址已是 `10.244.19.92` | 测试目标要用 **Service ClusterIP**，不能用 Pod IP |
| 2 | HEAD 响应 `Content-Length = 0` | **代理的真 bug**（我覆盖了上游原值）。HEAD 的 Content-Length 应描述 GET 将返回的长度 | 已修（`proxy.py:313-319`）。**这条是真缺陷，不是工具问题** |
| 3 | 代理返回 411 `MissingContentLength` | **代理的真 bug**：改写分支漏加 `Content-Length: 0`（只在透传分支加了） | 已修 |
| 4 | multipart `complete` 失败 | 我的 shell 把 JSON 的 `\"` 转义弄坏，`Invalid JSON: column 21` | JSON 参数走文件 `--multipart-upload file://`，不用行内拼接 |
| 5 | `create-multipart-upload` 报「失败」 | UploadId `2~KYNpKlb…` **是合法的**，我的校验正则漏了 `~` 字符 | 校验别用猜测的正则 |
| 6 | 「200 次里只成功 180 次」 | `200 // 30 = 6`，实际只发了 180 次，**180 全成功** | 标称次数 ≠ 实际次数 |
| 7 | 代理「丢请求」 | 我的 worker 线程没做异常捕获，连接层报错会静默死线程。补上异常取证后 180/180、300/300、600/600 全通过 | 压测必须捕获并统计异常 |
| 8 | `length(Uploads)` 返回空 | RGW 空结果时**省略** `Uploads` 字段，`--query` 取不到值。**不代表桶里有东西** | 空 ≠ 有；用 JSON 直读核实 |
| 9 | `abort-multipart-upload` 全部失败 | `--output text` 的列被 `awk` 错位（把 UploadId 当成了 Key） | 结构化输出用 JSON + parser，别用 awk 猜列序 |
| 10 | SigV2 首次全部 403 | 我把 `canonical_resource` 的**前导斜杠 `lstrip("/")` 掉了**，AWS SigV2 要求保留 | 签名失败先怀疑自己的实现 |
| 11 | YAML 定位「未定位到 s3.endpoint」 | 在 `s3:` 块内遇到 `access_key:` 这类新键就 `break`，而它排在 `endpoint` 之前 | 定位嵌套块必须**缩进感知** |
| 12 | **把 ConfigMap 里的 AK/SK 明文打印到了终端** | 我的取证命令直接输出了 190-215 行原文 | 违反脱敏要求。已在后续所有输出加 `REDACTED` 过滤 |
| 13 | `pg_stat_replication` 查询为空 | 我在**副本** `pg16-ceph-4` 上查复制状态 | 复制状态要在**主库**上查 |
| 14 | `pg_relation_size('pg_xact/0000')` 报错 | `pg_xact/0000` 是文件不是 relation；`pg_stat_file` 的路径是 `global/` 不是 `base/` | 文件大小直接读文件系统最省事 |
| 15 | Prometheus 计数器查询无返回 | 我的 Service 名过滤器挑中了 `prometheus-alertmanager` 而非 `prometheus-prometheus`(10.111.41.17) | 已知端点就用已知值，别用模式猜 |

---

## 7. 另一项：PG 修复（已完成）

### 7.1 根因

`pg16-ceph-2` 数据卷的事务状态段被**截断为 0 字节**：

| 实例 | `pg_xact/0000` 大小 | 后果 |
|---|---|---|
| `pg16-ceph-2`（故障） | **0 字节** | `could not access status of transaction 3047` / `invalid record length at 1/A30000A0: expected at least 24, got 0` → startup 进程 exit 1 → 崩溃循环，restarts=110 |
| `pg16-ceph-3`（健康） | 8192 字节 | 正常 |
| `pg16-ceph-4`（重建后） | 8192 字节 | 正常 |

最后完整数据停在 **2026-06-18 09:10**，HA 缺失 103 天。
`base/` 的 mtime（`May 9 11:31`）与 `pg16-ceph-3` 创建时刻一致 → 该卷由 pg-3 克隆而来。

### 7.2 处置

1. 归档故障实例 pgdata（46,735,360 字节）留证 —— 内含 0 字节的 `pg_xact/0000`，是根因的实物证据
2. 删除 `pg16-ceph-2` + `pg16-ceph-2-wal` 两个 PVC 与 Pod
3. CNPG 自动 `pg_basebackup` 重建为 **`pg16-ceph-4`**（刻意避开复用 `-2` 名字）

### 7.3 验证

| 检查项 | 结果 |
|---|---|
| `pg_stat_replication`（主库上查） | `pg16-ceph-4  streaming  async  sent_lsn == replay_lsn` ✅ |
| 复制槽 | `_cnpg_pg16_ceph_4  active=true` ✅ |
| 角色 | pg-3 = 主（`in_recovery=f`），pg-4 = 副本（`in_recovery=t`）✅ |
| 重启次数 | pg-3 = 6（142 天历史），**pg-4 = 0** ✅ |
| `pg_xact/0000` | 8192 字节 ✅ |
| 数据库完整性 | `mytest`, `n8n`, `postgres` 三库齐全 ✅ |
| n8n | 库可连，20+ 张业务表在位（owner `n8nuser`）✅ 未受牵连 |

> n8n 依赖本集群（`DB_POSTGRESDB_HOST=pg16-ceph-rw.cnpg-system.svc.cluster.local`），因此修复期间优先保证该库可用。

---

## 8. 尚未执行的变更（等待确认）

> **【2026-09-29 已取消】** 本节的 endpoint 翻转与代理方案已随 Ceph 升级根治**作废**。
> 代理四件套已删除，`tempo3-config` 保持直连 `10.0.0.31:7480` 不变。表格留档仅供参考。

| 状态（当时） | 项 |
|---|---|
| ✅ 曾落线（惰性，无流量） | ConfigMap / Secret / Service / Deployment（**已全部删除**） |
| ✅ 已备份 | `pre-state/tempo3-config-PREFLIP.yaml`（回滚源，不再需要） |
| ⛔ **未执行（永久取消）** | `tempo3-config` 第 206 行 endpoint 变更 |

---

## 9. 风险与回滚

### 9.1 风险

| # | 风险 | 说明 | 缓解 |
|---|---|---|---|
| 1 | **代理是写入路径单点** | 代理挂则 block 落盘停摆（等同现状） | 建议 `replicas: 2`（代理无状态，安全）；待你定 |
| 2 | **未做真实 minio-go 端到端验证** | 无外网、tempo 镜像无 shell，无法起同版本实例 | 用抓包重放 + aws-cli 代替；翻转后立即盯计数器 |
| 3 | **配置变更触发 tempo3 全栈滚动重启** | block-builder 正在处理的 in-progress block 会丢弃 | 那些 block 本来也落不了盘，无实际损失 |
| 4 | 代理每请求新建上游连接 | 当前负载无压力（428 req/min） | 实测 20× 余量 |
| 5 | `readOnlyRootFilesystem` + 非 root | Python 可能需写临时文件 | 实测稳定运行 3h+，无异常 |

### 9.2 回滚

```bash
# 恢复到直连 RGW（即当前状态，回到失败循环）
kubectl apply -f /root/observability-upgrade-backup-20260929-111055-pg-s3-incident/pre-state/tempo3-config-PREFLIP.json
```

代理本身可独立删除，删除前需先执行上述回滚（否则 tempo3 写入全部失败）：
```bash
kubectl delete -n logging deploy/tempo3-s3-compat svc/tempo3-s3-compat \
  cm/tempo3-s3-compat secret/tempo3-s3-compat-creds
```

---

## 10. 翻转后的验证清单

1. `nocompact.flg` PUT 返回 200（代理 `fix` 计数持续增长）
2. 桶内出现 `meta.json`（**这是 block 落盘成功的决定性标志**）
3. `tempo_ingest_storage_reader_read_errors_total` 停止增长
4. `Tempo3BlockFlushFailing` 告警恢复
5. Grafana Trace 面板能查到实际 trace
6. 代理 `err` 保持 0

---

## 11. 遗留事项

| 优先级 | 事项 |
|---|---|
| P1 | ~~补 `pg16-ceph` 监控~~：`cnpg-system` namespace 当前**零告警**，103 天静默与本次故障同源（仍未解决） |
| ~~P1~~ | ~~`Tempo3BlockFlushFailing` 持续 firing~~：已随 Ceph 升级根治，无告警 |
| P2 | tempo 3.0.3 升级到含 minio-go 修复的版本（需先解决外网出口问题） |
| P2 | `pg16-ceph` 无 Backup / ScheduledBackup（无 barman，无 externalClusters） |
| ~~P3~~ | ~~评估为 RGW 加统一的 S3 兼容层~~：已随升级退役，无需再评估 |

---

## 12. 诊断反转与根治（2026-09-29）

### 12.1 诊断反转：缺陷在 RGW 服务端，不在 minio-go

本报告最初章节（§2、§3）基于 17.2.8 环境写成，其中"minio-go 帧畸形"的结论**已被证据推翻**：

| 项 | 旧结论（已推翻） | 新结论（已证实） |
|---|---|---|
| 断言对象 | minio-go v7.0.98 发的帧"畸形" | **无责**。双层分帧（HTTP chunked 包 aws-chunked）逐字节合法；与 aws-cli ground truth 签名逐一比对一致 |
| 失败断言 | 服务端拒绝"非法请求" | 服务端**(合法空载荷也被拒)**——缺陷在 RGW 17.2.8 |
| 根因机制 | — | `AWSv4ComplMulti` 校验终止块时拿的是 **seed 签名**（从未被更新），而非新算出的终止块签名 → 必然不等 → 400 `XAmzContentSHA256Mismatch` |
| 定性 | 客户端可规避 | **客户端无解**：2×2 判别矩阵（0B/100B × 终止块签名规则 A/B/C）证明 0 字节时 RGW 全部 400，非空全部 200，与签名算法无关 |

### 12.2 上游修复归属

- `calc_chunk_signature` / `complete()` 逻辑在 **v17.2.8 / v18.2.0 / v19.2.0 三版本的源码逐字节一致**（都是拿 payload_hash 硬塞第 6 字段）→ 新版本不一定修，必须比对源码而非看版本号。
- 修复只存在于 **v18.2.5+ 与 v19.2.0+**（`complete()` 中新增"消费最终 0 长度块签名与 trailer 区"逻辑；上游注释原文为 *"historically, this code has been validating not the final zero-length chunk, but the one before that…"*）。
- quincy 17.2.8 是全分支最终版本（quay.io tag 即 `a0f373aaaf5a5ca5`），EOL 无修复。
- 跳版本核对结论：即便是 18.2.0/18.2.4 也**没有**修复；最低修复版本 = **18.2.5**。

### 12.3 升级执行（17.2.8 → 18.2.8 reef）

三节点（10.0.0.31/41/51）cephadm 滚动升级，约 40 分钟：

1. **前置**：HEALTH_OK、465 PG 全 active+clean、全部池 size=3 min_size=2、cephadm 可用、目标镜像三节点可达、`ceph orch upgrade check` rc=0。
2. **备份**：monmap / crushmap / config / orch export / 版本快照 → `/root/observability-upgrade-backup-20260929-154623/ceph-upgrade/`（11 文件）。
3. **执行**：`ceph orch upgrade start --image quay.io/ceph/ceph:v18.2.8`。
4. **途中异常**：ceph-03 首拉镜像网络抖动触发 `UPGRADE_FAILED_PULL` 自动暂停；三节点手动补齐 v18.2.8 镜像后 `ceph orch upgrade resume`。
5. **终态**：mon/mgr/osd/mds/rgw 全 18.2.8（16 daemon），HEALTH_OK。

### 12.4 升级后决定性验证（全部通过）

| 验证项 | 升级前 | 升级后 |
|---|---|---|
| 0 字节直写（纯 aws-chunked + CL） | 400 | **200** |
| 0 字节直写（minio-go 双层分帧） | 400 | **200** |
| 探针链路真实（坏 seed → 403） | — | **403**（预校验仍严格） |
| 探针链路（坏终止块签名 → 200） | — | 200（18.2.8 语义：仅当客户端带 `x-amz-trailer` 时严格比对，源码确认） |
| 桶内 `meta.json` | 3 block 全缺（永不可查询） | **3 block 全有 + 新 block + tenant index 写入** |
| `tempo_ingest_storage_reader_read_errors_total` | ~2160/5min 持续涨 | **+1.1/5min（归零）** |
| `Tempo3BlockFlushFailing` 告警 | firing | **恢复** |
| Tempo 查询 | 扇出必失败 | **totalBlocks=3、jobs 6/6、trace 可查** |

### 12.5 收尾动作（已完成）

- 兼容层代理四件套退役删除；备份在 `/root/observability-upgrade-backup-20260929-111055-pg-s3-incident/manifests/`（configmap/secret/workload、capture-pod.yaml）。
- 探针脚本归档至 `/root/observability-upgrade-backup-20260929-154623/ceph-upgrade/probes/`；工作区与 `/tmp` 临时产物、Ceph 节点 `/tmp` 残留全部清理。
- RGW 运行时调试级别随容器重启天然还原；无残留日志文件。

### 12.6 遗留（升级不解决的部分）

| 项 | 状态 |
|---|---|
| 集群仍无 `pg16-ceph` 监控告警（cnpg-system 零告警） | P1 未动 |
| tempo 3.0.3 镜像无外网可升 | P2 未动 |
| `pg16-ceph` 无 Backup/ScheduledBackup | P2 未动 |
| Ceph 暂无定期 HealthCheck 巡检 | 建议排期 |
