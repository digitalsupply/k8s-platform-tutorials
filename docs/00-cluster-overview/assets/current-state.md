# 当前集群实况快照

> 采集时间：2026-11-10 16:03:54 CST  
> 采集方式：在 m01 上执行只读 kubectl/helm/ceph 命令。集群会继续变化，本文是当时快照。

## 版本与节点
```text
Client Version: v1.35.9
Server Version: v1.35.9

NAME       STATUS   ROLES           AGE    VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                      KERNEL-VERSION                 CONTAINER-RUNTIME
m01        Ready    control-plane   297d   v1.35.9   10.0.0.61     <none>        Rocky Linux 9.6 (Blue Onyx)   5.14.0-570.58.1.el9_6.x86_64   containerd://2.3.2
master01   Ready    control-plane   297d   v1.35.9   10.0.0.121    <none>        Ubuntu 22.04.5 LTS            5.15.0-202-generic             containerd://2.3.2
master02   Ready    control-plane   297d   v1.35.9   10.0.0.120    <none>        Ubuntu 22.04.5 LTS            5.15.0-202-generic             containerd://2.3.2
worker01   Ready    <none>          297d   v1.35.9   10.0.0.122    <none>        Ubuntu 22.04.5 LTS            5.15.0-202-generic             containerd://2.3.2
worker02   Ready    <none>          297d   v1.35.9   10.0.0.123    <none>        Ubuntu 22.04.5 LTS            5.15.0-202-generic             containerd://2.3.2
worker03   Ready    <none>          297d   v1.35.9   10.0.0.124    <none>        Ubuntu 22.04.5 LTS            5.15.0-202-generic             containerd://2.3.2
```

## 节点容量
```text
m01        4     5801092Ki    110   10.0.0.61
master01   4     6063400Ki    110   10.0.0.121
master02   4     4005168Ki    110   10.0.0.120
worker01   6     10179360Ki   110   10.0.0.122
worker02   6     10179356Ki   110   10.0.0.123
worker03   4     8127784Ki    110   10.0.0.124
```

## 命名空间
```text
argocd ceph-csi-operator-system ceph-csi-rbd cert-manager china-study-free cicd cilium-secrets cnpg-system compassio deeptutor default etcd-backup gitlab-runner grafana-operator kafka kube-node-lease kube-public kube-system logging metallb-system monitoring n8n nfs-provisioner oauth2-proxy open-webui opentelemetry tekton-operator tekton-pipelines traefik 
```

## Helm Releases
```text
NAME              	NAMESPACE    	REVISION	UPDATED                                	STATUS  	CHART                         	APP VERSION
alloy             	logging      	3       	2026-11-09 21:21:24.408703536 +0800 CST	deployed	alloy-1.13.0                  	v1.20.0    
argocd            	argocd       	15      	2026-11-10 13:39:17.246859448 +0800 CST	deployed	argo-cd-10.9.6                	v3.5.3     
cert-manager      	cert-manager 	1       	2026-03-03 10:24:22.048547245 +0800 CST	deployed	cert-manager-v1.19.4          	v1.19.4    
cilium            	kube-system  	4       	2026-11-09 10:10:06.276646 +0800 CST   	deployed	cilium-1.20.4                 	1.20.4     
loki              	logging      	3       	2026-11-09 12:14:12.214452847 +0800 CST	deployed	loki-6.55.0                   	3.6.7      
otel-operator     	opentelemetry	1       	2026-03-03 10:25:21.158569862 +0800 CST	deployed	opentelemetry-operator-0.106.0	0.145.0    
prometheus        	monitoring   	13      	2026-11-09 14:33:58.051804859 +0000 UTC	deployed	kube-prometheus-stack-83.7.0  	v0.90.1    
prometheus-adapter	monitoring   	3       	2026-11-09 22:55:09.892700316 +0800 CST	deployed	prometheus-adapter-5.3.0      	v0.12.0    
tempo3            	logging      	6       	2026-09-28 18:44:57.415859646 +0800 CST	deployed	tempo-distributed-3.7.0       	3.0.3      
vpa               	kube-system  	2       	2026-10-12 16:41:36.994626176 +0800 CST	deployed	vertical-pod-autoscaler-0.12.0	1.7.1      
```

## ArgoCD Applications
```text
app-of-apps                  Synced   Healthy
china-study-free             Synced   Healthy
compassio                    Synced   Healthy
deeptutor                    Synced   Healthy
open-webui                   Synced   Healthy
platform-alloy-config        Synced   Healthy
platform-ceph-csi            Synced   Healthy
platform-ceph-csi-drivers    Synced   Healthy
platform-ceph-csi-operator   Synced   Healthy
platform-cicd                Synced   Healthy
platform-cilium-l2           Synced   Healthy
platform-cnpg-cluster        Synced   Healthy
platform-cnpg-operator       Synced   Healthy
platform-cnpg-plugin         Synced   Healthy
platform-etcd-backup         Synced   Healthy
platform-gateway-api         Synced   Healthy
platform-grafana             Synced   Healthy
platform-grafana-operator    Synced   Healthy
platform-kafka-cluster       Synced   Healthy
platform-kafka-operator      Synced   Healthy
platform-metallb             Synced   Healthy
platform-monitoring-crds     Synced   Healthy
platform-monitoring-rules    Synced   Healthy
platform-monitoring-stack    Synced   Healthy
platform-monitoring-wecom    Synced   Healthy
platform-sealed-secrets      Synced   Healthy
platform-sso-oauth2-proxy    Synced   Healthy
platform-traefik             Synced   Healthy
platform-ui                  Synced   Healthy
tekton-config                Synced   Healthy
tekton-operator              Synced   Healthy
```

## CNI / Service 数据面
```text
NAME           READY   STATUS    RESTARTS      AGE   IP           NODE       NOMINATED NODE   READINESS GATES
cilium-5675l   1/1     Running   2 (19h ago)   29h   10.0.0.123   worker02   <none>           <none>
cilium-7zr5l   1/1     Running   1 (19h ago)   29h   10.0.0.121   master01   <none>           <none>
cilium-88bkp   1/1     Running   1 (19h ago)   29h   10.0.0.61    m01        <none>           <none>
cilium-brnfm   1/1     Running   1 (19h ago)   29h   10.0.0.124   worker03   <none>           <none>
cilium-gdfsr   1/1     Running   1 (19h ago)   29h   10.0.0.120   master02   <none>           <none>
cilium-h28cj   1/1     Running   1 (19h ago)   29h   10.0.0.122   worker01   <none>           <none>

true
native
true

KVStore:                 Disabled   
Kubernetes:              Ok         1.35 (v1.35.9) [linux/amd64]
Kubernetes APIs:         ["cilium/v2::CiliumCIDRGroup", "cilium/v2::CiliumClusterwideNetworkPolicy", "cilium/v2::CiliumEndpoint", "cilium/v2::CiliumNetworkPolicy", "cilium/v2::CiliumNode", "core/v1::Pods", "networking.k8s.io/v1::NetworkPolicy"]
KubeProxyReplacement:    True   [eth0   10.0.0.124 fe80::be24:11ff:feb2:3691 (Direct Routing)]
Host firewall:           Disabled
SRv6:                    Disabled
CNI Chaining:            none
CNI Config file:         successfully wrote CNI configuration file to /host/etc/cni/net.d/05-cilium.conflist
Cilium:                  Ok   1.20.4 (v1.20.4-beb276d2)
NodeMonitor:             Listening for events on 4 CPUs with 64x4096 of shared memory
Cilium health daemon:    Ok   
IPAM:                    IPv4: 46/254 allocated from 10.244.5.0/24, 
IPv4 BIG TCP:            Disabled
IPv6 BIG TCP:            Disabled
BandwidthManager:        Disabled
Routing:                 Network: Native   Host: BPF
Attach Mode:             Legacy TC
Device Mode:             veth
Masquerading:            BPF   [eth0]   10.244.0.0/16  [IPv4: Enabled, IPv6: Disabled]
Controller Status:       234/234 healthy
Proxy Status:            OK, ip 10.244.5.157, 0 redirects active on ports 10000-20000, Envoy: embedded
Global Identity Range:   min 256, max 65535
Hubble:                  Ok              Current/Max Flows: 4095/4095 (100.00%), Flows/s: 198.32   Metrics: Ok
Encryption:              Disabled        
Cluster health:          6/6 reachable   (2026-11-10T08:00:44Z)   (Probe interval: 2m33.896961447s)
```

## 存储
```text
NAME          PROVISIONER        RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
ceph-rbd-sc   rbd.csi.ceph.com   Retain          Immediate           true                   220d
nfs-sc        example.com/nfs    Delete          Immediate           false                  296d

     17 Bound

17
```

## Ceph
```text
  cluster:
    id:     594e535e-d82c-11f0-afa7-bc24112b746f
    health: HEALTH_OK
 
  services:
    mon: 3 daemons, quorum ceph-02,ceph-03,ceph-01 (age 5d)
    mgr: ceph-02.wzbtbx(active, since 5d), standbys: ceph-01.egryfx
    mds: 1/1 daemons up, 2 standby
    osd: 6 osds: 6 up (since 5d), 6 in (since 10M)
    rgw: 2 daemons active (2 hosts, 1 zones)
 
  data:
    volumes: 1/1 healthy
    pools:   15 pools, 465 pgs
    objects: 18.64k objects, 27 GiB
    usage:   81 GiB used, 99 GiB / 180 GiB avail
    pgs:     465 active+clean
 
  io:
    client:   10 KiB/s rd, 103 KiB/s wr, 9 op/s rd, 8 op/s wr
 
```

## 监控 / 日志 / 追踪
```text
NAME                                             READY   STATUS    RESTARTS      AGE
alertmanager-prometheus-alertmanager-0           2/2     Running   0             19h
prometheus-adapter-659886599f-zwdbp              1/1     Running   0             17h
prometheus-grafana-8975965b4-rk7gn               1/1     Running   0             179m
prometheus-kube-state-metrics-5d768dd8ff-m5phv   1/1     Running   0             19h
prometheus-operator-6d74f54c4c-n48hl             1/1     Running   0             19h
prometheus-prometheus-node-exporter-2kjq5        1/1     Running   2 (19h ago)   44h
prometheus-prometheus-node-exporter-4stgl        1/1     Running   1 (19h ago)   44h
prometheus-prometheus-node-exporter-nd6cr        1/1     Running   1 (19h ago)   44h
prometheus-prometheus-node-exporter-sjdxz        1/1     Running   1 (19h ago)   19h
prometheus-prometheus-node-exporter-vm6v5        1/1     Running   1 (19h ago)   44h
prometheus-prometheus-node-exporter-vnwx9        1/1     Running   1 (19h ago)   44h
prometheus-prometheus-prometheus-0               2/2     Running   0             17h
wecom-adapter-7ddcb575f-jthfk                    1/1     Running   0             19h
wecom-adapter-7ddcb575f-phlxl                    1/1     Running   0             19h

NAME                                        READY   STATUS    RESTARTS      AGE
alloy-b7c77                                 2/2     Running   0             18h
alloy-fcc5c                                 2/2     Running   0             18h
alloy-lgmwg                                 2/2     Running   0             18h
alloy-mmvxv                                 2/2     Running   0             18h
alloy-mns8z                                 2/2     Running   0             18h
alloy-pptz2                                 2/2     Running   0             18h
loki-backend-0                              2/2     Running   0             19h
loki-canary-9w2rb                           1/1     Running   2 (19h ago)   32h
loki-canary-h927j                           1/1     Running   1 (19h ago)   32h
loki-canary-mvcfr                           1/1     Running   1 (19h ago)   32h
loki-chunks-cache-0                         2/2     Running   0             19h
loki-gateway-67fcc7bb44-7g4tr               1/1     Running   0             19h
loki-read-b7c85bb-pw9c6                     1/1     Running   0             19h
loki-results-cache-0                        2/2     Running   0             19h
loki-write-0                                1/1     Running   0             19h
tempo3-backend-scheduler-0                  1/1     Running   0             19h
tempo3-backend-worker-0                     1/1     Running   0             19h
tempo3-block-builder-0                      1/1     Running   3 (19h ago)   19h
tempo3-block-builder-1                      1/1     Running   0             19h

41
14
```

## 入口
```text
NAME      CONTROLLER                      PARAMETERS   AGE
traefik   traefik.io/ingress-controller   <none>       297d
NAME          TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)                      AGE
traefik       LoadBalancer   10.111.240.160   10.0.0.252    80:30156/TCP,443:30306/TCP   43d
traefik-api   ClusterIP      10.107.202.109   <none>        9000/TCP                     34m
NAMESPACE          NAME                        AGE
argocd             argocd                      43d
argocd             argocd-http-redirect        43d
kube-system        hubble                      5h9m
kube-system        hubble-http-redirect        5h9m
logging            alloy                       5h9m
logging            alloy-http-redirect         5h9m
monitoring         grafana                     43d
monitoring         grafana-http-redirect       34d
monitoring         prometheus                  291d
monitoring         prometheus-http-redirect    34d
oauth2-proxy       oauth2-alloy                43m
oauth2-proxy       oauth2-hubble               43m
oauth2-proxy       oauth2-tekton               43m
oauth2-proxy       oauth2-traefik              43m
tekton-pipelines   tekton-dashboard            2d18h
tekton-pipelines   tekton-dashboard-http       2d18h
traefik            traefik-dashboard           297d
traefik            traefik-xyz                 5h9m
traefik            traefik-xyz-http-redirect   5h9m
traefik            traefik-xyz-root            19m
```
