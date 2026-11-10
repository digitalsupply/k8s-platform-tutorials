# Compassio CI/CD 运维手册

## 一、日常运维命令

### 流水线

| 含义 | 命令 |
|---|---|
| 最近 5 次 CI | `kubectl get pipelinerun -n cicd --sort-by=.metadata.creationTimestamp \| head -6` |
| 看某次构建子任务 | `kubectl get taskrun -n cicd \| grep <pipelinerun名字>` |
| 看构建日志（kaniko/buildctl） | `kubectl logs -n cicd <taskrun名>-pod -c step-build`（grep -v '#\|INFO' 掉杂讯）|
| GitOps 当前 tag | `git -C /root/.hermes/cache/scratch/compassio-recon/gitops pull && grep newTag overlays/prod/kustomization.yaml` |
| ArgoCD 状态 | `kubectl get应用 argoproj.io compassio -n argocd` |
| 强制重同步 | `argocd app sync compassio`（或 UI 重同步） |

### 镜像仓库

| 含义 | 命令 |
|---|---|
| Harbor 健康检查 | `curl -sk https://192.168.67.202:8443/api/v2.0/health` |
| 列项目（含扫描策略） | `curl -sk https://192.168.67.202:8443/api/v2.0/projects` |
| 镜像扫描报告 | Harbor UI → compassio → repo → Artifact → 漏洞页签 |

### 数据库（CNPG）

| 含义 | 命令 |
|---|---|
| 集群健康 | `kubectl get cluster -n compassio` |
| 登录 | `kubectl exec -n compassio -it compassio-pg-1 -- psql -U compassio` |
| 备份 | `kubectl cnpg backup compassio-pg -n compassio`（需 PGSimpleMan） |

## 二、凭据矩阵（不要在 git 历史之外留存明文）

| secret | 用途 | key |
|---|---|---|
| `cicd/gitlab-auth` | GitLab root PAT（clone/commit/webhook 管控） | username/password/token/git-url/gitops-url |
| `cicd/gitlab-webhook-secret` | webhook 来源校验（EL interceptor） | secretToken（须 == GitLab hook 的 Secret token） |
| `cicd/harbor-auth` | push/pull Harbor | .dockerconfigjson（builder 挂载 `DOCKER_CONFIG`） |
| `compassio/compassio-db-credentials` | CNPG 初始库管理员 | username/password（basic-auth） |
| `compassio/compassio-app-secrets` | app 运行时 | DATABASE_URL/JWT_SECRET/LLM_PROVIDER/LLM_BASE_URL/LLM_MODEL/LLM_API_KEY |
| `compassio/compassio-tunnel`（如有） | 反向隧道 SSH key 或 PAT | — |

> **安全**：这些值只落私有 GitLab 仓 + 集群 secret；文档不放值。JWT_SECRET/DB 密码建议季度轮换。

> **RBAC**：各 Pod 用的是哪个 SA、`cicd/pipeline` 的授权与越权面、以及 Tekton 那些 Role/ClusterRole 是不是自动生成的，
> 见 `docs/22-从push到上线的CI-CD全链路详解.md` **§5.1.4**。

## 三、触发链路（直连 ingress，SSH 反向隧道已退休）

> 本节只讲触发入口。**从 push 到上线的完整逐级流转（含各组件原理与配置）见 `docs/22-从push到上线的CI-CD全链路详解.md`。**

自 **2026-10-18** 起，GitLab webhook 不再经 SSH 反向隧道，改为**直连 Traefik ingress**：

```
GitLab push → http://ci-compassio.xyz/   (GitLab 主机 /etc/hosts: 10.0.0.252)
  → Traefik LB(10.0.0.252) → svc el-compassio-listener:8080
  → EventListener compassio-listener（gitlab interceptor 校验 X-Gitlab-Token）
  → TriggerBinding/Template → PipelineRun
```

- **网络路径**：GitLab 主机 `192.168.67.201` 经**内网**访问 `10.0.0.0/24`（`10.0.0.0/24 via 192.168.67.156`）；
  `ip route get 10.0.0.252` 应显示 `via 192.168.67.156 dev eth0`。Tailscale 仅作其它流量通路。
- **连通自检**（在 GitLab 主机上跑）：
  - `curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' http://ci-compassio.xyz/` → **202**（EL 受理）
  - `curl -H 'Host: ci-compassio.xyz' http://10.0.0.252/` → **400**（EL 只吃 POST，返 400 即"通"）
- **来源校验**：EL 挂 `gitlab` ClusterInterceptor，要求 `X-Gitlab-Token` == secret
  `cicd/gitlab-webhook-secret(secretToken)`，且 `X-Gitlab-Event: Push Hook`；不匹配的事件被丢弃
  （注意：被丢弃时 HTTP **仍返回 202**，这是 Tekton 语义，不代表触发成功）。
- **Service 归属**：`el-compassio-listener` 是 ClusterIP，由 triggers controller 自动创建/管理；
  EL 的 NodePort 30081 已随早期手工 Service 一并移除。
- 旧的 `gitlab-el-tunnel.service`（m01）已 `systemctl disable --now`。

> **内网直连已启用**：GitLab 主机加 `10.0.0.0/24 via 192.168.67.156 dev eth0`
> （正确下一跳是 `.156`，**不是**默认网关 `.1`——`.1` 会黑洞 curl 000）+
> ip rule `to 10.0.0.0/24 lookup main priority 5265`，由 systemd `k8s-internal-route.service` 持久化。
> Tailscale（table 52 / rule 5270）仅保留给其它流量，二者不冲突。

**（仅应急）回退到隧道**：需同时恢复 NodePort Service，否则隧道无端口可转：
```
# 1) 临时手工建回 NodePort（会与 controller 冲突，仅应急短暂用）
kubectl -n cicd expose deploy el-compassio-listener --type=NodePort --name=el-compassio-listener-np --port=8080 --target-port=8080
# 2) 起隧道（指向新 NodePort 或 30081）
systemctl enable --now gitlab-el-tunnel.service
# 3) GitLab webhook 改回 http://127.0.0.1:18080/
```

## 四、故障树

| 症状 | 根因 | 处理 |
|---|---|---|
| PipelineRun Failed 1s，tag 包含 `$` | Trigger 模板双替换污染 | 检查 03-trigger.yaml，镜像 tag 用 `$(tt.params.gitrevision)` |
| kaniko `Error checking push permissions` | harbor-auth secret 变更 | 检查 admin 凭据；Harbor 8443 三轴 --insecure --skip-tls-verify --insecure-pull |
| BuildKit 报 `x509: certificate signed by unknown authority` | `buildctl` **客户端**的 CA 库没有 Harbor 自签 CA（daemon 的 CA 配置不覆盖客户端）| Task 挂 `harbor-ca` → `cat 系统CA + ca.crt > /tmp/ca-bundle.crt` → `export SSL_CERT_FILE`；详见 `docs/23` |
| 外网拉镜像龟速 | 1ms.run/DaoCloud 波动 | 驻停后重跑；必要时 ubuntu02 host-docker 转拉转推 Harbor 本地 |
| ArgoCD Degraded（ImagePullBackOff） | image tag 不存在 | gitops `newTag` 应等于 Harbor 里果期 tag；push 触发 CI 重做 |
| webhook 422 Invalid url | local 请求未放行（**仅隧道时代需要**，现已直连不再触发） | 若确需 local hook：PUT settings（见下） |
| push 后无 PipelineRun，EL 却返回 202 | interceptor token/事件类型不匹配（202 是 Tekton 语义） | 核对 GitLab hook 的 Secret token == `cicd/gitlab-webhook-secret`；确认发的是 `X-Gitlab-Event: Push Hook` |
| EL 报 `services "el-compassio-listener" already exists` | 手工声明了同名 Service，controller 无法接管 | 删掉手工 Service，交由 controller 建（见 `04-eventlistener.yaml` 顶部注释）；`kubectl get eventlistener compassio-listener -n cicd` 的 Service 条件须为 True |
| 改了 EL（如加 interceptor）却不生效 | controller reconcile 失败 → sink 配置未下发；sink 是热加载，无需重启 Pod | 先看 EL 的 `Service/Ready` 条件；必要时 `kubectl rollout restart deploy/tekton-triggers-controller -n tekton-pipelines` 强制 resync |
| `kubectl logs` 看 sink 无 token 报错但事件被丢 | interceptor 在 core-interceptors 侧拦截 | `kubectl logs -n tekton-pipelines deploy/tekton-triggers-core-interceptors` 看 `Continue:false` |

### GitLab 设置速令（必须保持开启）

```bash
# 直连目标 10.0.0.252 是私网地址：此项必须为 true，否则 GitLab 拒投 webhook。
# 报错形如：WebHook Error => URL is blocked: Requests to the local network are not allowed
# 改值后 Sidekiq/WebHookWorker 可能短时缓存旧值，随后一两次 push 仍可能被拦；等缓存过期即恢复。
curl -s -X PUT 'http://192.168.67.201/api/v4/application/settings' \
  -H "PRIVATE-TOKEN: $TOK" -H 'Content-Type: application/json' \
  -d '{"allow_local_requests_from_hooks_and_services": true}'
# 如需收窄 SSRF 面，用出站 allowlist 精确放行，而非关闭：
# -d '{"outbound_local_requests_allowlist": ["10.0.0.0/8","192.168.0.0/16"]}'
```

## 五、BuildKit（现役构建器）管理

> **2026-10-20 起现役**：`Task/compassio-build-push` 使用 BuildKit（`compassio/buildkit:v0.20.2-rootless`）。
> 2026-10-14~10-20 期间因 CA 问题回滚为 Kaniko，排障经过见 `docs/23-BuildKit构建器排障与切换纪要.md`。

```bash
# buildkitd 部署/状态
kubectl get pods -n cicd -l app=buildkitd
kubectl logs -n cicd -l app=buildkitd --tail=20

# 当前用的是哪个构建器
kubectl get task compassio-build-push -n cicd -o jsonpath='{.spec.steps[0].image}{"\n"}'

# 手工测速（在任意 task 内；注意客户端也要信任 Harbor CA）
buildctl --addr tcp://buildkitd.cicd.svc:1234 build \
  --frontend dockerfile.v0 --local context=. --local dockerfile=. \
  --output type=image,name=192.168.67.202:8443/compassio/backend:smoke,push=true
```

- **客户端 CA 必须注入**：`buildctl` 自己做 registry token 交换；Task 挂 `harbor-ca` 并 `export SSL_CERT_FILE=/tmp/ca-bundle.crt`（系统 CA + Harbor CA）。漏了报 `x509: certificate signed by unknown authority`。
- **缓存已持久化**：`home` 卷为 hostPath `/var/lib/buildkitd-cache`（m01），跨 Pod 重启保留；NFS/Ceph 均因 rootless/CSI 限制不可用（见 `docs/23 §9.1`）。
- **客户端已非 root**：Task 用镜像默认 uid 1000，`DOCKER_CONFIG=/home/user/.docker`。
- **seccomp 必须 `Unconfined`**：`RuntimeDefault` 会让 rootlesskit 起不来（已实测）。
- buildkitd.toml 已配置 docker.io → docker.1ms.run 镜像源；daemon 侧 CA = `/bundle/ca-bundle.crt`（initContainer 拼装）。
- TLS 校验已恢复：正常任务不再使用 `registry.insecure`。
- **回滚 kaniko**：`kubectl apply -f cicd/99-kaniko-tasks.yaml.bak`（会恢复 `--skip-tls-verify` 等宽松参数，仅应急）。

### 5.1 旧 PipelineRun / PVC 清理

每个 PipelineRun 会通过 `volumeClaimTemplate` 创建一块 **256Mi** workspace PVC；`cicd/cicd-cleanup` CronJob 每天 03:00 删除 **7 天前已结束**的 run，K8s GC 会级联回收其 TaskRun / Pod / PVC。

```bash
# 看 CronJob 与历史 Job
kubectl get cronjob cicd-cleanup -n cicd
kubectl get jobs -n cicd | grep cicd-cleanup

# 预演（只看不删）
kubectl create job --from=cronjob/cicd-cleanup cleanup-dry -n cicd --dry-run=client -o yaml \
  | sed 's/value: "false"/value: "true"/' | kubectl apply -f -
kubectl logs -n cicd job/cleanup-dry

# 立即执行一次
kubectl create job --from=cronjob/cicd-cleanup cleanup-manual -n cicd

# 想保留某个 run：打 label
kubectl label pipelinerun <name> -n cicd cleanup=keep
```

> 该 Tekton 版本（v1.6.0）不支持 `spec.ttlSecondsAfterFinished`，所以用 CronJob 实现。

## 六、复刻指南（其他 Web 应用也用这套）

1. GitLab 组 `digitalsupply` 建 `xxx` + `xxx-gitops`
2. `harbor`建项目（auto_scan）+ 更新镜像 repository 变量
3. 复制 `cicd/01-tasks.yaml` 里的 build-push 与 update-gitops task，更改项目/镜像参数
4. 更新鲜 TriggerTemplate 里的 pipeline 名 / image-repository 默认值
5. 新 EventListener（**勿手工声明同名 Service**，交 controller 建）+ ingress + gitlab webhook（直连 ingress，配 Secret token + `X-Gitlab-Token` interceptor）
6. `deploy/k8s` base + overlay 起理，然后 argocd Application

## 七、数据导入 SOP（师生名册）

### 7.1 标准流程（先教师、后学生）

```bash
# 0) 取 token
TOK=$(curl -s -H 'Host: compassio.xyz' -H 'Content-Type: application/json' \
  -X POST http://10.0.0.252/api/auth/login \
  -d '{"username":"admin","password":"******"}' | python3 -c "import json,sys;print(json.load(sys.stdin)['access_token'])")

# 1) 先看预览（0 错误再提交；预览不写库）
curl -s -H 'Host: compassio.xyz' -H "Authorization: Bearer $TOK" \
  -F "file=@testdata/教师导入表.xlsx" http://10.0.0.252/api/import/teachers | head -c 400

# 2) 提交教师
curl -s -H 'Host: compassio.xyz' -H "Authorization: Bearer $TOK" \
  -F "file=@testdata/教师导入表.xlsx" http://10.0.0.252/api/import/teachers/commit \
  -o /tmp/teachers.json     # 返回里含 roster_html（姓名/用户名/初始密码），务必保存

# 3) 再导入学生（同理，kind=students）
curl -s -H 'Host: compassio.xyz' -H "Authorization: Bearer $TOK" \
  -F "file=@testdata/学生导入表.xlsx" http://10.0.0.252/api/import/students/commit -o /tmp/students.json
```

- **表头契约**：教师 `姓名,手机号,性别,班级,是否班主任`（性别可空→"未知"）；学生 `姓名,班级,性别,班主任`。
- 多工作表 xlsx 会**按表名匹配** kind（含"教师/teacher"或"学生/student"），匹配不到才用活动表。
- 手机号在教师表内必须唯一；班级不存在会自动创建；`初一/初二/初三` 自动规范成 `七/八/九年级`。
- 学生"班主任"按姓名在教师中匹配，同名不唯一 → warning 且暂不设置（可在账号管理里手工指定）。

### 7.2 验证

```bash
kubectl exec -n compassio deploy/compassio-backend -- python -c "
import asyncio
from sqlalchemy import text
from app.db import get_sessionmaker
async def main():
    sm = get_sessionmaker()
    async with sm() as s:
        for q,l in [(\"select count(*) from users where role='TEACHER'::userrole\",'教师'),
                    (\"select count(*) from users where role='STUDENT'::userrole\",'学生'),
                    ('select count(*) from classes','班级'),
                    ('select count(*) from users where is_homeroom=true','班主任')]:
            print(l, (await s.execute(text(q))).scalar())
asyncio.run(main())"
```

预期（本校名册）：教师 16 / 学生 887 / 班级 16 / 班主任 16。

### 7.3 常见故障

| 现象 | 根因 | 处理 |
|---|---|---|
| 导入请求返回 nginx 错误页/超时 | `proxy_read_timeout` 小于批量 bcrypt 耗时 | nginx 模板已设 600s；`BCRYPT_ROUNDS=10`；千人级仍建议预览+分批 |
| 请求超时但"数据其实进去了" | 客户端放弃 ≠ 后端回滚 | 提交后**先查库核对**再决定是否重导（见 7.4） |
| 教师行报"性别必须是 男/女" | 名单缺性别列且为旧版本 | 升级到含"性别可空"的版本，或补上性别列 |
| 导入读到错误的表 | 旧版本只读活动工作表 | 升级版本；或将两表拆成两个单表文件 |
| 应用重启后 500（`column does not exist`） | 新增列未迁移 | 应用自带 `_apply_light_migrations`（`ADD COLUMN IF NOT EXISTS`），重启即补 |

### 7.4 重复数据清理（导入非幂等）

重复导入会生成带序号后缀的账号（`s23baihexiang2`）。清理（**删全部学生后重导**）：

```bash
kubectl exec -n compassio deploy/compassio-backend -- python -c "
import asyncio
from sqlalchemy import text
from app.db import get_sessionmaker
async def main():
    sm = get_sessionmaker()
    async with sm() as s:
        n = (await s.execute(text(\"delete from users where role='STUDENT'::userrole\"))).rowcount
        await s.commit(); print('deleted', n)
asyncio.run(main())"
```

删教师前需先解除班级引用：`update classes set head_teacher_id=null;` 再 `delete from users where role='TEACHER'::userrole;`。

### 7.5 账号名单生成

- 导入 commit 的响应含 `roster_html`（可打印），建议落盘：`testdata/账号名单/学生账号名单.html`。
- 忘记保存时，逐个重置换新密码：`POST /api/admin/accounts/{id}/reset-password` → 返回 `{username, temporary_password}`。
- **名单含初始密码，不要提交到 git**（`.gitignore` 已排除 `testdata/账号名单/`）。
