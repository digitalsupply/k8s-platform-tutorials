# 06 · 容器安全：capability、seccomp、LSM 与 Pod Security

> 证据：[`k8s-security/pod-security-summary.txt`](../05-linux/assets/evidence/k8s-security/pod-security-summary.txt)、
> [`k8s/inspect-cilium.json`](assets/evidence/k8s/inspect-cilium.json)、
> [`k8s/inspect-frpc.json`](assets/evidence/k8s/inspect-frpc.json)、
> [`k8s/inspect-node-exporter.json`](assets/evidence/k8s/inspect-node-exporter.json)、
> [`docker/harbor-inspect.txt`](assets/evidence/docker/harbor-inspect.txt)。

## 1. 容器安全的六层

```text
1. 用户：root / 非 root / user namespace
2. capability：CAP_NET_ADMIN / CAP_SYS_ADMIN ...
3. seccomp：允许哪些 syscall
4. LSM：SELinux / AppArmor
5. namespace：PID/NET/MNT/HOST
6. cgroup：CPU/内存/PIDs 限制
```

少一层，逃逸/提权面就大一层。

## 2. 默认 capability

容器默认通常有 14 个 capability（Docker/runc 默认集）：

```text
CHOWN, DAC_OVERRIDE, FSETID, FOWNER, MKNOD, NET_RAW,
SETGID, SETUID, SETFCAP, SETPCAP, NET_BIND_SERVICE,
SYS_CHROOT, KILL, AUDIT_WRITE
```

真实 frpc Pod（普通容器）：

```json
"bounding": ["CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_FSETID","CAP_FOWNER",
"CAP_MKNOD","CAP_NET_RAW","CAP_SETGID","CAP_SETUID","CAP_SETFCAP",
"CAP_SETPCAP","CAP_NET_BIND_SERVICE","CAP_SYS_CHROOT","CAP_KILL","CAP_AUDIT_WRITE"]
```

这些已经足够做很多事；业务 Pod 应 `drop: ["ALL"]` 再按需 add。

## 3. privileged / hostNetwork / hostPID

| 配置 | 含义 | 风险 |
|---|---|---|
| `privileged: true` | 所有 capability、所有设备、关闭 seccomp/AppArmor | 近乎 root 宿主 |
| `hostNetwork: true` | 共享宿主 netns | 端口冲突、抓包、访问宿主服务 |
| `hostPID: true` | 看到宿主进程 | 可 ptrace/注入 |
| `hostIPC: true` | 共享 IPC | 共享内存攻击 |
| `hostPath` | 挂宿主目录 | 读写宿主文件 |
| `/var/run/docker.sock` | 挂 Docker socket | 等于宿主 root |

## 4. 真机证据

### 4.1 138 个 Pod 的统计

```text
summary: pods=138 hostNetwork=35 privileged=10 capAdd=19
```

典型：

| Pod | hostNetwork | privileged | added caps |
|---|---|---|---|
| `cilium-*` | true | true | `NET_ADMIN,NET_RAW,SYS_ADMIN,SYS_MODULE,SYS_PTRACE,SYS_RESOURCE,...` |
| `rbd.csi.ceph.com-nodeplugin-*` | true | true | `SYS_ADMIN` |
| `buildkitd-*` | false | true | - |
| `deeptutor-*` | false | false | `CHOWN,DAC_OVERRIDE,FOWNER,SETGID,SETUID` |
| `coredns-*` | false | false | `NET_BIND_SERVICE` |
| `kube-vip-ds-*` | true | false | `NET_ADMIN,NET_RAW` |
| `node-exporter-*` | true | false | - |

平台组件（Cilium/CSI/BuildKit）需要特权；业务 Pod 不需要。

### 4.2 Cilium 的 capability

```json
bounding: [
 "CAP_CHOWN","CAP_KILL","CAP_NET_ADMIN","CAP_NET_RAW","CAP_IPC_LOCK",
 "CAP_SYS_MODULE","CAP_SYS_ADMIN","CAP_SYS_RESOURCE","CAP_DAC_OVERRIDE",
 "CAP_FOWNER","CAP_SETGID","CAP_SETUID","CAP_SYSLOG"
]
```

`CAP_SYS_ADMIN` + `CAP_SYS_MODULE` 基本等于“能改内核/网络”。Cilium 是 CNI，必须这样；
但不能让业务 Pod 复制这个配置。

### 4.3 Harbor 的容器安全

Harbor core：

```text
Privileged: False
CapAdd: ['CAP_SETGID', 'CAP_SETUID']
CapDrop: ['ALL']
NetworkMode: harbor_harbor
ReadonlyRootfs: False
SecurityOpt: None
Binds: /data, /etc/core/app.conf, private_key.pem, ...
```

这是“最小 capability”的正面例子：先 drop ALL，再加需要的 SETGID/SETUID。

### 4.4 node-exporter 的 hostNetwork/hostPID

```text
hostNetwork: true
hostPID: true
```

它需要读 `/host/proc`、`/host/sys`；但这也意味着它能看宿主进程，必须限制镜像/权限。

## 5. 推荐的 securityContext

示例文件：[`assets/examples/secure-pod.yaml`](assets/examples/secure-pod.yaml)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-demo
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: app
      image: example/app:1.0.0
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 500m
          memory: 256Mi
```

需要写临时目录时挂 `emptyDir`，不要为了省事开 `readOnlyRootFilesystem: false`。

## 6. Pod Security Standards

K8s 内置三档：

| 档位 | 限制 |
|---|---|
| privileged | 几乎不限制 |
| baseline | 禁止 privileged/hostNetwork/hostPID/危险 cap |
| restricted | 非 root、seccomp、drop ALL、禁止提权 |

namespace 标签：

```yaml
pod-security.kubernetes.io/enforce: restricted
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/warn: restricted
```

平台组件 namespace 用 `privileged`，业务 namespace 用 `restricted`。

## 7. 审计命令

```bash
# 哪些 Pod privileged/hostNetwork/capAdd
kubectl get pods -A -o json | jq -r '
  .items[] | select(.spec.hostNetwork==true or
    ([.spec.containers[].securityContext.privileged] | any))
  | [.metadata.namespace,.metadata.name,.spec.hostNetwork] | @tsv'

# 容器 runtimeSpec 的 capability
crictl inspect <container-id> | jq '.info.runtimeSpec.process.capabilities'

# Docker
docker inspect <container> | jq '.[0].HostConfig | {Privileged,CapAdd,CapDrop,SecurityOpt}'

# 镜像扫描
trivy image <image>
```

## 8. 踩坑点

### 坑 1：`CAP_SYS_ADMIN` 不是“一个小权限”

它能 mount、改 namespace、操作大量内核对象。业务 Pod 加它，基本等于放弃隔离。

### 坑 2：privileged 关闭 seccomp/AppArmor

`privileged: true` 不是“多一点权限”，而是“几乎没有隔离”。

### 坑 3：hostNetwork 绕过 NetworkPolicy

hostNetwork Pod 的流量不经过 Pod veth，NetworkPolicy 可能不生效；要配合节点防火墙。

### 坑 4：挂 Docker socket

`/var/run/docker.sock` 等于宿主 root；不要挂进业务 Pod，CI 也要专用 runner。

### 坑 5：`allowPrivilegeEscalation` 默认可能为 true

业务 Pod 显式设 `false`，否则 setuid/file cap 可能提权。

### 坑 6：只 drop 部分 capability

`drop: ["ALL"]` 再按需 add；不要只 drop `NET_RAW`。

### 坑 7：seccomp 未启用

默认 `Unconfined` 的容器可以调更多 syscall；设 `RuntimeDefault`。

### 坑 8：readOnlyRootFilesystem 后应用写失败

应用要写 `/tmp`/缓存时挂 `emptyDir`，不要直接关 readOnly。

### 坑 9：镜像扫描不等于运行时安全

Trivy 只查已知漏洞；capability/privileged/hostPath 是配置风险，扫描器不一定报。

## 9. 一页命令

```bash
kubectl get pods -A -o json | jq -r '.items[] | [.metadata.namespace,.metadata.name,.spec.hostNetwork] | @tsv'
crictl inspect <id> | jq '.info.runtimeSpec.process.capabilities'
docker inspect <container> | jq '.[0].HostConfig | {Privileged,CapAdd,CapDrop,SecurityOpt}'
kubectl auth can-i --list
trivy image <image>
```
