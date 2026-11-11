# 流水线 / 镜像 / 发布 / 回滚：本环境实测

对应教程：[`../../10-pipeline-release-artifacts.md`](../../10-pipeline-release-artifacts.md)。

## 证据

| 文件 | 内容 |
|---|---|
| `evidence/tekton-pipeline-dag.txt` | 4 条 Pipeline 的 Task、runAfter、when |
| `evidence/buildkit-cache.txt` | 三次构建：全量 / 全 CACHED / 只重建 src 层 |
| `evidence/buildx-remote.txt` | buildx 0.30.1 + remote driver 连集群 BuildKit v0.20.2；Harbor CA x509 |
| `evidence/harbor-tags.txt` | Harbor 全部项目/仓库 tag，SHA40/SHA7/latest/手工 tag 统计 |
| `evidence/image-layers.txt` | frontend 11 层 25.4MB、backend 9 层 185.6MB、open-webui 5 层 225.4MB |
| `evidence/deploy-strategies.txt` | 集群 Deployment 的 RollingUpdate/Recreate 分布 |
| `evidence/rollback-lab.txt` | 3 副本滚动发布 4 秒、undo 4 秒 |
| `evidence/bluegreen-lab.txt` | blue→green selector 切换、响应变化 |
| `evidence/expand-contract.txt` | PostgreSQL 16.15 expand-contract 每步 SQL 与耗时 |
| `evidence/cnpg.txt` | CNPG 集群版本/实例/主库 |

## 可复用清单

| 文件 | 用途 |
|---|---|
| `examples/Dockerfile.node.multistage` | Node 多阶段 + 依赖层缓存 |
| `examples/Dockerfile.python.multistage` | Python 多阶段 + 依赖锁定 |
| `examples/.dockerignore` | 减小构建上下文 |
| `examples/buildx-bake.hcl` | 多镜像、registry cache、SBOM/provenance |
| `examples/tekton-buildkit-cache.yaml` | Tekton + BuildKit registry cache |
| `manifests/deployment-rolling.yaml` | maxUnavailable=0 的滚动发布 |
| `manifests/blue-green.yaml` | 双 Deployment + Service selector |
| `manifests/canary-traefik.yaml` | Traefik 权重金丝雀 |
| `manifests/feature-flag-configmap.yaml` | 最小 feature flag（ConfigMap） |
| `sql/expand-contract.sql` | expand-contract 完整 SQL |

## 关键结论

- 依赖清单单独一层：改源码时 `COPY package.json` 与 `npm ci` 层 CACHED，只重建源码层；
- 多阶段把 node_modules/源码/构建工具挡在运行镜像外：frontend 最终仅 25.4MB；
- 应用 tag 用 40 位 SHA；Harbor 仍存在基础镜像 `latest`、手工 `manual-test1`、短 SHA 混用；
- Harbor 没有 immutable tag 规则，retention 只留 5 个，回滚窗口有限；
- 3 副本滚动发布/回滚实测各 4 秒；1 分钟回滚取决于镜像保留、DB 兼容、配置版本化；
- 蓝绿切换是瞬时 selector 变更，真正的门禁是 green readiness；
- Argo Rollouts/Feature Flag 系统未部署，金丝雀目前靠 Traefik 权重；
- DB expand-contract 每步毫秒级，Contract 后旧代码立即失败，是不可逆门。
