# 08 · CI/CD、镜像、发布与回滚面试题

> 详细证据：[10 流水线、缓存、镜像分层、发布与回滚](../10-cicd-delivery/10-pipeline-release-artifacts.md)。

## 1. 流水线阶段怎么设计

**一句话**：checkout → 检查/单测 → build（一次）→ scan/sign → push → promote GitOps → 部署 → 验证。

**本环境**：`clone → check-changes → build backend/frontend（并行）→ promote-gitops`，build 失败不改 GitOps。

## 2. 为什么 build 只做一次

**一句话**：同一 commit 只产出一个镜像，按 digest/tag 晋级，避免各环境重新构建导致不可复现。

**本环境**：Harbor 应用镜像 tag 都是 40 位 SHA，GitOps 只改 `newTag`。

## 3. 构建缓存怎么命中

**一句话**：层缓存键 = 父层 digest + 指令 + 参数 + 文件校验和；输入不变才命中。

**本环境**：buildctl 三次构建，源码不变时 `COPY package.json`/`COPY src` 都 CACHED；只改 src 时仅 src 层重建。

## 4. 为什么 COPY package.json 要单独一层

**一句话**：缩小缓存失效范围；依赖清单不变时 `npm ci` 层复用，改业务代码不必重装依赖。

**本环境**：真机日志 `#5 CACHED`（package.json）+ `#6 DONE`（src）。

## 5. 多阶段构建解决什么

**一句话**：构建阶段装依赖/编译，运行阶段只复制产物，镜像更小、攻击面更小。

**本环境**：frontend 最终 25.4MB/11 层，history 只有 nginx + dist，没有 node_modules。

## 6. 镜像为什么大 / 怎么减小

**一句话**：基础镜像大、依赖多、把构建工具/缓存/源码带进运行层、没清理包缓存。

**本环境**：backend 185.6MB（Python 依赖），open-webui 225.4MB（单层 177MB 依赖）。

## 7. tag 策略

**一句话**：应用镜像用 40 位 git SHA；禁止 latest/main/手工 tag；基础镜像固定 digest。

**本环境**：compassio/deeptutor 全是 SHA40；但基础镜像有 latest、openwebui 有 `manual-test1`、china-study-free 混用 7 位 SHA。

## 8. 为什么禁止 latest

**一句话**：latest 可变，无法复现、无法回滚、无法关联漏洞和代码版本。

**本环境**：`compassio/node:latest`、`python:latest` 仍存在；CI 应用镜像已不用 latest。

## 9. 滚动发布

**一句话**：逐个替换 Pod，`maxSurge/maxUnavailable` 控制速度与容量。

**本环境**：51 个 Deployment 用 25%/25%（全集群 74 个）；`metrics-server` 用 25%/0 保证容量。

## 10. 蓝绿

**一句话**：两套环境同时跑，Service/入口一次切流量，回滚即切回。

**本环境**：lab 里 blue→green selector 切换，响应从 blue 变 green；要求 DB 同时兼容两版。

## 11. 金丝雀

**一句话**：按比例放量，用指标判定，异常把权重归零。

**本环境**：Argo Rollouts 未装；Traefik IngressRoute 可按 weight 分流（90/10）。

## 12. Feature Flag

**一句话**：部署与发布解耦，代码先上、开关后开；可按用户/租户灰度。

**本环境**：无 Unleash/flagd；ConfigMap+env 只是静态开关，改开关仍要重启。

## 13. 1 分钟回滚

**一句话**：镜像不可变 + 旧 ReplicaSet 保留 + Harbor 未清 tag + DB 向前兼容 + 配置版本化。

**本环境**：3 副本 rollout 4 秒、undo 4 秒；但这只是执行时间，不含定位/审批/验证。

## 14. 数据库 expand-contract

**一句话**：先加可空新列 → 双写 → 回填 → 观察期 → 再删旧列；Contract 不可逆。

**本环境**：PG16.15 每步 2–3ms；`ADD COLUMN` 可空无默认不重写表。

## 15. 私服与依赖锁定

**一句话**：私有 Harbor + robot account 最小权限 + 依赖锁文件 + 基础镜像 digest。

**本环境**：compassio/deeptutor 自动扫描；openwebui 未开扫描；无 immutable 规则；retention 只留 5 个。

## 16. docker buildx

**一句话**：buildx 是 BuildKit 前端，支持多平台、registry cache、SBOM/provenance、远程 builder。

**本环境**：buildx 0.30.1 + remote driver 连集群 BuildKit v0.20.2；Harbor 基础镜像拉取仍 x509（daemon 信任链未配好）。

## 17. 构建并行

**一句话**：DAG 同层 Task 并行、BuildKit `max-parallelism` 控制内部并行；并行度受 CPU/磁盘/网络限制。

**本环境**：compassio backend/frontend 并行；仓库写 max-parallelism=4，集群实际是 2（漂移）。

## 18. 制品保留与回滚

**一句话**：retention 决定回滚窗口；关键版本要 always retain 或归档，不能只留最近 5 个。

**本环境**：compassio/deeptutor 保留最近 5 个；openwebui 应用仓库 always retain。

## 一句话总表

| 题 | 一句话 |
|---|---|
| 阶段设计 | build once，按 digest 晋级，门禁前置 |
| 缓存 | 输入不变才命中；依赖清单单独一层 |
| 多阶段 | 构建工具不进运行镜像 |
| tag | 40 位 SHA，禁止 latest |
| 滚动 | maxSurge/maxUnavailable 控制 |
| 蓝绿 | 双套 + 切 selector，秒级回滚 |
| 金丝雀 | 按权重放量 + 指标判定 |
| Feature Flag | 部署与发布解耦 |
| 回滚 1 分钟 | 镜像/配置/DB 三者都可回 |
| expand-contract | 先兼容、后删除，Contract 不可逆 |
| 私服 | 最小权限 + 扫描 + 不可变 tag |
| buildx | 多平台/缓存/SBOM/远程 builder |
