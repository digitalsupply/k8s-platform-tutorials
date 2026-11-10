# tekton-demo-cicd 资源清理记录 (2026-10-28)

> 清理对象: 226 天前(≈2026-03-18)部署的 Tekton + GitLab + Harbor + ArgoCD 全流程 CI/CD Demo（本地工程名 `teketondemo`）
> 集群 context: `kubernetes-admin@kubernetes`（K8s v1.35.9）

## 1. 资源盘点

demo 组成（README: /root/cloud-native-notes/devops/ci-cd/teketondemo/README.md，现已删除）：

- Pipeline `tekton-demo-cicd`（ns `cicd`）：git-clone-local → python-test → build-and-push → update-gitops-tag
- Trigger 链：EventListener `tekton-demo-listener` + TriggerBinding/Template，NodePort 30080 入口
- GitOps：ArgoCD 应用 `tekton-demo-api`，部署到 ns `tekton-demo`
- 镜像：Harbor `10.0.0.41/library/tekton-demo-api`
- 代码源：GitLab `http://10.0.0.200/root/teketondemo.git`

## 2. 本次删除（ns `cicd`）

| 资源 | 类型 | 状态 |
|---|---|---|
| pipeline.tekton.dev/tekton-demo-cicd | Pipeline | ✅ 已删 |
| task.tekton.dev/git-clone-local | Task | ✅ 已删 |
| task.tekton.dev/python-test | Task | ✅ 已删 |
| eventlistener/tekton-demo-listener | EventListener | ✅ 已删，级联清理 deployment `el-tekton-demo-listener`、pod、svc `el-tekton-demo-listener` |
| service/tekton-demo-listener-nodeport | Service(NodePort 30080) | ✅ 已删，端口号已释放 |
| triggerbinding/tekton-demo-binding | TriggerBinding | ✅ 已删 |
| triggertemplate/tekton-demo-template | TriggerTemplate | ✅ 已删 |
| pvc/tekton-demo-workspace-pvc | PVC(2Gi, nfs-sc) | ✅ 已删，对应 PV 回收策略为 Delete，已自动释放 |
| secret/dockerhub-auth | Secret | ✅ 已删（集群内无任何引用） |
| 本地目录 `cloud-native-notes/devops/ci-cd/teketondemo/` | 代码工程 | ✅ 已删（用户确认直接删除） |

## 3. 明确保留（demo 时期创建但仍在服役）

| 资源 | 原因 |
|---|---|
| task.tekton.dev/build-and-push (226d) | **open-webui-cicd 流水线仍在使用** |
| task.tekton.dev/update-gitops-tag (226d) | **open-webui-cicd 流水线仍在使用** |
| secret/harbor-auth (226d) | SA `pipeline`、compassio-build-push、deeptutor-build-push 及对应 TriggerTemplate 引用 |
| SA `pipeline` + RoleBinding `pipeline-edit-binding` | 所有活跃流水线/EventListener 共用 |
| ns `cicd` | compassio / deeptutor / open-webui CI 正在运行，删除会误伤 |
| ns `tekton-pipelines` / `tekton-pipelines-resolvers` | Tekton 平台本体，活跃 CI 依赖 |

## 4. 清理前已不存在 / 不可达

- ns `tekton-demo`：早前 `kubectl delete ns tekton-demo` 已生效，本次确认为 NotFound
- ArgoCD 应用 `tekton-demo-api`：argocd 命名空间中已无此应用（现存仅 compassio / deeptutor / open-webui）
- GitLab `10.0.0.200`：网络不可达（curl 无响应），仓库 `root/teketondemo` 无法远程清理；旧 GitLab 地址已废弃，现 CI 使用 `192.168.67.201`
- Harbor `10.0.0.41`（镜像 `library/tekton-demo-api`）：网络不可达，无法经 API 清理镜像；现 Harbor 为 `192.168.67.202:8443`

## 5. 验证结果（删除后）

- `kubectl get all,pvc,secret,sa,cm,role,rolebinding,ingress -n cicd` 搜索 `demo`：无残留
- Tekton CRD（task/pipeline/pipelinerun/taskrun/eventlistener/trigger*/detail）：`tekton-demo` 命中 0 条
- NodePort 30080 已无任何 Service 占用
- 活跃项目健康检查：
  - EventListener `compassio-listener` / `deeptutor-listener`：READY=True
  - Pipeline `compassio-cicd` / `deeptutor-cicd` / `open-webui-cicd`：完好
  - 进行中的 deeptutor 流水线 `deeptutor-cicd-harbor-77b92031` 未受影响

## 6. 遗留事项

1. 若旧 Harbor `10.0.0.41` 的数据仍在某处（数据盘/NFS），`library/tekton-demo-api` 镜像未清理——当前无法访问，需待该环境恢复后手动删除。
2. 若旧 GitLab `10.0.0.200` 数据留存，仓库 `root/teketondemo` 同理。
3. open-webui-cicd 依赖的两个 226d Task（build-and-push / update-gitops-tag）与 harbor-auth Secret 在未来若该线路退役，需一并清理（见第 3 节）。
