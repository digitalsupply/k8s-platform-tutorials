# 10 · 流水线、构建缓存、镜像分层、发布与回滚

> 这一章回答交付链路里最容易“看起来会、实际做不对”的几件事：
> **阶段怎么切、缓存怎么命中、镜像为什么这么大、tag 怎么定、怎么发、怎么在 1 分钟内回滚、
> 数据库变更怎么才能回滚。**
>
> 证据目录：[`assets/pipeline-release/`](assets/pipeline-release/README.md)。
> 一句话版本：[15 面试速查 08-cicd-release](../15-interview-cheatsheet/08-cicd-release.md)。

## 1. 流水线阶段设计

### 1.1 一条可复现的流水线

```text
checkout
  → 静态检查/单测（可并行）
  → 构建镜像（一次）
  → 扫描/签名（Trivy/cosign）
  → 推送 Harbor（tag = git SHA）
  → 改 GitOps 仓 image tag（promote）
  → ArgoCD 同步
  → 滚动/蓝绿/金丝雀
  → 验证（就绪、错误率、关键接口）
```

原则：

1. **构建一次，按 digest 晋级**：同一镜像从 dev 到 prod 不重新 build；
2. **每个阶段有明确输入/输出**：源码 → 镜像 digest → Git commit → 集群状态；
3. **质量门禁前置**：lint/单测/扫描失败就不 push，不把坏镜像留给回滚；
4. **阶段幂等**：重跑同一 commit 得到同一 tag，不产生 `latest`/时间戳垃圾；
5. **凭据只在运行时注入**：不落盘、不进镜像层、不打印。

### 1.2 本环境真实 DAG

`kubectl -n cicd get pipeline` 的四条流水线结构：

```text
compassio-cicd
  clone
    ├── check-changes
    ├── build-push-backend   (when need-build=true)
    └── build-push-frontend  (when need-build=true)
  build-push-backend + build-push-frontend
    └── promote-gitops       (when need-build=true)
```

关键点：

- `build-push-backend` 与 `build-push-frontend` 的 `runAfter` 都只有 `clone`，
  两者**并行**；
- 两者都 `when` 引用 `check-changes.results.need-build`，Tekton 会隐式等待该结果；
- `promote-gitops` `runAfter` 两个 build，**必须都成功**才改 GitOps tag；
- 只改 `docs/` 时 `check-changes` 返回 false，build/promote 全跳过。

完整输出：[`evidence/tekton-pipeline-dag.txt`](assets/pipeline-release/evidence/tekton-pipeline-dag.txt)。

> 并行不是“多写几个 Task”就行：没有 `runAfter` 的 Task 默认同层并行；
> 但共享 workspace 时要注意写冲突。本环境 build backend/frontend 只读同一 source，
> 写各自的镜像，互不冲突。

### 1.3 阶段设计常见错误

| 错误 | 后果 | 正确做法 |
|---|---|---|
| 每个环境重新 build | 镜像不可复现，回滚找不到原镜像 | build once，按 digest/tag 晋级 |
| build 和 promote 之间无门禁 | 构建失败也改 GitOps | `runAfter` 全部 build + 结果校验 |
| 文档提交也全量构建 | 浪费几分钟和 Harbor 存储 | `check-changes` 路径过滤 |
| CI 直接 `kubectl set image` | Git 不再是唯一事实源 | 只改 GitOps 仓，ArgoCD 同步 |
| tag 用 `latest` | 无法知道线上是哪个 commit | tag = 40 位 git SHA |
| 失败历史立即清理 | 无法排障/回滚 | 成功保留 7–30 天，失败更久 |

## 2. 构建缓存与并行

### 2.1 缓存命中靠“层输入不变”

Dockerfile 每条指令是一层，层缓存键由：

```text
父层 digest + 指令 + 指令参数 + COPY/ADD 的文件内容校验和
```

决定。所以：

- **依赖清单单独一层**：`package.json`/lock 不变 → `npm ci` 层命中；
- **源码放后面**：改业务代码只让 `COPY . .` 及其后的层失效；
- **不要把 `COPY . .` 放在 `npm ci` 前面**，否则改一行代码就重装全部依赖。

### 2.2 真机验证：改源码只重建最后一层

在集群 BuildKit（v0.20.2）里用 `buildctl` 构建同一 Dockerfile 三次：

```dockerfile
FROM scratch
WORKDIR /app
COPY package.json /app/package.json
COPY src /app/src
```

```text
build 1（新上下文）: #5 COPY package.json  DONE
                     #6 COPY src           DONE
build 2（源码不变）: #5 CACHED
                     #6 CACHED
build 3（只改 src）: #5 CACHED             ← 依赖层复用
                     #6 COPY src  DONE     ← 只有源码层重建
```

完整日志：[`evidence/buildkit-cache.txt`](assets/pipeline-release/evidence/buildkit-cache.txt)。

> build 2 的 manifest digest 与 build 1 相同，说明输出完全一致；
> build 3 digest 变化，但依赖层仍命中。

### 2.3 缓存后端：inline vs registry

本环境两种都在用：

| 方式 | 配置 | 特点 |
|---|---|---|
| BuildKit inline | `--export-cache type=inline` | 缓存元数据写进镜像，跨 tag/跨节点命中差 |
| Kaniko cache repo | `--cache=true --cache-repo=.../cache` | 中间层推到独立 repo |
| BuildKit registry | `--export-cache type=registry,ref=.../cache:tag,mode=max` | 跨节点共享，推荐 CI 用 |

真实 Harbor 里能看到 `compassio/cache`、`openwebui/cache` 仓库；
`compassio/cache` 当前只有 1 个 SHA tag，说明缓存并未持续复用。

> 常见误区：以为“开了 `--cache=true` 就一定快”。
> 缓存要满足：同一 Dockerfile、同一构建参数、同一基础镜像、缓存后端可达。

### 2.4 并行度

- Tekton：同层 Task（无 `runAfter`）并行；`workspaces` 只读时安全。
- BuildKit：`[worker.oci] max-parallelism` 控制单次构建内部并行。
- CI 集群：多个 PipelineRun 之间靠调度器并行，但会争 CPU/磁盘/网络。

本环境发现一处**仓库与集群漂移**：

```text
仓库 assets/tekton/06-buildkit.yaml: max-parallelism = 4
集群 buildkitd 实际配置:            max-parallelism = 2
```

这说明“文档里的性能参数”不一定等于线上；排障要以
`kubectl -n cicd exec deploy/buildkitd -- cat /etc/buildkit/buildkitd.toml` 为准。

### 2.5 docker buildx

本机没有 Docker daemon，但安装了 Docker CLI 27.4.0 + buildx 0.30.1：

```text
$ docker buildx version
github.com/docker/buildx v0.30.1

$ docker buildx create --name pve-remote --driver remote tcp://127.0.0.1:1234
$ docker buildx inspect --bootstrap
Driver:        remote
Status:        running
BuildKit version: v0.20.2
Platforms:     linux/amd64, linux/amd64/v2, linux/amd64/v3, linux/386
```

也就是说：**buildx 可以直连集群里的 buildkitd**，不需要本机 Docker daemon。
完整输出：[`evidence/buildx-remote.txt`](assets/pipeline-release/evidence/buildx-remote.txt)。

实战中暴露两个真问题：

1. **buildkitd 拉 Harbor 基础镜像仍 x509**：

   ```text
   failed to fetch anonymous token:
   tls: failed to verify certificate: x509: certificate signed by unknown authority
   ```

   即使 `buildkitd.toml` 配了 `[registry."192.168.67.202:8443"] ca = [...]`，
   匿名 token 请求仍未信任。CI 里 push 能成功，是因为 `buildctl` 客户端另外设了
   `SSL_CERT_FILE`。**daemon 拉取与 client 推送是两条信任链**，要分别验证。

2. **docker.io 镜像源不稳定**：拉 `docker/dockerfile:1` 前端镜像时出现
   `error reading from server: EOF`，说明镜像加速源本身会抖动。
   生产应给基础镜像做 Harbor 代理缓存/固定 digest，不依赖公网即时拉取。

buildx 常用命令：

```bash
# 远程 builder
docker buildx create --name pve-remote --driver remote tcp://127.0.0.1:1234 --use
docker buildx inspect --bootstrap

# 多平台 + registry 缓存 + SBOM/provenance
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --cache-from type=registry,ref=$REG/cache:web \
  --cache-to   type=registry,ref=$REG/cache:web,mode=max \
  --provenance=true --sbom=true \
  -t $REG/web:$(git rev-parse HEAD) --push .

# 声明式多镜像
docker buildx bake -f buildx-bake.hcl --push
```

示例：[`examples/Dockerfile.node.multistage`](assets/pipeline-release/examples/Dockerfile.node.multistage)、
[`examples/buildx-bake.hcl`](assets/pipeline-release/examples/buildx-bake.hcl)。

## 3. 镜像分层与多阶段构建

### 3.1 多阶段解决什么

```dockerfile
FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginx:1.29-alpine AS runtime
COPY --from=build /app/dist /usr/share/nginx/html
```

最终镜像只包含 **nginx + dist**，不带 node_modules、源码、npm、编译工具。
本环境 `compassio/frontend` 就是这种结构：

```text
layers: 11
compressed_total_MB: 25.36
history（最后几层）:
  COPY /app/dist /usr/share/nginx/html
  COPY nginx.conf.template /etc/nginx/templates/...
  CMD ["nginx" "-g" "daemon off;"]
```

对比：

| 镜像 | 层数 | 压缩后大小 | 说明 |
|---|---|---|---|
| `compassio/frontend` | 11 | 25.4 MB | nginx + 前端产物 |
| `compassio/backend` | 9 | 185.6 MB | Python 运行时 + 依赖 |
| `openwebui/open-webui` | 5 | 225.4 MB | 应用 + 依赖，单层较大 |

证据：[`evidence/image-layers.txt`](assets/pipeline-release/evidence/image-layers.txt)。

> 层数不是越少越好。把整个应用塞进一层会导致任何改动都全量传输；
> 合理做法是“变化频率低的大依赖在前，变化频率高的业务代码在后”。

### 3.2 为什么 `COPY package.json` 要单独一层

因为依赖安装通常是最慢的一步。把依赖清单和源码分开：

```dockerfile
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build
```

- 只改源码：`npm ci` 层 CACHED，几秒完成；
- 依赖也改：才重新下载/安装。

如果把 `COPY . .` 放前面：

```dockerfile
COPY . .
RUN npm ci
```

任何源码改动都会改变 `COPY . .` 的校验和 → `npm ci` 缓存失效 → 每次全量装依赖。
这就是“`COPY package.json` 要单独一层”的本质：**缩小缓存失效范围**。

### 3.3 镜像构建检查清单

- [ ] 多阶段：构建工具不进运行镜像；
- [ ] `.dockerignore` 排除 `.git`/`node_modules`/`.env`/测试产物；
- [ ] 依赖锁定：`package-lock.json` + `npm ci`、`uv.lock`/`pip-compile`、`go.sum`；
- [ ] 基础镜像固定 digest，至少固定 minor tag；
- [ ] 非 root 用户；
- [ ] 不把 token/私钥写进 `ARG`/`ENV`/层；
- [ ] 只保留运行时需要的文件；
- [ ] 打 OCI labels：`org.opencontainers.image.revision`、`source`、`version`；
- [ ] 扫描（Trivy）通过再 push。

## 4. Tag 策略：禁止 latest，用 git SHA

### 4.1 推荐规则

```text
应用镜像: <registry>/<project>/<app>:<40位 git commit SHA>
可选别名: <app>:v1.4.0        （只做人类可读，必须指向同一个 digest）
基础镜像: <image>@sha256:<digest>  或固定 minor tag
禁止:     latest / main / dev / 手工 test tag
```

理由：

- SHA 与代码一一对应，回滚/排障能直接定位 commit；
- 不会“同一 tag 指向不同镜像”，避免节点缓存/不可变性问题；
- GitOps diff 可读：`newTag: 05f030a...` 就是一次发布。

### 4.2 本环境 Harbor 真实 tag 审计

| 项目/仓库 | 现状 | 评价 |
|---|---|---|
| `compassio/backend`、`frontend` | 全部 40 位 SHA | ✅ 符合 |
| `deeptutor/deeptutor` | 全部 40 位 SHA | ✅ 符合 |
| `china-study-free/web` | 3 个 40 位 + 3 个 7 位 | ⚠️ 短 SHA 混用 |
| `compassio/python`、`nginx`、`node` | 有 `latest` | ⚠️ 基础镜像可变 |
| `openwebui/open-webui` | `a077c804`、`manual-test1` | ❌ 手工 tag |
| 所有项目 | `immutable tag rules = 0` | ❌ 未禁止覆盖 |

完整清单：[`evidence/harbor-tags.txt`](assets/pipeline-release/evidence/harbor-tags.txt)。

短 SHA 的问题：7 位在超大仓库有碰撞概率；且同一个 commit 可能同时存在 7 位和 40 位两个 tag，
GitOps 里难以判断“这是不是同一个镜像”。**统一 40 位**最省心。

### 4.3 latest 为什么危险

- `imagePullPolicy: Always` 时，不同节点可能拉到不同时间点的 `latest`；
- 回滚 `latest` 无法回到“上一个版本”；
- 扫描/审计无法把漏洞关联到具体代码版本；
- 基础镜像 `latest` 会在某天悄悄升级，构建结果不可复现。

允许 `latest` 的唯一场景：本地开发临时用，不进 CI/生产。

### 4.4 保留策略会限制回滚窗口

Harbor retention 实际配置：

```text
compassio: backend/frontend/cache 各保留最近 5 个 tag
deeptutor: 所有仓库保留最近 5 个
openwebui: cache 保留 3 个；open-webui 仓库 always retain
```

也就是说：

- 连续发布 6 次后，第 1 个镜像会被清掉；
- “回滚到任意历史版本”并不成立，只能回滚到保留窗口内；
- 重要版本（如 `v1.4.0`）应加 `always retain` 规则或复制到归档项目。

## 5. 发布策略：滚动 / 蓝绿 / 金丝雀 / Feature Flag

### 5.1 本集群现状

```text
RollingUpdate 25%/25%   54 个 Deployment
Recreate                12 个
RollingUpdate 0/1        5 个
RollingUpdate 25%/1      3 个
RollingUpdate 25%/0      1 个（metrics-server）
```

Argo Rollouts CRD **未安装**，没有 `Rollout` 资源；发布主要靠原生 Deployment +
ArgoCD 同步。证据：[`evidence/deploy-strategies.txt`](assets/pipeline-release/evidence/deploy-strategies.txt)。

### 5.2 四种方式对比

| 方式 | 资源 | 切换速度 | 回滚 | 适用 |
|---|---|---|---|---|
| 滚动 RollingUpdate | 少量额外 | 逐步 | `rollout undo` | 无状态、兼容新旧版本 |
| 蓝绿 Blue/Green | 双倍 | 秒级切 selector | 切回旧 selector | 需要快速切换/验证 |
| 金丝雀 Canary | 少量 | 按权重逐步 | 权重归零/删 canary | 有指标、能自动判定 |
| Feature Flag | 无额外 | 改开关 | 关开关 | 代码已部署、按用户/租户放开 |

### 5.3 蓝绿真机实验

在 `rollout-lab` 里部署 blue/green 两套（各 2 副本），Service 先指向 blue：

```text
before: blue
patch selector blue -> green
first_green_after_seconds=1
after: green
```

切换只是改 Service selector，API 层是瞬时的；真正决定“能不能切”的是
**green 的 readiness**。回滚同理：selector 切回 blue 即可。

证据：[`evidence/bluegreen-lab.txt`](assets/pipeline-release/evidence/bluegreen-lab.txt)，
清单：[`manifests/blue-green.yaml`](assets/pipeline-release/manifests/blue-green.yaml)。

> 注意：蓝绿要求数据库同时兼容 blue/green 两版代码；
> 如果 green 做了破坏性 schema 变更，切回去就坏了。

### 5.4 金丝雀

本环境没有 Argo Rollouts，但 Traefik 支持按权重分流：

```yaml
services:
  - name: web-stable
    weight: 90
  - name: web-canary
    weight: 10
```

发布流程：

1. 部署 canary（同一 Service 的不同 label）；
2. 权重 5% → 观察错误率/P95/业务指标；
3. 正常则 25% → 50% → 100%；
4. 异常则权重归零，canary 副本保留供排查。

清单：[`manifests/canary-traefik.yaml`](assets/pipeline-release/manifests/canary-traefik.yaml)。

> 金丝雀的难点不是“分流”，而是**判定**：没有 SLO/指标，金丝雀就只是“随机让 10% 用户踩雷”。

### 5.5 Feature Flag

本集群没有 Unleash/flagd/OpenFeature 一类系统。最小替代是 ConfigMap + env：

```yaml
data:
  NEW_CHECKOUT: "false"
```

但这**不是真正的 feature flag**：改 ConfigMap 仍需重启 Pod，无法按用户/租户灰度，
也没有审计和自动回滚。生产建议：

- flag 服务（Unleash/flagd）+ OpenFeature SDK；
- flag 变更也走 Git/审批；
- flag 有生命周期，发布完删除，避免永久开关堆积。

## 6. 回滚要能在 1 分钟内完成

### 6.1 真机测量

在 `rollout-lab` 用 3 副本 Deployment 做滚动发布与回滚：

```text
trigger v2 (set env): rollout_seconds=4
rollout undo:         undo_seconds=4
```

完整输出：[`evidence/rollback-lab.txt`](assets/pipeline-release/evidence/rollback-lab.txt)。

4 秒的前提：

- 镜像已在节点（或拉取很快）；
- readinessProbe 周期短；
- `maxUnavailable` 允许滚动；
- 没有长时间 preStop/优雅退出。

### 6.2 1 分钟回滚的必备条件

| 条件 | 不满足会怎样 |
|---|---|
| 镜像 tag 不可变 | 回滚时镜像已被覆盖/删除 |
| 保留旧 ReplicaSet | `rollout undo` 无版本可回 |
| Harbor 保留窗口足够 | 旧 tag 被 retention 清掉 |
| DB 变更向前兼容 | 回滚后新代码写的字段旧代码不认 |
| 配置/Secret 也版本化 | 只回滚镜像，配置还是坏的 |
| 有 smoke test | 回滚后不知道是否真的恢复 |

回滚阶梯：

```bash
# 1) 最快：ArgoCD 回退到上一个 Git commit（GitOps）
argocd app rollback <app>

# 2) 原生 Deployment：回到上一个 ReplicaSet
kubectl -n <ns> rollout undo deploy/<name>
kubectl -n <ns> rollout status deploy/<name> --timeout=60s

# 3) 指定 revision
kubectl -n <ns> rollout history deploy/<name>
kubectl -n <ns> rollout undo deploy/<name> --to-revision=<n>

# 4) 蓝绿：切回旧 selector
kubectl -n <ns> patch svc <name> -p '{"spec":{"selector":{"color":"blue"}}}'
```

> 回滚时间要从“决定回滚”开始算：定位 + 审批 + 执行 + 验证。
> 只测 `kubectl` 的 4 秒没有意义，**演练**要覆盖整条链路。

## 7. 数据库变更：expand-contract

### 7.1 四步法

```text
1. Expand   加新列/新表（可空、无默认值），旧代码不受影响
2. Dual-write 新代码同时写旧列和新列
3. Backfill 回填历史数据；新代码读 coalesce(new, old)
4. Contract 观察期后删旧列/改约束
```

每一步都可独立回滚；**Contract 是单向门**，执行前必须确认没有旧代码在跑。

### 7.2 真机 SQL 与耗时

在 CNPG `pg16-ceph`（PostgreSQL 16.15）的独立库 `expand_contract_lab` 执行：

```sql
ALTER TABLE users ADD COLUMN email_new text;              -- 2.9 ms
INSERT INTO users (id,email,email_new) VALUES (2,'bob@old','bob@new');
UPDATE users SET email_new = email WHERE email_new IS NULL;
SELECT id, email, email_new, coalesce(email_new,email) FROM users;

ALTER TABLE users DROP COLUMN email;                      -- 2.8 ms
ALTER TABLE users RENAME COLUMN email_new TO email;       -- 2.7 ms
ALTER TABLE users ALTER COLUMN email SET NOT NULL;        -- 2.8 ms
```

完整输出：[`evidence/expand-contract.txt`](assets/pipeline-release/evidence/expand-contract.txt)，
脚本：[`sql/expand-contract.sql`](assets/pipeline-release/sql/expand-contract.sql)。

关键点：

- PostgreSQL 11+ `ADD COLUMN` 可空且无默认值，**不重写表**，锁很短；
- `ADD COLUMN ... DEFAULT` 在旧版本会重写表，大表要避免；
- 大表回填要分批（`LIMIT` + 循环），避免长事务/膨胀；
- 索引用 `CREATE INDEX CONCURRENTLY`，不阻塞写入；
- `DROP COLUMN` 很快，但会让旧代码立刻报错，所以必须等观察期。

### 7.3 回滚窗口

| 阶段 | 回滚动作 | 安全性 |
|---|---|---|
| Expand 后 | 旧代码继续跑 | ✅ 安全 |
| Dual-write 后 | 回滚新代码，旧列还在 | ✅ 安全 |
| Backfill 后 | 回滚新代码，忽略新列 | ✅ 安全 |
| Contract 后 | 旧代码缺列，直接报错 | ❌ 只能恢复备份 |

所以“数据库变更向前兼容”具体指：**Contract 之前，任何一版代码都能跑**。
蓝绿/金丝雀期间尤其要保证这一点。

## 8. 制品与依赖

### 8.1 私服 Harbor

本环境 Harbor `192.168.67.202:8443`：

| 项目 | 可见性 | 自动扫描 | 保留策略 |
|---|---|---|---|
| `compassio` | 私有 | 开 | backend/frontend 最近 5 个 |
| `deeptutor` | 公开 | 开 | 所有仓库最近 5 个 |
| `openwebui` | 私有 | **关** | cache 3 个；应用 always |
| `china-study-free` | 私有 | 未开 | 无 |
| `library` | 公开 | 未开 | 无 |

发现：

- **没有 immutable tag 规则**，任何有 push 权限的账号都能覆盖已有 tag；
- `openwebui` 自动扫描关闭，应用镜像存在未扫描窗口；
- retention 只留 5 个，回滚窗口有限；
- 没有 proxy-cache 项目，公网镜像仍靠 buildkitd 的 mirror。

建议：

1. 应用 tag 加 immutable 规则（至少 `sha-*`/40 位 SHA）；
2. `prevent_vul=true`，高危镜像禁止 pull；
3. 基础镜像走 Harbor proxy cache，固定 digest；
4. 关键版本 `always retain` 或归档；
5. CI 用 robot account，最小权限（只 push 指定项目）。

### 8.2 依赖锁定

| 生态 | 锁文件 | 可复现安装 |
|---|---|---|
| Node | `package-lock.json` | `npm ci`（不是 `npm install`） |
| Python | `uv.lock` / `requirements.lock` | `uv sync --frozen` / `pip install -r` |
| Go | `go.sum` | `go mod download` |
| 系统包 | 镜像 digest / 固定版本 | 不用 `apt-get upgrade` |
| 基础镜像 | `@sha256:` | 不用 `latest` |

本环境已有 `--build-arg NPM_REGISTRY`、`PIP_INDEX_URL` 指向内网/镜像源，
但部分 Dockerfile 仍用 `python:3.11-slim` 这类浮动 tag，建议改成 digest。

### 8.3 SBOM / 签名 / 溯源

buildx 支持但本环境尚未启用：

```bash
docker buildx build \
  --provenance=true \
  --sbom=true \
  -t $REG/app:$(git rev-parse HEAD) --push .
```

产物：

- provenance：谁在什么时间、用什么源码/参数构建；
- SBOM：镜像里有哪些包/版本；
- 配合 cosign 签名 + Kyverno/OPA 验签，才能阻止“未签名镜像”进集群。

## 9. 一页命令与检查清单

```bash
# 流水线
kubectl -n cicd get pipeline
kubectl -n cicd get pipelinerun --sort-by=.metadata.creationTimestamp
kubectl -n cicd logs <taskrun-pod> -c step-build

# 缓存
kubectl -n cicd exec deploy/buildkitd -c buildkitd -- \
  buildctl --addr tcp://127.0.0.1:1234 build \
  --frontend dockerfile.v0 --local context=. --local dockerfile=. \
  --export-cache type=registry,ref=$REG/cache:app,mode=max \
  --import-cache type=registry,ref=$REG/cache:app

# buildx
docker buildx create --name remote --driver remote tcp://127.0.0.1:1234 --use
docker buildx inspect --bootstrap
docker buildx bake -f buildx-bake.hcl --push

# tag 审计
crane ls --insecure $REG/compassio/frontend | grep -E '^[0-9a-f]{40}$'

# 发布/回滚
kubectl -n <ns> rollout status deploy/<name> --timeout=60s
kubectl -n <ns> rollout undo deploy/<name>
kubectl -n <ns> rollout history deploy/<name>
```

发布前检查：

- [ ] 镜像 tag 是 40 位 SHA，且 Harbor 里有该 digest；
- [ ] Trivy 扫描通过（或已知风险被接受）；
- [ ] readiness/liveness 正确，`maxUnavailable` 符合容量；
- [ ] DB 变更是 expand 阶段，旧代码仍可运行；
- [ ] 回滚目标版本仍在 Harbor retention 窗口内；
- [ ] 有 smoke test/关键指标看板；
- [ ] GitOps 仓只改 image tag，没有手工 `kubectl set image`。
