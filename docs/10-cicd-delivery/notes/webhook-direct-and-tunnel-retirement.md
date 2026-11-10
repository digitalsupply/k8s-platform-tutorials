# 21 · CI 触发链路改造：webhook 直连 + 隧道退休 + 来源校验

**日期**：2026-10-18
**范围**：`cicd/04-eventlistener.yaml`、GitLab webhook、m01 `gitlab-el-tunnel.service`、GitLab 全局设置、集群 Secret
**结论**：GitLab → Tekton 触发由「SSH 反向隧道」改为「直连 Traefik ingress（走内网路由 `10.0.0.0/24 via 192.168.67.156`，Tailscale 保留为其它流量通路）」，并顺带修掉一个**长期潜伏的 EventListener Service 冲突**、加上 **webhook 来源校验**。

---

## 一、动机

原链路：`GitLab push → http://127.0.0.1:18080/（SSH 反向隧道）→ m01 → NodePort 30081 → EL`。
问题：

1. **单点 + 脆弱**：隧道依赖 m01 的 systemd + sshd + NodePort 三者，任一挂掉 CI 静默失效。
2. **实测正在抖动**：`gitlab-el-tunnel.service` 反复 `Timeout, server 192.168.67.201 not responding` 并自动重启（restart counter 递增），而相反方向（GitLab → 集群）稳定。
3. **无来源校验**：EL 无 interceptor，任何能到达入口的主体都能伪造 push 触发构建。

---

## 二、连通性实测（改造前）

在 GitLab 主机 `ubuntu01`（192.168.67.201）上：

| 测试 | 结果 |
|---|---|
| `ip route get 10.0.0.252` | `dev tailscale0 table 52 src 100.94.131.119`（走 Tailscale） |
| `curl http://10.0.0.252/` | 404（Traefik 可达） |
| `curl -H Host:ci-compassio.xyz http://10.0.0.252/` | **400**（EL 存活） |
| `curl -X POST http://ci-compassio.xyz/` | **202**（EL 受理） |
| `getent hosts ci-compassio.xyz` | 10.0.0.252（`/etc/hosts` 已有映射） |
| 内网直连尝试 `via 192.168.67.1` | **黑洞**（curl 000，放弃） |
| 内网直连尝试 `via 192.168.67.156` | ✅ **通**（EL 400 / app 200）——正确下一跳是 `.156`，不是网关 `.1` |

→ 直连条件已具备，无需隧道；内网经 `.156` 可达，遂加静态路由走内网（Tailscale 仍作其它流量通路）。

---

## 三、变更内容

1. **GitLab webhook（project `digitalsupply/compassio`，hook id=1）**
   - `url`：`http://127.0.0.1:18080/` → **`http://ci-compassio.xyz/`**
   - 新增 `Secret token`（写入 Secret `cicd/gitlab-webhook-secret` 的 `secretToken`）
2. **`cicd/04-eventlistener.yaml`**
   - 加 `gitlab` ClusterInterceptor：校验 `X-Gitlab-Token` + 仅接受 `Push Hook`
   - **删除手工声明的 `el-compassio-listener` Service（NodePort 30081）**，改由 triggers controller 自动创建 ClusterIP
3. **m01**：`systemctl disable --now gitlab-el-tunnel.service`（隧道退休）
4. **GitLab 全局**：`allow_local_requests_from_hooks_and_services` **保持开启** —— 直连目标 `ci-compassio.xyz` 解析为私网地址 `10.0.0.252`，关掉会被 GitLab 直接拒投（详见 §四 坑 2）
5. 新增 Secret：`cicd/gitlab-webhook-secret{secretToken}`
6. **GitLab 主机内网路由**：`10.0.0.0/24 via 192.168.67.156 dev eth0`（main 表）+ ip rule
   `to 10.0.0.0/24 lookup main priority 5265`（优先于 Tailscale 的 rule 5270，仅影响该 /24，不动其它流量），
   持久化于 systemd `k8s-internal-route.service`

---

## 四、踩到的坑（重要）

**EventListener 的 Service 名与手工声明的 Service 名相同 → controller 报错 → EL 配置永远不下发。**

- 现象：`04-eventlistener.yaml` 里手工声明了 `el-compassio-listener`（NodePort 30081），而 triggers controller 也想创建同名 Service，报
  `Error creating EventListener Service: services "el-compassio-listener" already exists`，reconcile 反复失败。
- 后果：**EL 的 spec 变更（包括本次加的 interceptor）不会生效**，sink 一直跑旧配置。
- 修复：从清单里删掉手工 Service，并 `kubectl delete svc` 让 controller 接管。
- 补充：controller 处于指数退避，删 Service 后不会立刻重建 → 用
  `kubectl rollout restart deploy/tekton-triggers-controller -n tekton-pipelines` 强制 resync，随后它自动创建了 ClusterIP Service（8080/9000）并 `Ready=True`。

> 教训：**Tekton EventListener 不要手工声明它要管理的 Service**；需要 NodePort/自定义端口时用 Ingress，而不是自建 Service。

---

**坑 2：直连投递「internal error」——`allow_local_requests_from_hooks_and_services` 不能关。**

- 现象：首次真实 push 的 webhook 投递 `response_status = internal error`，且未创建 PipelineRun（但同主机 `curl` 手动 POST 却是 202）。
- 根因：直连目标 `ci-compassio.xyz` → `10.0.0.252` 属 **RFC1918 私网**；GitLab 该开关控制的是「是否允许向私网/本地地址投递」，关掉即拒投。
- 修复：置回 `true`，`resend` 事件 → 返回 **202**，PipelineRun 正常拉起。
- **注意缓存**：改回 `true` 后，**Sidekiq/WebHookWorker 仍可能持有旧的 `ApplicationSetting` 缓存**，表现为「随后的一次 push 仍被拦（`URL is blocked`），但用 API `resend` 却成功」（resend 跑在 web 进程、不走 worker 缓存）。等缓存过期后，真实 push 即恢复正常。
- 教训：**只要 webhook 目标是私网地址，这个开关就必须保持开启**。若要收窄 SSRF 面，用出站 allowlist（`outbound_local_requests_allowlist`）精确放行，而不是整体关闭。

---

## 五、验证证据

| 项 | 结果 |
|---|---|
| EL 状态 | `Available/Deployment/Progressing/Ready/Service` 全 `True` |
| Service | ClusterIP，controller 托管（owner=Controller） |
| ingress 直连 | `GET -H Host:ci-compassio.xyz http://10.0.0.252/` → 400 |
| interceptor 拦截 | 无 token / 错 token / 错事件类型 → `Continue:false`（事件丢弃） |
| 拦截不误伤 | 错 token + **合法 payload** → 未创建 PipelineRun（delta=0） |
| **端到端（真实 push）** | 首次 `7331b6a` 因开关被关 → `URL is blocked`；置回后 `resend` → **202** → `compassio-triggered-ptbx2` 拉起；缓存过期后再 push 正常投递 |
| 隧道 | `inactive / disabled`；GitLab 主机 18080 不再监听 |
| 内网路由 | `ip route get 10.0.0.252` → `via 192.168.67.156 dev eth0`；Tailscale peer 仍走 `tailscale0 table 52`（不冲突） |
| webhook（内网路径） | 真实投递 **202** |

---

## 六、回退方法

```bash
# 1) 恢复 NodePort（应急，会与 controller 冲突，尽量短暂）
kubectl -n cicd expose deploy el-compassio-listener --type=NodePort \
  --name=el-compassio-listener-np --port=8080 --target-port=8080
# 2) 起隧道
systemctl enable --now gitlab-el-tunnel.service      # m01
# 3) GitLab webhook url 改回 http://127.0.0.1:18080/（并临时打开 allow_local_requests_...）
# 4) 去掉内网路由、恢复走 Tailscale：
ssh root@192.168.67.201 systemctl disable --now k8s-internal-route.service
```

---

## 七、遗留 / 后续

- **CI 仍无质量门禁**：Pipeline 里没有 `pytest`/`npm build` 任务（见 `docs/20` P0#3），未过测代码仍会被构建上线——本次未动，建议优先补。
- **内网路由已加**（`via 192.168.67.156`，见 §三-6）；Tailscale 仍保留用于其它流量，本次未移除。
- **敏感信息仍在 git**：`compassio-app-secrets`（含 SECRET_KEY/LLM_API_KEY）仍以明文 `stringData` 落在 gitops 仓（见 `docs/20` P0#2）。
- **Harbor TLS 校验仍跳过**（`registry.insecure`），见 `docs/20` P0#4。
