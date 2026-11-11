# 实测基准（2026-11-11 由 Hermes 直接采集，只读）

仓库路径：仓库根（本文档位于 `docs/19-audit/assets/`）
采集方式：kubectl / curl / ceph / 本机命令。**这份基准优先于文档里的任何说法。**

## 节点
| 名字 | 角色 | IP | 版本 | 运行时 | OS | 内核 |
|---|---|---|---|---|---|---|
| m01 | control-plane | 10.0.0.61 | v1.35.9 | containerd 2.3.2 | Rocky 9.6 | 5.14.0-570.58.1.el9_6 |
| master01 | control-plane | 10.0.0.121 | v1.35.9 | containerd 2.3.2 | Ubuntu 22.04.5 | 5.15.0-202 |
| master02 | control-plane | 10.0.0.120 | v1.35.9 | containerd 2.3.2 | Ubuntu 22.04.5 | 5.15.0-202 |
| worker01 | worker | 10.0.0.122 | v1.35.9 | containerd 2.3.2 | Ubuntu 22.04.5 | 5.15.0-202 |
| worker02 | worker | 10.0.0.123 | v1.35.9 | containerd 2.3.2 | Ubuntu 22.04.5 | 5.15.0-202 |
| worker03 | worker | 10.0.0.124 | v1.35.9 | containerd 2.3.2 | Ubuntu 22.04.5 | 5.15.0-202 |

- 6/6 Ready；3 control-plane + 3 worker。m01 是 Rocky，其余 Ubuntu（异构）。
- kube-apiserver/etcd/scheduler/controller-manager 均为 **kube-system 静态 Pod**（不是外部进程）。
- etcd 镜像 **registry.k8s.io/etcd:3.6.6-0**；CoreDNS **v1.13.1**。
- kube-vip DaemonSet 存在（3 副本，仅控制面）；VIP 10.0.0.168:6443。

## CNI
- Cilium **v1.20.4**（quay.io/cilium/cilium:v1.20.4），DaemonSet 6/6，operator 2/2，hubble-relay/hubble-ui 正常。
- cilium-config 实测：kube-proxy-replacement=true、routing-mode=native、ipv4-native-routing-cidr=10.244.0.0/16、enable-bpf-masquerade=true、enable-l2-announcements=true、tunnel-protocol=vxlan（native 模式下不生效，属默认残留）、ipam=kubernetes、enable-hubble=true。
- `cilium-dbg status`：KubeProxyReplacement True，Routing: Network Native / Host BPF，Masquerading BPF [eth0] 10.244.0.0/16，Attach Mode Legacy TC，Device Mode veth，Host firewall Disabled，Controller 234/234 healthy。
- kube-proxy 已移除：kube-system 无 DaemonSet/ConfigMap/ServiceMonitor。
  **但残留无 endpoints 的 Service `kube-system/prometheus-kube-proxy`（kube-prometheus-stack chart 83.7.0 管理，292 天）。**
- L2 Announcements：CiliumL2AnnouncementPolicy `traefik-l2` 存在。

## 入口
- Traefik docker.io/traefik:v3.7.17，Deployment 1/1；Service type LoadBalancer，EXTERNAL-IP **10.0.0.252**（：30156/30306 为 NodePort）。
- MetalLB：controller 1/1 保留，speaker DaemonSet desired=0（annotation metallb.io/announcer-disabled=true）。

## GitOps / 平台
- ArgoCD **v3.5.3**（server/repo-server/appset/notifications 同版本），dex v2.45.1，redis 8.6.4-alpine。
- Application 共 **31 个，全部 Synced**。
- sealed-secrets-controller、VPA（3 组件，各 2 副本）、metrics-server、cert-manager 均在跑。
- 没有 knative 命名空间（已下线）；tekton-operator + tekton-pipelines 存在；cicd 命名空间有 buildkitd、3 个 EventListener（compassio / deeptutor / china-study-free）。
- oauth2-proxy 四个实例：traefik / hubble / alloy / tekton。

## 可观测性
- Prometheus **v3.11.2**（StatefulSet prometheus-prometheus-prometheus）、Alertmanager **v0.32.0**、Grafana **12.4.3**、prometheus-operator **v0.90.1**、kube-state-metrics **v2.18.0**、prometheus-adapter **v0.12.0**、kube-prometheus-stack chart **83.7.0**。
- **PrometheusRule 44 个（全集群）**、**ServiceMonitor 27 个（全集群）** —— README 写 41 / 14，与实测不符。
- Loki **3.6.7**（distributed：write/backend StatefulSet + read/gateway Deployment + canary），memcached 1.6.39-alpine。
- Alloy **v1.20.0**（DaemonSet，6 副本）。
- Tempo **3.0.3**（tempo-distributed：distributor / querier / query-frontend / metrics-generator Deployment，backend-scheduler / backend-worker / block-builder / live-store StatefulSet）。
- wecom-adapter：Deployment 2/2，image python:3.12-alpine。
- otel-collector 0.145.0 与 otel-operator 在 opentelemetry 命名空间。

## 存储
- Ceph **18.2.8 reef**，`ceph -s` HEALTH_OK，3 mon（ceph-01..03）、2 mgr、**6 osd**、2 rgw、3 mds、15 pools/465 pgs、465 active+clean，用量 92 GiB / 180 GiB。
- StorageClass：`ceph-rbd-sc`（rbd.csi.ceph.com，**Retain**，Immediate，allowVolumeExpansion=true，221d）、`nfs-sc`（example.com/nfs，Delete，297d）。
- **PV 17 个，全部 Bound**（与 README 一致）。
- ceph-csi 通过 ceph-csi-operator 部署（ceph-csi-operator-system + ceph-csi-rbd 命名空间）。RGW 在 10.0.0.31:7480。
- CNPG：cnpg-system 有 barman-cloud 与 cnpg-controller-manager。

## 备份
- CronJob `etcd-backup/etcd-snapshot`，`5 * * * *`（每小时），时区 Asia/Shanghai，最近 Job 均 Complete。

## GitLab / Harbor / PVE
- GitLab：**http://192.168.67.201**，`/api/v4/version` 返回 **19.5.0**，**Community Edition**（README 写 19.4.2 → 版本漂移）。仓库地址 http://192.168.67.201/digitalsupply/k8s-platform-tutorials （私有，需 token）。
- Harbor：**https://192.168.67.202:8443**，`/api/v2.0/systeminfo` 返回 auth_mode=**oidc_auth**、oidc_provider_name=**GitLab**、self_registration=false；registry /v2/ 返回 401 UNAUTHORIZED（匿名不可拉）。192.168.67.203 未监听。
- PVE：**10.0.0.1:8006 与 192.168.67.156:8006 是同一台**（同一份 proxmox 前端、同一 ver 资产）；未登录无法取 pveversion，文档写的 PVE 8.4.13 未能独立验证。SSH 到 10.0.0.1 拒绝（publickey,password）。
- Hyper-V 宿主：192.168.67.110（GitLab/Harbor 的 VM 宿主，文档 self-report，未验证）。

## 静态检查（已由 Hermes 跑过，勿重复）
- 所有 .py 通过 py_compile（0 错误）。
- 所有 .yaml/.json 可解析（0 错误）。
- 所有 .md 代码围栏成对、相对链接可达（0 断链）。
- **bash -n 只有 1 个语法错误**：docs/04-monitoring-gitops/notes/wecom-alert-receiver-20261001/apply.sh（`<redacted>` 替换把引号吃掉 + `AM_SECRET=<redacted>` 把 StatefulSet 名也脱敏了）。
- 全仓 126 处 `<redacted>`，其中 13 个 .sh、9 个 yaml 受影响。

## 审计口径
1. 本环境是"未来版本"环境（k8s 1.35、Cilium 1.20、Prometheus 3.11、GitLab 19.5）。**不要因为"我没见过这个版本"就判错**；只报能用实测/内部证据证明的问题。
2. 只报**具体、可指认**的问题：文件:行号 + 原文摘录 + 为什么错 + 证据/正确写法。
3. 重点找这几类：
   - 与实测不符的事实/版本/数量/拓扑；
   - 技术性错误：命令参数错、API 名错、YAML 字段错、公式/单位错、概念解释错（如 kube-proxy/iptables 规则、Cilium 数据面、CSI 行为、etcd 恢复、LVM/RAID 容量算法、PromQL 语义、SLO 计算）；
   - 前后自相矛盾（同一事实在不同文档里数字/结论不同）；
   - 不合理实践：危险命令无警告、把实验环境的做法说成生产最佳实践、过期/已废弃的 flag、错误的排障方向；
   - 安全/卫生问题：真实密钥未脱敏、脱敏破坏可执行性、过度宽权限。
4. 严禁对集群做任何写操作（不要 apply/delete/patch/scale/edit/exec 除只读命令）。只读：kubectl get/describe/logs/top、curl、grep、cat。
5. 不要重写文档、不要提交 commit。只产出发现清单。
