# Cilium 循序渐进实验教程

本套实验帮助你在 **k3s + Cilium v1.20.1** 集群上,从零到进阶地掌握 Cilium。

集群环境:
- 3 节点 (ubuntu01 master / ubuntu02 / ubuntu03),K3s v1.36
- Cilium v1.20.1,完整 eBPF 模式,kube-proxy replacement 开启
- Cilium CLI v0.20.0 已安装,`cilium` 命令可直接使用
- kubeconfig: `~/.kube/config` (已配置)

## 实验命名空间与测试应用

所有实验都在 `lab` 命名空间,测试应用:
- `web`   — nginx,2 副本,标签 `app=web, tier=frontend`,Service `lab/web:80`
- `api`   — httpd,1 副本,标签 `app=api, tier=backend`,Service `lab/api:80`
- `test`  — curl 工具,标签 `app=test, role=curl`,用于发包测试

## 学习路线图

```
┌─► 01 基础概念:理解 Cilium 组件与身份
│    · cilium status / endpoint / identity / cilium bpf
│    · 连接性自检 (cilium connectivity test)
│
├─► 02 可观测性:用 Hubble 看流量
│    · cilium monitor / hubble observe
│    · Hubble UI / Service Map
│
├─► 03 网络策略 L3/L4:学会放行与拦截
│    · 默认拒绝
│    · 按标签(pod selector)、按 IP 放行
│    · 端口级控制 (port)
│
├─► 04 网络策略 L7:应用层安全
│    · 限制 HTTP 方法/路径 (GET, /api)
│    · CiliumNetworkPolicy + toFQDNs (DNS 规则)
│
├─► 05 高级:身份安全 + 加密 + 多集群概念
│    · 基于身份的默认拒绝
│    · IPsec/WireGuard 加密配置
│    · ClusterMesh 概念
│
├─► 06 Service 与负载均衡
│    · kube-proxy replacement 观察
│    · cilium service list / bpf lb
│    · 多副本负载均衡验证
│
└─► 07 故障排查实战
     · cilium troubleshoot / endpoint list
     · 策略命中日志验证
     · MTU / DNS 排查
```

## 快速开始

每个目录包含:
- `README.md`  — 讲解概念 + 操作步骤
- `*.yaml`     — 需要的 Kubernetes/Cilium 资源
- 文档内命令可直接在 master 节点执行

### 常用便捷命令

```bash
export POD=$(kubectl get pod -n lab -l app=test -o jsonpath='{.items[0].metadata.name}')

# 从 test pod 访问 web 服务
kubectl exec -n lab $POD -- curl -s -o /dev/null -w "%{http_code}\n" http://web.lab.svc.cluster.local/

# 实时观察 Cilium agent 决策
cilium monitor

# 观察 Hubble 流量
hubble observe
```

> 提示:如果 `hubble` 命令未安装,可参考 `02-observability/README.md` 启用并安装。
