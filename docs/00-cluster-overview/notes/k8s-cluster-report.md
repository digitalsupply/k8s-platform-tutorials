# Kubernetes 集群基本信息报告

> 生成时间: 2026-09-27  
> 集群 API Server: `https://10.0.0.168:6443`

---

## 1. 集群概览

| 项目 | 值 |
|------|-----|
| **Kubernetes 版本** | v1.29.8 |
| **Git Commit** | 234bc63696ad15dcf62584b6ba48671bf0f25fb6 |
| **构建日期** | 2024-08-14 |
| **Go 版本** | go1.22.5 |
| **平台** | linux/amd64 |
| **容器运行时** | containerd://1.7.22 |
| **CoreDNS 地址** | `https://10.0.0.168:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy` |
| **集群健康状态** | ✅ 所有组件正常 (ping, etcd, informer-sync, poststarthook 等全部 ok) |

---

## 2. 节点信息

### 2.1 节点列表

| 节点名 | 状态 | 角色 | 版本 | 内网 IP | OS | 内核版本 | 容器运行时 | 运行时长 |
|--------|------|------|------|---------|-----|----------|------------|----------|
| m01 | Ready | control-plane | v1.29.8 | 10.0.0.61 | Rocky Linux 9.6 | 5.14.0-570.58.1.el9_6.x86_64 | containerd://1.7.22 | 253d |
| master01 | Ready | control-plane | v1.29.8 | 10.0.0.121 | Ubuntu 22.04.5 LTS | 5.15.0-179-generic | containerd://1.7.22 | 253d |
| master02 | Ready | control-plane | v1.29.8 | 10.0.0.120 | Ubuntu 22.04.5 LTS | 5.15.0-179-generic | containerd://1.7.22 | 253d |
| worker01 | Ready | worker | v1.29.8 | 10.0.0.122 | Ubuntu 22.04.5 LTS | 5.15.0-179-generic | containerd://1.7.22 | 253d |
| worker02 | Ready | worker | v1.29.8 | 10.0.0.123 | Ubuntu 22.04.5 LTS | 5.15.0-179-generic | containerd://1.7.22 | 253d |
| worker03 | Ready | worker | v1.29.8 | 10.0.0.124 | Ubuntu 22.04.5 LTS | 5.15.0-179-generic | containerd://1.7.22 | 253d |

### 2.2 节点污点 (Taints)

| 节点 | 污点 |
|------|------|
| m01 | `node-role.kubernetes.io/control-plane:NoSchedule` |
| master01 | `node-role.kubernetes.io/control-plane:NoSchedule` |
| master02 | `node-role.kubernetes.io/control-plane:NoSchedule` |
| worker01 | 无 |
| worker02 | 无 |
| worker03 | 无 |

### 2.3 节点标签 (Labels)

| 节点 | 关键标签 |
|------|----------|
| m01 | `kubernetes.io/hostname=m01`, `node-role.kubernetes.io/control-plane=` |
| master01 | `kubernetes.io/hostname=master01`, `node-role.kubernetes.io/control-plane=` |
| master02 | `kubernetes.io/hostname=master02`, `node-role.kubernetes.io/control-plane=` |
| worker01 | `kubernetes.io/hostname=worker01`, `dedicated=high-mem`, `zone=test-a` |
| worker02 | `kubernetes.io/hostname=worker02`, `dedicated=general`, `zone=test-b` |
| worker03 | `kubernetes.io/hostname=worker03`, `dedicated=general`, `zone=test-a` |

### 2.4 节点资源使用

| 节点 | CPU 使用 | CPU% | 内存使用 | 内存% |
|------|----------|------|----------|-------|
| m01 | 419m | 10% | 3543Mi | 63% |
| master01 | 264m | 6% | 2639Mi | 45% |
| master02 | 897m | 22% | 2557Mi | 67% |
| worker01 | 415m | 6% | 3689Mi | 37% |
| worker02 | 442m | 7% | 4143Mi | 42% |
| worker03 | 245m | 6% | 2052Mi | 26% |

---

## 3. 命名空间 (Namespaces)

| 命名空间 | 状态 | 运行时长 | 用途说明 |
|----------|------|----------|----------|
| argocd | Active | 252d | ArgoCD 持续交付 |
| ceph-csi-rbd | Active | 177d | Ceph RBD CSI 存储插件 |
| cert-manager | Active | 208d | 证书管理 |
| cicd | Active | 196d | CI/CD Tekton 流水线 |
| cnpg-system | Active | 177d | CloudNativePG 数据库 |
| default | Active | 253d | 默认命名空间 |
| gitlab-runner | Active | 252d | GitLab Runner |
| kafka | Active | 113d | Kafka (Strimzi) |
| knative-eventing | Active | 113d | Knative Eventing |
| knative-operator | Active | 114d | Knative Operator |
| knative-serving | Active | 114d | Knative Serving |
| kube-node-lease | Active | 253d | 节点租约 |
| kube-public | Active | 253d | 公共访问 |
| kube-system | Active | 253d | 系统组件 |
| kubernetes-dashboard | Active | 253d | K8s Dashboard |
| logging | Active | 174d | 日志系统 (Loki + Tempo + Promtail) |
| metallb-system | Active | 253d | MetalLB 负载均衡 |
| monitoring | Active | 247d | 监控 (Prometheus + Grafana) |
| n8n | Active | 176d | n8n 工作流自动化 |
| nfs-provisioner | Active | 252d | NFS 存储供应器 |
| opentelemetry | Active | 208d | OpenTelemetry 可观测性 |
| shop | Active | 109d | 商店应用 |
| tekton-demo | Active | 100d | Tekton 演示 |
| tekton-pipelines | Active | 242d | Tekton Pipelines |
| tekton-pipelines-resolvers | Active | 242d | Tekton 远程解析器 |
| tf-space | Active | 154d | Terraform 工作空间 |
| traefik | Active | 253d | Traefik 入口控制器 |

---

## 4. 工作负载 (Workloads)

### 4.1 Deployments

| 命名空间 | 名称 | 就绪 | 更新 | 可用 | 运行时长 |
|----------|------|------|------|------|----------|
| argocd | argocd-applicationset-controller | 1/1 | 1 | 1 | 252d |
| argocd | argocd-dex-server | 1/1 | 1 | 1 | 252d |
| argocd | argocd-notifications-controller | 1/1 | 1 | 1 | 252d |
| argocd | argocd-redis | 1/1 | 1 | 1 | 252d |
| argocd | argocd-repo-server | 1/1 | 1 | 1 | 252d |
| argocd | argocd-server | 1/1 | 1 | 1 | 252d |
| ceph-csi-rbd | ceph-csi-rbd-provisioner | 1/1 | 1 | 1 | 177d |
| cert-manager | cert-manager | 1/1 | 1 | 1 | 208d |
| cert-manager | cert-manager-cainjector | 1/1 | 1 | 1 | 208d |
| cert-manager | cert-manager-webhook | 1/1 | 1 | 1 | 208d |
| cicd | el-tekton-demo-listener | 1/1 | 1 | 1 | 196d |
| cnpg-system | cnpg-controller-manager | 1/1 | 1 | 1 | 177d |
| default | autoscale-demo-00003-deployment | 0/0 | 0 | 0 | 113d |
| default | hello-00001-deployment | 0/0 | 0 | 0 | 114d |
| default | hello-00002-deployment | 0/0 | 0 | 0 | 114d |
| default | hello-00003-deployment | 1/1 | 1 | 1 | 114d |
| default | netshoot-debug | 1/1 | 1 | 1 | 142d |
| default | report-processor-00001-deployment | 0/0 | 0 | 0 | 112d |
| gitlab-runner | gitlab-runner | 1/1 | 1 | 1 | 252d |
| kafka | my-cluster-entity-operator | 1/1 | 1 | 1 | 112d |
| kafka | strimzi-cluster-operator | 1/1 | 1 | 1 | 113d |
| knative-eventing | eventing-controller | 1/1 | 1 | 1 | 113d |
| knative-eventing | eventing-webhook | 1/1 | 1 | 1 | 113d |
| knative-eventing | job-sink | 1/1 | 1 | 1 | 113d |
| knative-eventing | kafka-broker-receiver | 1/1 | 1 | 1 | 113d |
| knative-eventing | kafka-controller | 1/1 | 1 | 1 | 113d |
| knative-eventing | kafka-webhook-eventing | 1/1 | 1 | 1 | 113d |
| knative-eventing | pingsource-mt-adapter | 1/1 | 1 | 1 | 113d |
| knative-operator | knative-operator | 1/1 | 1 | 1 | 114d |
| knative-operator | operator-webhook | 1/1 | 1 | 1 | 114d |
| knative-serving | 3scale-kourier-gateway | 1/1 | 1 | 1 | 114d |
| knative-serving | activator | 1/1 | 1 | 1 | 114d |
| knative-serving | autoscaler | 1/1 | 1 | 1 | 114d |
| knative-serving | autoscaler-hpa | 1/1 | 1 | 1 | 114d |
| knative-serving | controller | 1/1 | 1 | 1 | 114d |
| knative-serving | net-kourier-controller | 1/1 | 1 | 1 | 114d |
| knative-serving | webhook | 1/1 | 1 | 1 | 114d |
| kube-system | calico-kube-controllers | 1/1 | 1 | 1 | 253d |
| kube-system | coredns | 2/2 | 2 | 2 | 253d |
| kube-system | metrics-server | 1/1 | 1 | 1 | 180d |
| kube-system | vpa-admission-controller | 2/2 | 2 | 2 | 178d |
| kube-system | vpa-recommender | 2/2 | 2 | 2 | 178d |
| kube-system | vpa-updater | 2/2 | 2 | 2 | 178d |
| kubernetes-dashboard | dashboard-metrics-scraper | 1/1 | 1 | 1 | 253d |
| kubernetes-dashboard | kubernetes-dashboard | 1/1 | 1 | 1 | 253d |
| logging | loki-gateway | 1/1 | 1 | 1 | 154d |
| logging | loki-read | 1/1 | 1 | 1 | 154d |
| logging | tempo-compactor | 1/1 | 1 | 1 | 154d |
| logging | tempo-distributor | 1/1 | 1 | 1 | 154d |
| logging | tempo-metrics-generator | 1/1 | 1 | 1 | 154d |
| logging | tempo-querier | 1/1 | 1 | 1 | 154d |
| logging | tempo-query-frontend | 1/1 | 1 | 1 | 154d |
| metallb-system | controller | 1/1 | 1 | 1 | 253d |
| monitoring | flask-prom | 2/2 | 2 | 2 | 100d |
| monitoring | prometheus-grafana | 1/1 | 1 | 1 | 247d |
| monitoring | prometheus-kube-state-metrics | 1/1 | 1 | 1 | 247d |
| monitoring | prometheus-operator | 1/1 | 1 | 1 | 247d |
| n8n | cloudflared | 1/1 | 1 | 1 | 176d |
| n8n | n8n | 1/1 | 1 | 1 | 176d |

> **注意**: cloudflared 已修复，详见 `/root/cloudflared-troubleshooting.md`
| nfs-provisioner | nfs-provisioner | 1/1 | 1 | 1 | 252d |
| opentelemetry | otel-collector | 1/1 | 1 | 1 | 173d |
| opentelemetry | otel-operator-opentelemetry-operator | 1/1 | 1 | 1 | 208d |
| tekton-demo | tekton-demo-api | 2/2 | 2 | 2 | 100d |
| tekton-pipelines-resolvers | tekton-pipelines-remote-resolvers | 1/1 | 1 | 1 | 242d |
| tekton-pipelines | tekton-dashboard | 1/1 | 1 | 1 | 242d |
| tekton-pipelines | tekton-events-controller | 1/1 | 1 | 1 | 242d |
| tekton-pipelines | tekton-pipelines-controller | 1/1 | 1 | 1 | 242d |
| tekton-pipelines | tekton-pipelines-webhook | 1/1 | 1 | 1 | 242d |
| tekton-pipelines | tekton-triggers-controller | 1/1 | 1 | 1 | 242d |
| tekton-pipelines | tekton-triggers-core-interceptors | 1/1 | 1 | 1 | 241d |
| tekton-pipelines | tekton-triggers-webhook | 1/1 | 1 | 1 | 242d |
| tf-space | terraform-nginx | 3/3 | 3 | 3 | 154d |
| traefik | traefik | 1/1 | 1 | 1 | 253d |

### 4.2 DaemonSets

| 命名空间 | 名称 | 期望 | 当前 | 就绪 | 可用 | 运行时长 |
|----------|------|------|------|------|------|----------|
| ceph-csi-rbd | ceph-csi-rbd-nodeplugin | 3 | 3 | 3 | 3 | 177d |
| kube-system | calico-node | 6 | 6 | 6 | 6 | 253d |
| kube-system | kube-proxy | 6 | 6 | 6 | 6 | 253d |
| kube-system | kube-vip-ds | 3 | 3 | 3 | 3 | 253d |
| logging | loki-canary | 3 | 3 | 3 | 3 | 154d |
| logging | promtail | 6 | 6 | 6 | 6 | 174d |
| metallb-system | speaker | 6 | 6 | 6 | 6 | 253d |
| monitoring | prometheus-prometheus-node-exporter | 6 | 6 | 6 | 6 | 247d |

### 4.3 StatefulSets

| 命名空间 | 名称 | 就绪 | 运行时长 |
|----------|------|------|----------|
| argocd | argocd-application-controller | 1/1 | 252d |
| knative-eventing | kafka-broker-dispatcher | 1/1 | 113d |
| logging | loki-backend | 1/1 | 154d |
| logging | loki-chunks-cache | 1/1 | 154d |
| logging | loki-results-cache | 1/1 | 154d |
| logging | loki-write | 1/1 | 154d |
| logging | tempo-ingester | 3/3 | 154d |
| logging | tempo-memcached | 1/1 | 154d |
| monitoring | alertmanager-prometheus-alertmanager | 1/1 | 247d |
| monitoring | prometheus-prometheus-prometheus | 1/1 | 247d |

---

## 5. 服务 (Services)

### 5.1 服务统计

| 类型 | 数量 |
|------|------|
| ClusterIP | 大多数 |
| LoadBalancer | 2 (kourier, traefik) |
| NodePort | 1 (tekton-demo-listener) |
| ExternalName | 3 (autoscale-demo, hello, report-processor) |

### 5.2 LoadBalancer 服务

| 命名空间 | 服务名 | 外部 IP | 端口 |
|----------|--------|---------|------|
| knative-serving | kourier | 172.16.1.221 | 80:32163, 443:32282 |
| traefik | traefik | 172.16.1.220 | 80:30417, 443:32220 |

### 5.3 NodePort 服务

| 命名空间 | 服务名 | 端口映射 |
|----------|--------|----------|
| cicd | tekton-demo-listener-nodeport | 8080:30080 |

### 5.4 对外服务入口地址 (MetalLB / Ingress)

> **MetalLB 地址池**: 172.16.1.220 ~ 172.16.1.221

#### Ingress 服务 (Traefik)

| 域名 | 命名空间 | 服务 | 端口 | 入口 IP | 说明 |
|------|----------|------|------|---------|------|
| `n8n.zeroth.com` | n8n | n8n-svc | 80/5678 | 172.16.1.220 | n8n 集群内部访问 (HTTPS) |
| `n8ntrace.ccwu.cc` | n8n | n8n-svc | 80/5678 | 公网 | n8n Cloudflare Tunnel 公网访问 |
| `tekton-demo.local` | tekton-demo | tekton-demo-api | 80 | 172.16.1.220 | Tekton Demo API |

#### Traefik IngressRoute (CRD)

| 域名 | 命名空间 | 服务 | 端口 | 入口 IP |
|------|----------|------|------|---------|
| `argocd.devops.com` | argocd | argocd-server | 80 | 172.16.1.220 |
| `dashboard.k8s.local` | kubernetes-dashboard | kubernetes-dashboard | 443 | 172.16.1.220 |
| `grafana.k8s.local` | monitoring | prometheus-grafana | 80 | 172.16.1.220 |
| `prometheus.k8s.local` | monitoring | prometheus-operated | 9090 | 172.16.1.220 |
| `traefik.example.com` | traefik | api@internal | - | 172.16.1.220 |

#### MetalLB LoadBalancer 服务

| 服务 | 命名空间 | 外部 IP | HTTP 端口 | HTTPS 端口 |
|------|----------|---------|-----------|------------|
| traefik | traefik | 172.16.1.220 | 80 (节点端口 30417) | 443 (节点端口 32220) |
| kourier | knative-serving | 172.16.1.221 | 80 (节点端口 32163) | 443 (节点端口 32282) |

#### NodePort 服务

| 服务 | 命名空间 | 端口映射 | 用途 |
|------|----------|----------|------|
| tekton-demo-listener-nodeport | cicd | 8080:30080 | Tekton EventListener |

#### Knative 服务 (通过 Kourier 暴露)

| 服务名 | 命名空间 | URL | 状态 |
|--------|----------|-----|------|
| autoscale-demo | default | http://autoscale-demo.default.hao.com | Ready |
| hello | default | http://hello.default.hao.com | Ready |
| report-processor | default | http://report-processor.default.hao.com | Ready |

> **访问方式**: Knative 服务通过 Kourier 网关暴露，入口 IP 为 `172.16.1.221`

---

## 6. 存储 (Storage)

### 6.1 存储类 (StorageClasses)

| 名称 | 供应器 | 回收策略 | 卷绑定模式 | 允许扩展 | 运行时长 |
|------|--------|----------|------------|----------|----------|
| ceph-rbd-sc | rbd.csi.ceph.com | Retain | Immediate | true | 176d |
| nfs-sc | example.com/nfs | Delete | Immediate | false | 252d |

### 6.2 持久卷 (PV)

| 名称 | 容量 | 访问模式 | 回收策略 | 状态 | 存储类 | 运行时长 |
|------|------|----------|----------|------|--------|----------|
| pvc-13f428e3... | 10Gi | RWO | Retain | Bound | ceph-rbd-sc | 174d |
| pvc-156eb2c1... | 2Gi | RWO | Delete | Bound | nfs-sc | 100d |
| pvc-1eaaa4c3... | 10Gi | RWO | Retain | Released | ceph-rbd-sc | 174d |
| pvc-28b685a9... | 10Gi | RWO | Retain | Bound | ceph-rbd-sc | 176d |
| pvc-312f456c... | 10Gi | RWO | Retain | Bound | ceph-rbd-sc | 140d |
| pvc-5dc9836b... | 10Gi | RWO | Retain | Bound | ceph-rbd-sc | 154d |
| pvc-64bf73eb... | 1Gi | RWO | Retain | Bound | ceph-rbd-sc | 177d |
| pvc-6b229b52... | 5Gi | RWO | Retain | Bound | ceph-rbd-sc | 140d |
| pvc-89160268... | 5Gi | RWO | Retain | Bound | ceph-rbd-sc | 176d |
| pvc-b5fb0054... | 10Gi | RWO | Retain | Bound | nfs-sc | 247d |
| pvc-c6bcf716... | 5Gi | RWO | Retain | Bound | ceph-rbd-sc | 176d |
| pvc-c9f23db5... | 100Gi | RWO | Delete | Bound | nfs-sc | 247d |
| pvc-e3ccf3ee... | 20Gi | RWO | Delete | Bound | nfs-sc | 247d |
| pvc-e6337758... | 20Gi | RWO | Retain | Bound | ceph-rbd-sc | 112d |

### 6.3 持久卷声明 (PVC)

| 命名空间 | 名称 | 容量 | 访问模式 | 存储类 | 状态 |
|----------|------|------|----------|--------|------|
| cicd | pvc-024375c6c5 | 2Gi | RWO | nfs-sc | Bound |
| cicd | pvc-07d4fa7725 | 2Gi | RWO | nfs-sc | Bound |
| cicd | pvc-7c2230c497 | 2Gi | RWO | nfs-sc | Bound |
| cicd | pvc-b7cd60a16f | 2Gi | RWO | nfs-sc | Bound |
| cicd | pvc-b881288a29 | 2Gi | RWO | nfs-sc | Bound |
| cicd | tekton-demo-workspace-pvc | 2Gi | RWO | nfs-sc | Bound |
| cnpg-system | pg16-ceph-2 | 10Gi | RWO | ceph-rbd-sc | Bound |
| cnpg-system | pg16-ceph-2-wal | 5Gi | RWO | ceph-rbd-sc | Bound |
| cnpg-system | pg16-ceph-3 | 10Gi | RWO | ceph-rbd-sc | Bound |
| cnpg-system | pg16-ceph-3-wal | 5Gi | RWO | ceph-rbd-sc | Bound |
| default | rbd-pvc-test | 1Gi | RWO | ceph-rbd-sc | Bound |
| kafka | data-my-cluster-single-pool-0 | 20Gi | RWO | ceph-rbd-sc | Bound |
| logging | data-loki-backend-0 | 10Gi | RWO | ceph-rbd-sc | Bound |
| logging | data-loki-write-0 | 10Gi | RWO | ceph-rbd-sc | Bound |
| monitoring | alertmanager-...-db-... | 20Gi | RWO | nfs-sc | Bound |
| monitoring | prometheus-grafana | 10Gi | RWO | nfs-sc | Bound |
| monitoring | prometheus-...-db-... | 100Gi | RWO | nfs-sc | Bound |
| n8n | n8n-pvc | 5Gi | RWO | ceph-rbd-sc | Bound |

---

## 7. 入口 (Ingress)

| 名称 | 命名空间 | 类 | 主机 | 地址 | 端口 | 运行时长 |
|------|----------|-----|------|------|------|----------|
| n8n-ingress | n8n | traefik | n8n.zeroth.com | 172.16.1.220 | 80 | 176d |
| tekton-demo-api | tekton-demo | - | tekton-demo.local | 172.16.1.220 | 80 | 100d |

---

## 8. 网络策略 (NetworkPolicies)

| 命名空间 | 名称 | Pod 选择器 | 运行时长 |
|----------|------|------------|----------|
| kafka | my-cluster-entity-operator | strimzi.io/cluster=my-cluster,strimzi.io/kind=Kafka,strimzi.io/name=my-cluster-entity-operator | 112d |
| kafka | my-cluster-network-policy-kafka | strimzi.io/cluster=my-cluster,strimzi.io/kind=Kafka,strimzi.io/name=my-cluster-kafka | 112d |

---

## 9. 自动伸缩 (HPA)

| 命名空间 | 名称 | 参考 | 目标 | 最小 Pod | 最大 Pod | 当前副本 | 运行时长 |
|----------|------|------|------|----------|----------|----------|----------|
| knative-eventing | eventing-webhook | Deployment/eventing-webhook | 6%/100% | 1 | 5 | 1 | 113d |
| knative-serving | 3scale-kourier-gateway | Deployment/3scale-kourier-gateway | 2%/100% | 1 | 10 | 1 | 114d |
| knative-serving | activator | Deployment/activator | 0%/100% | 1 | 20 | 1 | 114d |
| knative-serving | webhook | Deployment/webhook | 3%/100% | 1 | 5 | 1 | 114d |
| tekton-pipelines | tekton-pipelines-webhook | Deployment/tekton-pipelines-webhook | 2%/100% | 1 | 5 | 1 | 242d |

---

## 10. 准入控制 Webhooks

### 10.1 Mutating Webhooks

| 名称 | Webhook 数量 | 运行时长 |
|------|--------------|----------|
| cert-manager-webhook | 1 | 208d |
| cnpg-mutating-webhook-configuration | 3 | 177d |
| defaulting.webhook.kafka.eventing.knative.dev | 1 | 113d |
| otel-operator-opentelemetry-operator-mutation | 3 | 208d |
| pods.defaulting.webhook.kafka.eventing.knative.dev | 1 | 113d |
| prometheus-admission | 1 | 247d |
| sinkbindings.webhook.sources.knative.dev | 1 | 113d |
| vpa-vertical-pod-autoscaler-webhook-config | 1 | 178d |
| webhook.eventing.knative.dev | 1 | 113d |
| webhook.pipeline.tekton.dev | 1 | 242d |
| webhook.serving.knative.dev | 1 | 114d |
| webhook.triggers.tekton.dev | 1 | 242d |

### 10.2 Validating Webhooks

| 名称 | Webhook 数量 | 运行时长 |
|------|--------------|----------|
| cert-manager-webhook | 1 | 208d |
| cnpg-validating-webhook-configuration | 4 | 177d |
| config.webhook.eventing.knative.dev | 1 | 113d |
| config.webhook.pipeline.tekton.dev | 1 | 242d |
| config.webhook.serving.knative.dev | 1 | 114d |
| config.webhook.triggers.tekton.dev | 1 | 242d |
| metallb-webhook-configuration | 7 | 253d |
| otel-operator-opentelemetry-operator-validation | 4 | 208d |
| prometheus-admission | 2 | 247d |
| validation.webhook.eventing.knative.dev | 1 | 113d |
| validation.webhook.kafka.eventing.knative.dev | 1 | 113d |
| validation.webhook.pipeline.tekton.dev | 1 | 242d |
| validation.webhook.serving.knative.dev | 1 | 114d |
| validation.webhook.triggers.tekton.dev | 1 | 242d |

---

## 11. RBAC

### 11.1 集群角色 (部分)

| 名称 | 运行时长 |
|------|----------|
| admin | 253d |
| argocd-application-controller | 252d |
| argocd-notifications-controller | 252d |
| argocd-server | 252d |
| calico-cni-plugin | 253d |
| calico-kube-controllers | 253d |
| calico-node | 253d |
| ceph-csi-rbd-nodeplugin | 177d |
| ceph-csi-rbd-provisioner | 177d |
| cert-manager-cainjector | 208d |
| cert-manager-controller-* | 208d |
| cert-manager-webhook:subjectaccessreviews | 208d |

### 11.2 集群角色绑定 (部分)

| 名称 | 角色 | 运行时长 |
|------|------|----------|
| admin-user | cluster-admin | 253d |
| argocd-application-controller | argocd-application-controller | 252d |
| argocd-notifications-controller | argocd-notifications-controller | 252d |
| argocd-server | argocd-server | 252d |
| calico-cni-plugin | calico-cni-plugin | 253d |
| calico-kube-controllers | calico-kube-controllers | 253d |
| calico-node | calico-node | 253d |
| ceph-csi-rbd-nodeplugin | ceph-csi-rbd-nodeplugin | 177d |
| ceph-csi-rbd-provisioner | ceph-csi-rbd-provisioner | 177d |
| cert-manager-cainjector | cert-manager-cainjector | 208d |

---

## 12. 集群组件版本

| 组件 | 版本 |
|------|------|
| Kubernetes | v1.29.8 |
| CoreDNS | v1.11.1 |
| Calico | v3.27.4 |
| kube-proxy | v1.29.8 |
| kube-vip | v1.0.3 |
| metrics-server | v0.8.1 |
| VPA | 1.6.0 |
| ArgoCD | v3.2.4 |
| cert-manager | v1.19.4 |
| ceph-csi | v3.16.2 |
| MetalLB | v0.13.12 |
| Traefik | v3.6.2 |
| Strimzi (Kafka) | 1.0.0 |
| Knative Serving | v1.22.1 |
| Knative Eventing | - |
| Tekton Pipelines | v1.6.0 |
| Tekton Triggers | v0.34.0 |
| OpenTelemetry Collector | 0.145.0 |
| OpenTelemetry Operator | 0.145.0 |
| CloudNativePG | 1.22.0 |
| Grafana | 12.4.3 |
| Loki | 3.6.7 |
| Tempo | 2.9.0 |
| Promtail | 3.5.1 |
| Prometheus | v3.11.2 |
| Alertmanager | v0.32.0 |
| kube-state-metrics | v2.18.0 |
| node-exporter | v1.11.1 |
| nfs-subdir-external-provisioner | v4.0.2 |
| n8n | 2.14.2 |
| GitLab Runner | alpine-v18.7.2 |
| Kubernetes Dashboard | v2.7.0 |

---

## 13. 异常与告警

### 13.1 异常 Pod (Ceph 恢复后更新)

| 命名空间 | Pod | 状态 | 重启次数 | 问题 |
|----------|-----|------|----------|------|
| argocd | argocd-repo-server-765dc58894-7mkhn | Running | 153 | 仍在重启，但已恢复运行 |
| kafka | my-cluster-entity-operator-d888898c7-r28ll | Running | 212 | 仍在重启，但已恢复运行 |
| logging | loki-read-67b5687d4b-4pxcc | Running | 77 | 仍在重启，需关注 |
| gitlab-runner | gitlab-runner-6c678959c8-8qvph | Running | 2478 | 存活探针失败 |

> **Ceph 恢复后已恢复的 Pod**: loki-backend-0, loki-write-0, pg16-ceph-2, pg16-ceph-3, n8n-5674d5b9cf-7z2km, cloudflared

> **cloudflared 修复**: 2026-09-27 修复 DNS 配置后恢复正常，详见 `/root/cloudflared-troubleshooting.md`

### 13.2 最近事件 (Ceph 恢复后)

| 命名空间 | 时间 | 类型 | 对象 | 描述 |
|----------|------|------|------|------|
| default | 3m17s | Normal | report-processor-00001-deployment | ScalingReplicaSet scaled up |
| argocd | 3m14s | Warning | argocd-repo-server-765dc58894-7mkhn | Back-off restarting failed container |
| logging | 3m13s | Warning | promtail-drx7z | Readiness probe failed |
| n8n | 3m11s | Warning | cloudflared-5c87595bb7-4tf6x | Back-off restarting failed container |
| cnpg-system | 3m9s | Warning | pg16-ceph-2 | Startup probe failed: HTTP probe failed with statuscode: 500 |
| gitlab-runner | 2m29s | Warning | gitlab-runner-6c678959c8-8qvph | Liveness probe failed |

### 13.3 DNS 配置警告

多个 Pod 出现 `DNSConfigForming` 警告，提示 nameserver 限制超出，部分 nameserver 被省略。应用的 nameserver 行为: `223.5.5.5 119.29.29.29 223.5.5.5`。

---

## 14. 资源配额与限制

- **ResourceQuota**: 未设置
- **LimitRange**: 未设置

---

## 15. 集群架构图

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                   Kubernetes Cluster                    │
                   │                   v1.29.8 (6 nodes)                      │
                    └─────────────────────────────────────────────────────────┘
                                              │
            ┌─────────────────────────────────┼─────────────────────────────────┐
            │                                 │                                 │
    ┌───────▼───────┐               ┌─────────▼─────────┐               ┌───────▼───────┐
    │  Control Plane │               │   Control Plane   │               │  Control Plane │
    │      m01       │               │    master01       │               │    master02    │
    │  10.0.0.61    │               │   10.0.0.121      │               │   10.0.0.120   │
    │  Rocky Linux  │               │   Ubuntu 22.04    │               │   Ubuntu 22.04 │
    └───────────────┘               └───────────────────┘               └───────────────┘
            │                                 │                                 │
            └─────────────────────────────────┼─────────────────────────────────┘
                                              │
                    ┌─────────────────────────┼─────────────────────────┐
                    │                         │                         │
            ┌───────▼───────┐         ┌───────▼───────┐         ┌───────▼───────┐
            │    worker01   │         │    worker02   │         │    worker03   │
            │  10.0.0.122   │         │  10.0.0.123    │         │  10.0.0.124    │
            │  high-mem     │         │  general      │         │  general      │
            │  zone=test-a  │         │  zone=test-b  │         │  zone=test-a  │
            └───────────────┘         └───────────────┘         └───────────────┘

    网络: Calico v3.27.4
    入口: Traefik v3.6.2 (LoadBalancer: 172.16.1.220)
    负载均衡: MetalLB v0.13.12
    存储: Ceph RBD (ceph-rbd-sc) + NFS (nfs-sc)
    监控: Prometheus + Grafana + Alertmanager
    日志: Loki + Tempo + Promtail
    CI/CD: Tekton Pipelines + ArgoCD
    可观测性: OpenTelemetry Collector
    服务网格: Knative Serving + Eventing
```

---

## 16. 总结

### 集群规模
- **节点数**: 6 (3 control-plane + 3 worker)
- **命名空间**: 27
- **Pod 总数**: ~150+
- **服务数**: ~100+
- **存储类**: 2 (Ceph RBD + NFS)

### 主要技术栈
- **容器运行时**: containerd 1.7.22
- **网络**: Calico v3.27.4
- **入口**: Traefik v3.6.2 + MetalLB
- **存储**: Ceph RBD + NFS
- **监控**: Prometheus + Grafana
- **日志**: Loki + Tempo + Promtail
- **CI/CD**: Tekton + ArgoCD + GitLab Runner
- **Serverless**: Knative
- **消息队列**: Kafka (Strimzi)
- **数据库**: CloudNativePG (PostgreSQL)
- **可观测性**: OpenTelemetry

### 需要关注的问题
1. **argocd-repo-server** 处于 CrashLoopBackOff 状态
2. **kafka entity-operator** 处于 CrashLoopBackOff 状态
3. **n8n** 相关 Pod 状态异常
4. **loki-backend/loki-write** 状态 Unknown
5. **cnpg pg16-ceph-2/pg16-ceph-3** 状态 Unknown
6. **DNS 配置警告** 在多个 Pod 中出现
7. **Ceph 挂载超时** 影响部分 Pod

---

---

## 17. 可观测性体系 (LGMT)

### 17.1 可观测性组件概览

| 组件 | 版本 | 命名空间 | 状态 | 用途 |
|------|------|----------|------|------|
| **Grafana** | 12.4.3 | monitoring | ✅ 运行中 | 可视化仪表板 |
| **Prometheus** | v3.11.2 | monitoring | ✅ 运行中 | 指标收集与告警 |
| **Alertmanager** | v0.32.0 | monitoring | ✅ 运行中 | 告警路由与通知 |
| **Loki** | 3.6.7 | logging | ✅ 已恢复 | 日志聚合 |
| **Tempo** | 2.9.0 | logging | ✅ 运行中 | 分布式追踪 |
| **Promtail** | 3.5.1 | logging | ✅ 运行中 | 日志采集 |
| **OpenTelemetry** | 0.145.0 | opentelemetry | ✅ 运行中 | 可观测性数据采集 |
| **kube-state-metrics** | v2.18.0 | monitoring | ✅ 运行中 | K8s 对象状态指标 |
| **node-exporter** | v1.11.1 | monitoring | ✅ 运行中 | 节点系统指标 |

> **Ceph 恢复说明**: 2026-09-27 Ceph 存储节点（PVE VM 116/117/118 = nfs01/backup/db01，IP 10.0.0.31/41/51）开机后，所有因存储不可用而异常的 Pod 已恢复正常运行。

### 17.2 Grafana 可视化平台

| 项目 | 值 |
|------|-----|
| **版本** | 12.4.3 |
| **数据库状态** | ok |
| **Commit** | 86c83248 |
| **服务地址** | `prometheus-grafana.monitoring.svc.cluster.local` |
| **外部访问** | 通过 Traefik Ingress 或 LoadBalancer |

#### Grafana 仪表板列表

| 仪表板名称 | UID | 说明 |
|------------|-----|------|
| Kubernetes / Cluster | k8s-cluster | 集群总览 |
| Kubernetes / Namespace | k8s-namespace | 命名空间详情 |
| Kubernetes / Node | k8s-node | 节点监控 |
| Kubernetes / Pod | k8s-pod | Pod 监控 |
| Node Exporter / Nodes | node-exporter | 节点系统指标 |
| Loki / Logs | loki-logs | 日志查询 |
| Tempo / Traces | tempo-traces | 追踪查询 |

### 17.3 Prometheus 指标监控

#### 17.3.1 告警规则概览

| 规则组 | 规则数 | 说明 |
|--------|--------|------|
| node.rules | 3 | 节点 CPU/内存/磁盘告警 |
| otel-demo.rules | 2 | OpenTelemetry 演示告警 |
| pod.rules | 3 | Pod 崩溃/未就绪/OOM 告警 |
| alertmanager.rules | 8 | Alertmanager 自身告警 |
| config-reloaders | 1 | 配置重载错误告警 |
| etcd | 15 | etcd 集群健康告警 |
| general.rules | 3 | 通用告警 (TargetDown, Watchdog) |
| k8s.rules.* | 多项 | K8s 资源指标记录规则 |

#### 17.3.2 当前告警状态 (Ceph 恢复后更新)

| 状态 | 数量 | 变化 |
|------|------|------|
| **Firing** | 19 | ↓ 从 28 减少 |
| **Pending** | 12 | ↑ 从 5 增加 |
| **总计** | 31 | ↓ 从 33 减少 |

#### 17.3.3 Firing 告警详情 (Ceph 恢复后)

| 严重级别 | 告警名称 | 实例 | 摘要 |
|----------|----------|------|------|
| **critical** | AlertmanagerClusterFailedToSendAlerts | - | 所有 Alertmanager 实例发送通知失败 |
| **critical** | etcdInsufficientMembers | - | etcd 集群成员不足 |
| **warning** | AlertmanagerFailedToSendAlerts | 10.244.5.48:9093 | Alertmanager 实例发送通知失败 |
| **warning** | PodCrashLooping | 10.244.30.111:8080 | Pod 频繁重启: argocd/argocd-repo-server |
| **warning** | PodCrashLooping | 10.244.30.111:8080 | Pod 频繁重启: n8n/cloudflared |
| **warning** | PodCrashLooping | 10.244.30.111:8080 | Pod 频繁重启: kafka/my-cluster-entity-operator |
| **warning** | PodCrashLooping | 10.244.30.111:8080 | Pod 频繁重启: logging/loki-read |
| **warning** | PodCrashLooping | 10.244.30.111:8080 | Pod 频繁重启: gitlab-runner/gitlab-runner |
| **warning** | TargetDown | - | 一个或多个目标不可达 |
| **warning** | KubePodCrashLooping | 10.244.30.111:8080 | Pod 正在崩溃循环 |
| **warning** | etcdMembersDown | - | etcd 集群成员宕机 |

> **注意**: Ceph 恢复后，以下告警已消除: pg16-ceph-2/3 Unknown、loki-backend/write Unknown、Ceph 挂载超时等。

#### 17.3.4 集群资源指标

**节点可分配资源:**

| 节点 | CPU (cores) | 内存 | 临时存储 | 最大 Pod 数 |
|------|-------------|------|----------|-------------|
| m01 | 4 | 5.4 GiB | 42.2 GiB | 110 |
| master01 | 4 | 5.7 GiB | 42.3 GiB | 110 |
| master02 | 4 | 3.7 GiB | 33.5 GiB | 110 |
| worker01 | 6 | 9.6 GiB | 42.3 GiB | 110 |
| worker02 | 6 | 9.6 GiB | 42.3 GiB | 110 |
| worker03 | 4 | 7.7 GiB | 42.3 GiB | 110 |

**内存使用 Top 10 Pod:**

| 排名 | 内存使用 | 命名空间/Pod |
|------|----------|--------------|
| 1 | 1046.5 MB | kube-system/kube-apiserver-m01 |
| 2 | 975.9 MB | kube-system/kube-apiserver-master02 |
| 3 | 948.4 MB | kube-system/kube-apiserver-master01 |
| 4 | 684.6 MB | monitoring/prometheus-prometheus-prometheus-0 |
| 5 | 355.4 MB | knative-eventing/kafka-broker-dispatcher-0 |
| 6 | 310.1 MB | kube-system/etcd-m01 |
| 7 | 296.7 MB | monitoring/prometheus-grafana-fb7445bf9-4knb8 |
| 8 | 291.8 MB | knative-eventing/kafka-broker-receiver-6d77466bfc-hbx4h |
| 9 | 241.4 MB | kafka/strimzi-cluster-operator-6bccfd6b88-9txrh |
| 10 | 241.1 MB | argocd/argocd-application-controller-0 |

### 17.4 Loki 日志系统

#### 17.4.1 Loki 组件状态 (Ceph 恢复后)

| 组件 | 状态 | 说明 |
|------|------|------|
| loki-gateway | ✅ Running | Nginx 网关代理 |
| loki-backend | ✅ Running (2/2) | 已恢复，Ceph 存储正常 |
| loki-write | ✅ Running (1/1) | 已恢复 |
| loki-read | ⚠️ Running (重启 77 次) | 仍在重启，需关注 |
| loki-chunks-cache | ✅ Running | Memcached 缓存 |
| loki-results-cache | ✅ Running | Memcached 缓存 |
| loki-canary | ✅ Running (3 副本) | 日志健康检查 |

#### 17.4.2 日志采集

| 采集器 | 状态 | 覆盖范围 |
|--------|------|----------|
| promtail | ✅ 6 副本 DaemonSet | 所有节点 |
| loki-canary | ✅ 3 副本 DaemonSet | 日志系统健康检查 |

#### 17.4.3 日志存储

| 存储类型 | 用途 |
|----------|------|
| Ceph RBD (ceph-rbd-sc) | 持久化日志存储 |
| Memcached | 缓存加速 |

### 17.5 Tempo 分布式追踪

#### 17.5.1 Tempo 组件状态

| 组件 | 状态 | 说明 |
|------|------|------|
| tempo-distributor | ✅ Running | 追踪数据接收 |
| tempo-ingester | ✅ Running (3 副本) | 追踪数据写入 |
| tempo-querier | ✅ Running | 追踪数据查询 |
| tempo-query-frontend | ✅ Running | 查询前端 |
| tempo-compactor | ✅ Running | 数据压缩 |
| tempo-metrics-generator | ✅ Running | 指标生成 |
| tempo-memcached | ✅ Running | 缓存 |

#### 17.5.2 追踪数据流

```
应用 -> OpenTelemetry Collector -> Tempo Distributor -> Tempo Ingester -> 存储
                                                        ↓
                                              Tempo Query Frontend -> Grafana
```

### 17.6 OpenTelemetry 可观测性

| 组件 | 版本 | 状态 |
|------|------|------|
| opentelemetry-operator | 0.145.0 | ✅ Running |
| otel-collector | 0.145.0 | ✅ Running |

**Collector 配置:**
- 接收: OTLP (gRPC/HTTP)
- 导出: Tempo (追踪), Prometheus (指标), Loki (日志)

### 17.7 集群事件分析

#### 17.7.1 事件类型统计 (Ceph 恢复后)

| 事件类型 | 数量 | 说明 |
|----------|------|------|
| DNSConfigForming | 31 | DNS 配置警告 (nameserver 限制超出) |
| FailedMount | 13 | 卷挂载失败 (Ceph 恢复后已减少) |
| Unhealthy | 8 | 健康检查失败 |
| InternalError | 5 | 内部错误 |
| BackOff | 4 | 重启退避 |
| Pulled | 2 | 镜像拉取成功 |
| Pulling | 1 | 镜像拉取中 |

#### 17.7.2 事件趋势分析 (Ceph 恢复后)

**已解决的问题:**
1. ~~**存储挂载问题**~~ — Ceph 恢复后，FailedMount 事件已显著减少
2. ~~**Ceph 挂载超时**~~ — pg16-ceph-2/3、loki-backend/write 已恢复正常

**仍存在的问题:**
1. **DNS 配置问题** — 31 个事件，nameserver 限制超出，部分 nameserver 被省略
2. **健康检查失败** — loki-read 仍在重启 (77 次)，gitlab-runner 存活探针失败
3. **Pod 重启** — argocd-repo-server (153 次)、kafka entity-operator (212 次) 仍在重启

### 17.8 常用运维命令

#### 17.8.1 日志查询 (Loki)

```bash
# 查询特定命名空间的日志
kubectl exec -n default netshoot-debug -- curl -s \
  'http://loki-backend.logging.svc.cluster.local:3100/loki/api/v1/query_range?query={namespace="kube-system"}&limit=50'

# 查询特定 Pod 的日志
kubectl exec -n default netshoot-debug -- curl -s \
  'http://loki-backend.logging.svc.cluster.local:3100/loki/api/v1/query_range?query={pod="argocd-repo-server.*"}&limit=50'

# 查询包含错误关键词的日志
kubectl exec -n default netshoot-debug -- curl -s \
  'http://loki-backend.logging.svc.cluster.local:3100/loki/api/v1/query_range?query={namespace="kube-system"} |= "error"&limit=50'

# 获取 Loki 标签
kubectl exec -n default netshoot-debug -- curl -s \
  'http://loki-backend.logging.svc.cluster.local:3100/loki/api/v1/labels'
```

#### 17.8.2 指标查询 (Prometheus)

```bash
# 查询节点 CPU 使用率
kubectl exec -n default netshoot-debug -- curl -s \
  'http://prometheus-operated.monitoring.svc.cluster.local:9090/api/v1/query?query=100%20-%200%20*%20avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))%20by%20(node)'

# 查询节点内存使用率
kubectl exec -n default netshoot-debug -- curl -s \
  'http://prometheus-operated.monitoring.svc.cluster.local:9090/api/v1/query?query=100%20*%20(1%20-%20node_memory_MemAvailable_bytes%20/%20node_memory_MemTotal_bytes)'

# 查询 Pod 重启次数
kubectl exec -n default netshoot-debug -- curl -s \
  'http://prometheus-operated.monitoring.svc.cluster.local:9090/api/v1/query?query=kube_pod_container_status_restarts_total'

# 查询当前告警
kubectl exec -n default netshoot-debug -- curl -s \
  'http://prometheus-operated.monitoring.svc.cluster.local:9090/api/v1/alerts'

# 查询告警规则
kubectl exec -n default netshoot-debug -- curl -s \
  'http://prometheus-operated.monitoring.svc.cluster.local:9090/api/v1/rules'
```

#### 17.8.3 追踪查询 (Tempo)

```bash
# 查询追踪服务列表
kubectl exec -n default netshoot-debug -- curl -s \
  'http://tempo-query-frontend.logging.svc.cluster.local:3200/api/services'

# 查询最近追踪
kubectl exec -n default netshoot-debug -- curl -s \
  'http://tempo-query-frontend.logging.svc.cluster.local:3200/api/search?limit=10'

# 查询特定 Trace
kubectl exec -n default netshoot-debug -- curl -s \
  'http://tempo-query-frontend.logging.svc.cluster.local:3200/api/traces/<trace-id>'
```

#### 17.8.4 Grafana 仪表板

```bash
# 获取仪表板列表
kubectl exec -n default netshoot-debug -- curl -s \
  'http://prometheus-grafana.monitoring.svc.cluster.local/api/search?type=dash-db'

# 获取特定仪表板详情
kubectl exec -n default netshoot-debug -- curl -s \
  'http://prometheus-grafana.monitoring.svc.cluster.local/api/dashboards/uid/<uid>'

# 健康检查
kubectl exec -n default netshoot-debug -- curl -s \
  'http://prometheus-grafana.monitoring.svc.cluster.local/api/health'
```

#### 17.8.5 集群事件

```bash
# 查看所有事件
kubectl get events -A --sort-by='.lastTimestamp'

# 查看特定命名空间事件
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# 查看警告事件
kubectl get events -A --field-selector type=Warning

# 持续监控事件
kubectl get events -A --watch
```

#### 17.8.6 节点监控

```bash
# 节点资源使用
kubectl top nodes

# 节点详细信息
kubectl describe node <node-name>

# 节点条件
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[*].type}{"\n"}{end}'
```

#### 17.8.7 Pod 监控

```bash
# Pod 资源使用
kubectl top pods -A

# Pod 状态
kubectl get pods -A -o wide

# Pod 事件
kubectl describe pod <pod-name> -n <namespace>

# Pod 日志
kubectl logs <pod-name> -n <namespace> --tail=100

# 进入 Pod 调试
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh
```

#### 17.8.8 存储监控

```bash
# 存储类
kubectl get sc

# 持久卷
kubectl get pv

# 持久卷声明
kubectl get pvc -A

# 存储事件
kubectl get events -A --field-selector reason=FailedMount
```

### 17.9 可观测性架构图

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          OpenTelemetry Collector                             │
│                    (Trace, Metrics, Logs 统一采集)                           │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
          ┌───────────────────────────┼───────────────────────────┐
          │                           │                           │
          ▼                           ▼                           ▼
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│     Tempo       │         │   Prometheus    │         │      Loki       │
│   (分布式追踪)   │         │   (指标监控)     │         │   (日志聚合)    │
│                 │         │                 │         │                 │
│  distributor    │         │  prometheus     │         │  loki-gateway   │
│  ingester       │         │  alertmanager   │         │  loki-backend   │
│  querier        │         │  kube-state-    │         │  loki-write     │
│  query-frontend │         │  metrics        │         │  loki-read      │
│  compactor      │         │  node-exporter  │         │  loki-canary    │
└────────┬────────┘         └────────┬────────┘         └────────┬────────┘
         │                           │                           │
         │                           │                           │
         └───────────────────────────┼───────────────────────────┘
                                     │
                                     ▼
                           ┌─────────────────┐
                           │    Grafana      │
                           │   (可视化平台)   │
                           │                 │
                           │  12.4.3         │
                           │                 │
                           │  - 仪表板        │
                           │  - 告警          │
                           │  - 日志查询      │
                           │  - 追踪查询      │
                           └─────────────────┘
```

### 17.10 告警通知渠道

| 渠道 | 状态 | 说明 |
|------|------|------|
| Alertmanager | ✅ 运行中 | 告警路由与聚合 |
| 邮件通知 | ⚠️ 配置中 | AlertmanagerFailedToSendAlerts 告警 |
| Webhook | ⚠️ 配置中 | 部分目标不可达 |

### 17.11 可观测性最佳实践

#### 17.11.1 日志管理

1. **日志采集**: 使用 Promtail DaemonSet 采集所有节点日志
2. **日志存储**: 使用 Ceph RBD 持久化存储
3. **日志查询**: 通过 Grafana Loki 数据源查询
4. **日志保留**: 建议配置保留策略 (如 30 天)

#### 17.11.2 指标监控

1. **指标收集**: Prometheus 定期抓取指标
2. **指标存储**: 本地存储 (100Gi PVC)
3. **指标查询**: 通过 Grafana 或 Prometheus UI
4. **告警规则**: 配置合理的告警阈值

#### 17.11.3 分布式追踪

1. **追踪采集**: OpenTelemetry SDK 集成
2. **追踪存储**: Tempo 分布式存储
3. **追踪查询**: Grafana Tempo 数据源
4. **采样策略**: 建议配置尾部采样

#### 17.11.4 告警管理

1. **告警分级**: critical / warning / info
2. **告警抑制**: 配置合理的抑制规则
3. **告警路由**: 按团队/服务路由
4. **告警通知**: 配置多种通知渠道

---

*报告由 kubectl 自动生成，包含可观测性体系 (LGMT) 详细数据*
