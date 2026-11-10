# K8s 平台工程实战教程

这是一套从真实集群排障和 GitOps 改造过程中整理出来的教程，不是纯理论笔记。
每个分类都保留了**当时的环境、踩过的坑、修复的关键动作，以及背后的概念和原理**。

> 最后整理：2026-11-10
> 案例环境：kubeadm Kubernetes v1.35.9，3 control-plane + 3 worker；
> Cilium 1.20.4；ArgoCD v3.5.3；kube-prometheus-stack 83.7.0；
> prometheus-operator 0.90.1。

---

## 目录

| 分类 | 内容 | 适合谁 |
|---|---|---|
| [01 Kubernetes / k3s](docs/01-kubernetes-k3s/README.md) | k3s 集群进程模型、Pod 启动链路、Pod 与宿主机进程/命名空间/cgroup 的对应关系、Pod/Service 网段 | 想真正“看懂” Pod 是怎么跑起来的人 |
| [02 Cilium / eBPF](docs/02-cilium-ebpf/README.md) | eBPF 四大核心概念、Cilium BPF LB、ipcache、nodeid、VXLAN、Hubble/tcpdump 路径验证 | 需要排查 Service/NodePort/LB 网络的人 |
| [03 GitLab](docs/03-gitlab/README.md) | GitLab CE 19.4 安装、8088/80 端口排查、Cilium 遗留规则清理、80→8088 重定向 | 运维 GitLab / 处理端口冲突的人 |
| [04 Monitoring GitOps](docs/04-monitoring-gitops/README.md) | PrometheusRule/Alertmanager/WeCom 链路、kube-prometheus-stack 整体纳入 ArgoCD、CRD GitOps、告警白名单 | 做 K8s 可观测性和 GitOps 的人 |
| [05 Linux](docs/05-linux/README.md) | su/sudo、PAM、setuid、无密码 SSH、root shell 的原理与安全边界 | Linux 基础/权限排查 |

---

## 怎么读

每个分类的 `README.md` 都按同一结构组织：

1. **当时的情况**：为什么要做、改造前是什么状态；
2. **主要概念与原理**：理解问题需要的背景；
3. **踩坑点**：现象、根因、错误做法；
4. **修复关键**：真正解决问题的动作；
5. **文档列表**：该分类下的详细过程记录。

建议顺序：

- 先读分类 README，建立地图；
- 再按需读具体文档；
- 最后看 `04-monitoring-gitops/04-current-state.md`，了解当前集群状态。

---

## 当前集群状态（节选）

> 完整状态见 [04-monitoring-gitops/04-current-state.md](docs/04-monitoring-gitops/04-current-state.md)

| 项 | 状态 |
|---|---|
| ArgoCD 应用 | 31 个；监控相关 5 个全部 `Synced/Healthy` |
| `platform-monitoring-stack` | Synced / Healthy |
| `platform-monitoring-crds` | Synced / Healthy，10 个 CRD |
| `platform-monitoring-rules` | Synced / Healthy，6 个自建规则 |
| PrometheusRule | 44 个，全部带 `platform.gitops/managed=true` |
| Prometheus | 68 groups / 251 alerting rules / 0 health 异常 |
| `ruleSelector` | `release=prometheus` + `platform.gitops/managed=true` |
| `alertmanagerConfigSelector` | `platform.gitops/managed=true` |
| CRD 版本 | prometheus-operator 0.90.1 |
| Alertmanager 通知 | n8n + 企业微信（`continue: true`） |

> 集群里还有一个 `platform-sso-oauth2-proxy` 在 Progressing，属于监控改造之外的
> 独立应用，不影响本文档的监控结论。

---

## 脱敏与免责声明

- 文档中的 `10.x.x.x`、`192.168.x.x`、`*.k8s.local` 等均为实验环境地址，
  属于 RFC1918 私有网段，不能从公网访问；请替换成你自己的环境。
- 所有真实密码、token、webhook URL、私钥都已替换为
  `<redacted-...>` 或 `example.invalid`。
- 命令中的命名空间、release 名、镜像版本需要按你的环境调整。
- 生产环境操作前请先在测试集群验证，尤其是 CRD 升级、PVC 迁移、
  NetworkPolicy 和 iptables 清理。

---

## 目录结构

```text
k8s-platform-tutorials/
├── README.md
└── docs/
    ├── 01-kubernetes-k3s/
    ├── 02-cilium-ebpf/
    ├── 03-gitlab/
    ├── 04-monitoring-gitops/
    └── 05-linux/
```

每个分类目录下都有：

- `README.md`：分类导读（情况/原理/坑/修复）；
- 若干篇原始过程记录：命令、输出、时间线、验证。
