# 03 · GitLab：安装、端口 80 与 Cilium 遗留规则

> 账号体系、Token、Webhook、CI/CD 到 GitOps，以及 Harbor 的账号/镜像仓库，
> 见 [14 GitLab / Harbor](../14-gitlab-harbor/README.md)。

## 当时的情况

在实验节点上安装 **GitLab CE 19.4.2（Omnibus）**。
环境里同时运行 Cilium，端口 80 被占用/受 Cilium 的 eBPF/iptables 规则影响，
GitLab 最初监听 **8088**。目标是把 GitLab 切到 80，过程中遇到：

- 改了 `external_url` 但 nginx 仍然监听 8088；
- Cilium 的 iptables/nftables 规则与端口行为相互影响；
- 清理 Cilium 规则后，集群网络和 GitLab 访问都出现变化；
- 最终选择保留 8088，并在 80 上做重定向。

这个案例的价值不在“GitLab 怎么装”，而在于**端口冲突排查和清理 CNI 规则的边界**。

## 主要概念与原理

### 1. Omnibus GitLab

GitLab Omnibus 把 nginx、puma、sidekiq、postgres、redis 等打包在一起，
统一由 `gitlab-ctl reconfigure` 生成配置。

关键配置：

```ruby
external_url 'http://<host>:8088'
nginx['listen_port'] = 8088
nginx['listen_https'] = false
```

- `external_url` 决定对外 URL；
- `nginx['listen_port']` 才决定 nginx 实际监听端口；
- 两者不一致时，会出现“配置看起来改了，但端口没变”。

### 2. Cilium 与 iptables/nftables

Cilium 的 eBPF 数据面可能绕过部分 iptables 链，但仍然会创建/使用一些
iptables/nftables 规则（例如 NodePort、masquerade、策略相关）。
清理这些规则会影响集群网络，不能只把它当成“GitLab 的端口问题”。

### 3. 端口占用判断

```bash
ss -lntp | grep ':80 '
ss -lntp | grep ':8088 '
iptables-save | grep -i cilium
nft list ruleset | grep -i cilium
```

要区分：

- 进程监听（nginx）；
- iptables/nftables 规则；
- Cilium LB/NodePort；
- 本机对自身 IP 的访问路径。

### 4. GitLab 仓库访问的三种凭据

| 方式 | 凭据 | 适用 |
|---|---|---|
| HTTPS + PAT | 用户名 + Personal Access Token | 临时/脚本/CI |
| SSH Key | 私钥 + 公钥注册 | 开发者本机、长期 |
| Deploy Token / Project Access Token | 项目级 token | 只读部署、ArgoCD |

关键区别：

- **PAT 是用户身份**，权限跟人走；Deploy Token 是项目身份，人走了仍然有效；
- **Deploy Token 默认只读**（`read_repository`），要推代码必须显式给 `write_repository`；
- ArgoCD 拉私有仓库用 repository Secret，`password` 填 PAT/Deploy Token，不是登录密码。

### 5. ArgoCD 仓库凭据

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: platform-gitops-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: http://192.168.67.201/digitalsupply/platform-gitops.git
  username: <USERNAME>
  password: <PAT-OR-DEPLOY-TOKEN>
  insecure: "true"      # 自签 HTTP/HTTPS 时
```

## 踩坑点

### 坑 1：只改 `external_url`

`external_url` 改了，但 `nginx['listen_port']` 还是 8088，端口不会变。
必须同时改 `listen_port`，再 `gitlab-ctl reconfigure`。

### 坑 2：把 Cilium 规则当垃圾直接清

Cilium 规则可能承载 NodePort/LB/策略功能。清理前要备份，
并确认集群里没有依赖这些规则的流量。

### 坑 3：80 端口“看起来没被占用”

`ss` 没看到进程，不代表没有 iptables/nftables 重定向或 Cilium LB。
要同时看 `ss`、`iptables-save`、`nft list ruleset`。

### 坑 4：本机访问和节点 IP 访问结果不同

`127.0.0.1:80` 和 `<node-ip>:80` 可能走不同规则。
排查时要用 `curl -v` 分别测试，并看目标 IP/端口。

### 坑 5：`reconfigure` 不是瞬间完成

GitLab reconfigure 会重启多个服务；端口切换期间可能短暂不可用。
不要在业务高峰期操作。

### 坑 6：把 PAT 当登录密码用

HTTPS clone 时 `Username` 可以是任意非空值（建议填真实用户名），`Password` 填 PAT；
填 GitLab 登录密码会 401。CI 里不要把 PAT 写进 `.git/config` 或命令行参数，
用 `credential.helper store` 也有落盘风险。

### 坑 7：Deploy Token 权限不足

只给 `read_repository` 的 Deploy Token 只能拉取；ArgoCD 如果还要回写 GitOps 仓，
需要 `write_repository`，或者改用 Project Access Token。

### 坑 8：HTTP 的 GitLab 与 `insecure` 标记

自建 GitLab 常用 HTTP 或自签 HTTPS。ArgoCD 仓库 Secret 必须带 `insecure: "true"`，
否则报 `x509: certificate signed by unknown authority` 或 `server certificate verification failed`。
但这只应用于内网实验环境，生产应配受信任证书。

## 修复关键

1. **先确认目标**：是否真的必须用 80；如果只是访问方便，80→8088
   重定向是更小的改动。
2. **改 GitLab 配置**：`external_url` + `nginx['listen_port']` 同时改。
3. **清理 Cilium 规则前备份**：`iptables-save`、`nft list ruleset`。
4. **分层验证**：`ss` → `iptables/nftables` → `curl` → 浏览器。
5. **保留回滚路径**：记录原配置和规则，必要时恢复 8088。

## 配套脚本

[`scripts/check_ports.py`](scripts/check_ports.py)

```bash
sudo python3 scripts/check_ports.py \
  --ports 80,8088 \
  --urls http://127.0.0.1:8088,http://<node-ip>:8088
```

只读收集：`ss` 监听、iptables、nftables、HTTP 探测、`gitlab-ctl status`。
不会修改任何规则。

## 补充：GitLab 在交付链路中的位置（当前环境）

GitLab 服务本身不在 K8s 里，而是跑在宿主机 `192.168.67.201`（GitLab CE 19.4.2，Omnibus）。
集群里只有 **GitLab Runner** 和 Tekton，分工如下：

```text
开发者 git push
      │
      ▼
GitLab 192.168.67.201（代码仓 + Webhook）
      │  webhook
      ▼
Traefik 10.0.0.252 → Tekton EventListener（ns=cicd）
      │
      ▼
Tekton Pipeline → BuildKit → Harbor 192.168.67.202:8443
      │                          │
      │                          └─ 镜像 tag = commit SHA
      ▼
GitOps 仓（overlays/prod）→ ArgoCD → K8s 滚动发布
```

- GitLab Runner 使用 **Kubernetes executor**，运行在 `gitlab-runner` 命名空间；
- runner 的 `runners.toml` 存在 ConfigMap `gitlab-runner-config` 中，token 已脱敏；
- Helm Hub 镜像通过 `harbor-auth` imagePullSecret 拉取；
- 完整的 push→构建→GitOps→上线链路、BuildKit 排障、webhook 中断恢复，见
  [10-cicd-delivery](../10-cicd-delivery/README.md)。

## 配套资产

| 资产 | 说明 |
|---|---|
| [scripts/check_ports.py](scripts/check_ports.py) | 只读检查端口监听、iptables/nftables、HTTP 探测、GitLab 服务状态 |
| [assets/gitlab-runner-deployment.yaml](assets/gitlab-runner-deployment.yaml) | 当前 GitLab Runner Deployment（已脱敏） |
| [assets/gitlab-runner-config.yaml](assets/gitlab-runner-config.yaml) | 当前 runner `runners.toml` ConfigMap（token 已脱敏） |
| [assets/argocd-repo-secret.example.yaml](assets/argocd-repo-secret.example.yaml) | ArgoCD 仓库凭据示例（PAT/Deploy Token） |

## 文档列表

| 文档 | 内容 |
|---|---|
| [gitlab-19.4-install.md](gitlab-19.4-install.md) | GitLab CE 19.4.2 Omnibus 安装全过程 |
| [gitlab-port80-explanation.md](gitlab-port80-explanation.md) | 为什么没有直接用 80 端口 |
| [gitlab-port-80-troubleshooting.md](gitlab-port-80-troubleshooting.md) | 8088→80 的完整排查时间线 |
| [gitlab-fix-port80.md](gitlab-fix-port80.md) | 清理 Cilium 遗留规则并测试 80 |
| [gitlab-port80-cleanup-final.md](gitlab-port80-cleanup-final.md) | 最终方案：80→8088 重定向与清理总结 |
| [notes/gitlab-repo-access-tutorial-2026-11-09.md](notes/gitlab-repo-access-tutorial-2026-11-09.md) | SSH / HTTPS PAT / Deploy Token、ArgoCD 凭据与排错 |

> 安装文档中的初始 root 密码已脱敏；实际部署请立即修改默认密码。
