# 23 · BuildKit 构建器排障与切换纪要

**日期**：2026-10-20
**范围**：`cicd/01-tasks.yaml`、`cicd/06-buildkit.yaml`、`cicd/99-kaniko-tasks.yaml.bak`、`buildkitd`、Harbor
**结论**：查清「2026-10-14 起实际一直是 Kaniko、BuildKit 起不来」的根因——**`buildctl` 客户端自身的 CA 信任库没有 Harbor 自签 CA**（不是 daemon 的问题）。修复后已切回 **BuildKit**，并成功完成一次真实构建。

---

## 一、结论速览

| 项 | 切换前（10-14 ~ 10-20） | 切换后（10-20） |
|---|---|---|
| 集群 `Task/compassio-build-push` | Kaniko `openwebui/kaniko:v1.23.2` | **BuildKit** `compassio/buildkit:v0.20.2-rootless` |
| `cicd/01-tasks.yaml`（repo） | BuildKit（**与集群漂移**） | BuildKit（已 apply，一致） |
| 真正建镜像的 | Kaniko | **BuildKit** |
| TLS 校验 | Kaniko 全跳过（`--skip-tls-verify` 等） | **BuildKit 已校验**（去掉 `registry.insecure`） |
| 根因 | daemon CA + **客户端 CA** 双层问题，只修了 daemon 侧 | 客户端注入 `harbor-ca` + `SSL_CERT_FILE` |
| 证据 | `compassio/cache` 持续写入（Kaniko cache-repo） | 镜像 history 含 7~11 条 `# buildkit` |

---

## 二、切片前的实态与证据链

**结论**：那 6 天里所有应用镜像都是 **Kaniko** 构建的，BuildKit 只是"部署着但没被调用"。

| 证据 | 实测内容 |
|---|---|
| 集群 Task | `steps[0].image = 192.168.67.202:8443/openwebui/kaniko:v1.23.2`；args 含 `--destination --insecure --skip-tls-verify --cache=true --cache-repo=... --single-snapshot` |
| 构建 Pod | `compassio-triggered-*-build-push-backend-pod` 容器镜像 = `.../openwebui/kaniko@sha256:8a4f9af8...` |
| 构建日志 | `INFO[0000] Retrieving image manifest ...`、`Taking snapshot of full filesystem`、`Pushing image to ...` —— Kaniko 输出格式 |
| Harbor cache 仓 | `compassio/cache` 持续写入（`--cache-repo`），且与每次 run 时间同步 |
| 镜像 config | backend `layers=5`、frontend `layers=9`；新增 history 仅 1 条、`created=0001-01-01`、无 `# buildkit` —— `--single-snapshot` 特征 |
| buildkitd 日志 | 只有 2026-10-14T10:04:17 的 `x509: certificate signed by unknown authority`，之后无成功构建 |
| 集群 last-applied | 是 Kaniko 版 —— 说明实际 apply 的是 `99-kaniko-tasks.yaml.bak` |

---

## 三、时间线（从 git 与日志还原）

```
2026-10-14 07:42  6ff45d4  初始实现：Kaniko
2026-10-14 08:59  e73eaec  改 BuildKit（buildctl）
2026-10-14 09:52  4255707  pin 到 Harbor 内的 compassio/buildkit 镜像
2026-10-14 09:48          创建 ConfigMap buildkitd-ca（daemon 侧 CA）
2026-10-14 10:02:54       buildkitd 启动（此后未重启）
2026-10-14 10:04:17       BuildKit 构建失败：x509 unknown authority
2026-10-14 ~ 10-20       回滚 .bak（Kaniko），一直沿用；repo 与集群从此漂移
2026-10-20               诊断：发现客户端 CA 才是真正卡点 -> 修复 -> 切回 BuildKit
```

---

## 四、根因分析（两层，缺一不可）

### 4.1 第一层：daemon 侧的 Harbor CA（当时已埋下，现已 OK）

- 现象：`failed to fetch oauth token: <redacted> "https://192.168.67.202:8443/service/token": x509: certificate signed by unknown authority`。
- daemon 侧配置：
  ```toml
  # buildkitd.toml
  [registry."192.168.67.202:8443"]
    ca = ["/bundle/ca-bundle.crt"]
  ```
- 当前实测：`/bundle/ca-bundle.crt` 与 `/etc/ssl/certs/ca-certificates.crt` 均含 **141 张证书**，且 Harbor CA 在列（fingerprint 与 Harbor 实际证书一致）。
- **在 daemon pod 内部**用 `buildctl` 直接构建 → **成功**。证明 daemon 侧现已没问题。

### 4.2 第二层（真正卡点）：`buildctl` **客户端**的 CA

- 现象：把 Task 切回 BuildKit 后，`buildctl` 运行在**独立客户端 Pod** 里，仍然报**同一个 x509**。
- 对照实验：

| 客户端位置 | 结果 |
|---|---|
| 在 `buildkitd` pod 内部（继承 daemon 的 141 张证书） | ✅ 成功（pull + push） |
| 独立客户端 pod（buildkit 镜像默认 CA 库） | ❌ `x509: certificate signed by unknown authority` |
| 独立客户端 pod + `SSL_CERT_FILE=/etc/harbor-ca/ca.crt` | ✅ 成功 |
| 独立客户端 pod + 合并 bundle + 去掉 `registry.insecure=true` | ✅ 成功（TLS 真正校验） |

- **原理**：`buildctl` 客户端会参与 registry 的 **token 交换**（`/service/token` 的 TLS 在客户端侧完成），而客户端镜像里只有公共 CA，没有 Harbor 自签 CA。daemon 的 `buildkitd.toml` 的 `ca` 只覆盖 daemon 侧。
- 另有干扰项：客户端必须能读到 `harbor-auth`（`DOCKER_CONFIG=/root/.docker`），否则是 **401 Unauthorized**（与 x509 是两回事）。

> 这就是"之前为什么一直起不来"的完整答案：**只修了 daemon 侧 CA，没修客户端侧 CA**。

---

## 五、修复（已落地）

修改 `cicd/01-tasks.yaml` 的 `compassio-build-push`：

```yaml
steps:
  - name: build
    image: 192.168.67.202:8443/compassio/buildkit:v0.20.2-rootless
    workingDir: $(workspaces.source.path)/$(params.context)
    env:
      - { name: DOCKER_CONFIG,  value: /root/.docker }
      - { name: BUILDKIT_HOST,  value: tcp://buildkitd.cicd.svc.cluster.local:1234 }
    securityContext: { runAsUser: 0 }
    volumeMounts:
      - { name: docker-config, mountPath: /root/.docker }
      - { name: harbor-ca,     mountPath: /etc/harbor-ca, readOnly: true }
    script: |
      #!/bin/sh
      set -eu
      # buildctl 客户端自己做 registry token 交换；客户端镜像 CA 库没有 Harbor 自签 CA
      cat /etc/ssl/certs/ca-certificates.crt /etc/harbor-ca/ca.crt > /tmp/ca-bundle.crt
      export SSL_CERT_FILE=/tmp/ca-bundle.crt
      buildctl build \
        --frontend dockerfile.v0 \
        --local "context=$(pwd)" \
        --local "dockerfile=$(pwd)" \
        --opt "filename=$(params.dockerfile)" \
        --output "type=image,name=$(params.image),push=true" \
        --export-cache type=inline
      echo "Pushed image: $(params.image)"
volumes:
  - name: docker-config
    secret:
      secretName: harbor-auth
      items: [{ key: .dockerconfigjson, path: config.json }]
  - name: harbor-ca
    configMap: { name: harbor-ca }
```

要点：
1. **挂 `harbor-ca` ConfigMap** 到 `/etc/harbor-ca`。
2. **合并**系统 CA + Harbor CA，用 `SSL_CERT_FILE` 指过去（Go 的默认根证书池）。
3. **去掉 `registry.insecure=true`** —— TLS 已能校验，安全面收窄（实测通过）。

应用：

```bash
kubectl apply -f cicd/01-tasks.yaml
kubectl get task compassio-build-push -n cicd -o jsonpath='{.spec.steps[0].image}{"\n"}'
```

---

## 六、验证（真实构建）

手工触发一次（同 commit，`promote` 自动幂等，不改 GitOps）：

```bash
SHA=$(git rev-parse HEAD)
kubectl create -f - <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata: { generateName: compassio-buildkit-verify-, namespace: cicd }
spec:
  params:
    - { name: git-url, value: "http://192.168.67.201/digitalsupply/compassio.git" }
    - { name: git-revision, value: "$SHA" }
    - { name: image-tag, value: "$SHA" }
  pipelineRef: { name: compassio-cicd }
  taskRunTemplate:
    serviceAccountName: pipeline
    podTemplate:
      nodeSelector: { kubernetes.io/hostname: worker03 }
      tolerations: [ { key: node-role.kubernetes.io/control-plane, operator: Exists } ]
      imagePullSecrets: [ { name: harbor-auth } ]
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec: { accessModes: [ReadWriteOnce], resources: { requests: { storage: 2Gi } }, storageClassName: nfs-sc }
EOF
```

结果（`compassio-buildkit-verify-r7pfj`）：

| TaskRun | 结果 | 耗时 |
|---|---|---|
| clone | Succeeded | 7s |
| build-push-backend | Succeeded | 272s（其中 `apt-get` 202s、`pip install` 42s）|
| build-push-frontend | Succeeded | 94s |
| promote-gitops | Succeeded | 8s（tag 未变，幂等）|

镜像元数据（BuildKit 特征）：

| 镜像 | 层数 | history | 含 `# buildkit` |
|---|---|---|---|
| `backend:537725f…` | **9**（Kaniko 时 5）| **17**（Kaniko 时 11）| **7** |
| `frontend:537725f…` | **11**（Kaniko 时 9）| **24**（Kaniko 时 20）| **11** |

---

## 七、回滚

```bash
# 回 Kaniko（保留为应急路径）
kubectl apply -f cicd/99-kaniko-tasks.yaml.bak
kubectl get task compassio-build-push -n cicd -o jsonpath='{.spec.steps[0].image}{"\n"}'
```

> 注意：`.bak` 用的还是 `--skip-tls-verify --insecure --insecure-pull`，安全面更宽。

---

## 八、注意事项与后续

1. **客户端 CA 是硬要求**：只要 `buildctl` 跑在独立 Pod，就必须注入 Harbor CA（`SSL_CERT_FILE`）；换节点、换客户端镜像、换 Harbor 证书后都要记得。
2. **daemon CA 与客户端 CA 是两套**：`buildkitd.toml` 的 `ca` 只管 daemon；客户端靠 `SSL_CERT_FILE`/系统信任库。
3. **BuildKit 缓存仍是 `emptyDir`**：buildkitd 重启即丢，建议改 PVC（`nfs-sc`/`ceph-rbd`）。
4. **`--export-cache type=inline`**：无独立 registry cache；若跨节点/多副本，考虑 `--export-cache type=registry,ref=...`。
5. **安全面**：daemon 仍是 `seccompProfile: Unconfined` + `--oci-worker-no-process-sandbox`；Task 仍 `runAsUser: 0`（见 `docs/20 §六-11`）。
6. **Harbor 换正式证书后**：可移除 `harbor-ca` 注入，但客户端仍需信任正式 CA（系统库自带）。
7. **文档已同步**：`docs/20`、`docs/22` 已纠正"BuildKit 现役 / Kaniko 备选"的表述，并写入本次排障结论。

---

## 九、后续加固（2026-10-20）

切回 BuildKit 后，按 `docs/20 §七-8/11` 的建议做了四项加固，并记录了两次"不可行"的尝试。

### 9.1 缓存：`emptyDir` → `hostPath`（两条 PVC 路都不通）

| 方案 | 结果 |
|---|---|
| `emptyDir`（原） | 可用，但 buildkitd 重启即丢 |
| `nfs-sc` PVC | ❌ `failed to Lchown ...: operation not permitted` —— rootless snapshotter 在 NFS 上无法 chown |
| `ceph-rbd-sc` PVC | ❌ `CSINode m01 does not contain driver rbd.csi.ceph.com`（CSI 节点插件未装在 m01）|
| **`hostPath /var/lib/buildkitd-cache`** | ✅ 可用；initContainer `chown 1000:1000`；**跨 Pod 重启保留** |

### 9.2 资源限额
`requests: 500m/1Gi`，`limits: 2/4Gi`（m01 可分配 4C/5.7G，余量充足）。

### 9.3 seccomp：`RuntimeDefault` 不可行

实测报：
```
rootlesskit: failed to start the child: fork/exec /proc/self/exe: operation not permitted
```
`Unconfined` 是 rootless buildkit 的硬约束，已在 `06-buildkit.yaml` 中注明原因。

### 9.4 客户端非 root

- 去掉 `securityContext.runAsUser: 0`。
- `DOCKER_CONFIG=/home/user/.docker`，`harbor-auth` 挂到同一路径。
- 用镜像默认 uid 1000（buildkit 镜像 `USER 1000:1000`）。
- 实测 backend/frontend 构建均成功。

### 9.5 验证结果

| 场景 | 结果 |
|---|---|
| 冷缓存（hostPath 空） | `compassio-harden-verify-bvbzx` **Succeeded**，约 4m38s |
| 重启 buildkitd（删 Pod） | 缓存 1.3G **保留** |
| 热缓存 | `compassio-harden-warm-lkw58` **Succeeded**，约 **25s**，日志全 `CACHED` |
| 非 root 客户端 | 构建成功；Task pod 无 `runAsUser: 0` |

---

## 十、命令速查

```bash
# 现役构建器
kubectl get task compassio-build-push -n cicd -o jsonpath='{.spec.steps[0].image}{"\n"}'

# 最近构建 pod 的镜像
kubectl get pods -n cicd -o json | jq -r '.items[]|select(.metadata.name|test("build-push-backend-pod"))|.metadata.name+"  "+.spec.containers[0].image' | tail -3

# 构建日志（BuildKit 是 #n [x/y] 格式）
kubectl logs -n cicd <build-pod> -c step-build | head -20

# 判断镜像由谁构建（看 history 是否含 # buildkit）
#   Kaniko: 新增 1 层、history 1 条、created=0001-01-01、无 # buildkit
#   BuildKit: 多条目、含 # buildkit、created 为构建时间

# buildkitd 健康
kubectl exec -n cicd deploy/buildkitd -- buildctl --addr tcp://127.0.0.1:1234 debug workers
kubectl logs -n cicd deploy/buildkitd --tail=50
```
