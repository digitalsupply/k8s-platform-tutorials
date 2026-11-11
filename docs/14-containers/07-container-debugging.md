# 07 · 容器排障：从现象到运行时、镜像、网络、存储与安全

> 这一章是“命令手册 + 决策树”，配合 [08 案例](08-cases.md) 使用。
> 所有命令优先只读。

## 1. 先定位在哪一层

```text
Pod/容器不 Ready / 起不来
  ├─ 调度层：Pending、nodeSelector、资源不足、污点
  ├─ 镜像层：ImagePullBackOff、x509、manifest unknown
  ├─ 运行时层：CreateContainerError、RunContainerError、crictl 无容器
  ├─ 配置层：CreateContainerConfigError、Secret/ConfigMap 缺失
  ├─ 应用层：CrashLoopBackOff、退出码、日志
  ├─ 存储层：FailedMount、Multi-Attach、PVC Pending
  ├─ 网络层：DNS、Service、NetworkPolicy、CNI
  └─ 安全层：permission denied、SIGILL、OOMKilled、seccomp
```

## 2. K8s 层

```bash
kubectl get pod -o wide
kubectl describe pod <pod>
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl logs <pod> --tail=100
kubectl logs <pod> -c <container> --previous
kubectl exec -it <pod> -- sh
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>
```

看：

- `Status`/`Reason`/`Events`；
- `Last State` 的 exit code；
- `Limits`/`Requests`；
- `Node`/`Pod IP`；
- `Volumes`/`Mounts`。

## 3. 运行时层：crictl

```bash
crictl version
crictl info | head -40
crictl pods
crictl ps -a
crictl inspect <container-id>
crictl inspectp <pod-id>
crictl logs --tail=100 <container-id>
crictl stats <container-id>
crictl imagefsinfo
```

常见：

- `kubectl` 有 Pod，`crictl ps` 没有 → kubelet/containerd 状态不一致；
- `crictl ps -a` 有 Exited → 看退出码；
- `crictl inspect` 的 `status.reason`/`message`；
- `crictl inspect` 的 `info.runtimeSpec` 看 mounts/capabilities/namespaces。

## 4. containerd 层：ctr

```bash
ctr namespaces list
ctr -n k8s.io containers list | head
ctr -n k8s.io tasks list | head
ctr -n k8s.io images list | head
ctr -n k8s.io snapshots list | head
```

注意 namespace：`k8s.io`/`moby`，默认 namespace 是空的。

## 5. Docker 层

```bash
docker ps -a
docker inspect <container>
docker logs --tail=100 <container>
docker stats --no-stream
docker top <container>
docker exec -it <container> sh
docker system df -v
docker events --since 10m
```

## 6. 网络层

```bash
# Pod netns
crictl inspectp <pod-id> | jq '.info.runtimeSpec.linux.namespaces'
nsenter --net=/proc/<pid>/ns/net ip -br a
nsenter --net=/proc/<pid>/ns/net ip r
nsenter --net=/proc/<pid>/ns/net cat /etc/resolv.conf

# 宿主
ip -br link | grep -E 'lxc|cilium|veth'
ip r
cilium status
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```

## 7. 存储层

```bash
df -hT; df -i
findmnt -t overlay -o TARGET,SOURCE,OPTIONS | head
crictl imagefsinfo
du -sh /var/lib/containerd /var/lib/buildkitd-cache
kubectl get pvc -A
kubectl describe pvc <pvc>
```

## 8. 安全层

```bash
crictl inspect <id> | jq '.info.runtimeSpec.process.capabilities'
crictl inspect <id> | jq '.info.runtimeSpec.linux.seccomp'
docker inspect <c> | jq '.[0].HostConfig | {Privileged,CapAdd,CapDrop,SecurityOpt}'
kubectl get pod <pod> -o jsonpath='{.spec.securityContext}'
```

## 9. 常见错误对照表

| 现象/错误 | 根因 | 修复 |
|---|---|---|
| `ImagePullBackOff` | 镜像名/tag 错、registry 不可达、认证失败 | `crictl pull` 手动试；检查 `/etc/containerd/certs.d`、imagePullSecret |
| `x509: certificate signed by unknown authority` | 自签 Harbor CA 未配 | 节点 `/etc/containerd/certs.d/<registry>/hosts.toml` + `skip_verify`/CA |
| `manifest unknown` | tag 不存在/被覆盖 | 用 digest；查 Harbor |
| `CreateContainerConfigError` | Secret/ConfigMap 缺失 | `kubectl describe` 看 missing |
| `RunContainerError` | 运行时/权限/挂载失败 | `crictl inspect`、containerd 日志 |
| `CrashLoopBackOff` | 应用启动失败 | `kubectl logs --previous`；exit code |
| `OOMKilled` (137) | 超 `memory.max` | 提高 limit/查泄漏；`memory.events` |
| `SIGILL` (132) | CPU 指令不兼容 | `qm config` CPU v3；换镜像 |
| `Multi-Attach error` | RWO 卷旧节点未释放 | 查旧节点 rbd map/watcher；删旧 Pod/节点 |
| `FailedMount` | PVC/Secret/CSI 问题 | `describe pod`、CSI 日志 |
| `permission denied` | UID/capability/readOnly | securityContext/volume 权限 |
| `no such file or directory` | 入口脚本/解释器缺失 | `docker run --entrypoint sh` 查镜像 |
| `DiskPressure` | 镜像/日志/缓存占满 | `crictl rmi --prune`、清 BuildKit/日志 |

## 10. 日志在哪

```bash
# kubelet/containerd
journalctl -u kubelet -n 200 --no-pager
journalctl -u containerd -n 200 --no-pager

# Pod 日志
kubectl logs <pod>
crictl logs <container-id>
ls /var/log/pods/<ns>_<pod>_<uid>/

# Docker
docker logs <container>
journalctl -u docker -n 200 --no-pager
```

## 11. 一页命令

```bash
kubectl get pod -o wide
kubectl describe pod <pod>
kubectl logs <pod> --previous --tail=100
crictl ps -a
crictl inspect <id>
crictl inspectp <pod-id>
crictl logs --tail=100 <id>
crictl imagefsinfo
ctr -n k8s.io tasks list
docker ps -a
docker inspect <c>
docker system df -v
journalctl -u containerd -n 100 --no-pager
journalctl -u kubelet -n 100 --no-pager
```
