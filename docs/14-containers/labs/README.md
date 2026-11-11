# 容器实验手册

> 优先只读。需要创建容器时，请在实验机/非生产 Harbor/GitLab 上做。
> 生产节点只做 `docker/crictl/ctr` 查询。

## 实验 0：运行时盘点

```bash
docker version 2>/dev/null
docker info 2>/dev/null | grep -E 'Server Version|Storage Driver|Cgroup|Runtimes|Default Runtime'

crictl version
crictl info | head -40
ctr namespaces list
ctr -n k8s.io containers list | head
ctr -n moby containers list | head
```

验收：

- 能说出这台机器用 Docker 还是 containerd/CRI；
- 能解释 `ctr` 默认 namespace 为什么看不到镜像。

## 实验 1：镜像与层

```bash
docker images
docker history --no-trunc <image> | head -15
docker system df -v

crictl images
crictl imagefsinfo
ctr -n k8s.io images list | head

du -sh /var/lib/docker /var/lib/containerd /var/lib/buildkitd-cache 2>/dev/null
```

验收：

- 能区分镜像大小/实际占用/可回收；
- 能解释“删容器不释放镜像”；
- 能找到 BuildKit 缓存。

## 实验 2：生命周期

```bash
crictl pods
crictl ps -a
crictl inspect <container-id> | head -80
crictl inspectp <pod-id> | head -80
crictl logs --tail=50 <container-id>

ps -eo pid,ppid,user,stat,comm,args | grep -E 'containerd|shim|pause' | grep -v grep
```

验收：

- 能画出 `containerd → shim → pause/业务进程`；
- 能解释 `attempt 0/1` 旧 sandbox；
- 能说出退出码 137/132 的区别。

## 实验 3：网络 namespace

```bash
crictl pods --no-trunc
crictl inspectp <pod-id> | jq '.info.runtimeSpec.linux.namespaces'

nsenter --net=/proc/<pid>/ns/net ip -br a
nsenter --net=/proc/<pid>/ns/net ip r
nsenter --net=/proc/<pid>/ns/net cat /etc/resolv.conf

ip -br link | grep -E 'lxc|cilium|veth'
ip r
cilium status
```

验收：

- 能分辨 hostNetwork Pod 与普通 Pod；
- 能解释 Pod IP `10.244.x.x` 与节点 IP `10.0.0.x`；
- 能找到 `lxc*` veth 与 Pod 内 `eth0@ifX` 的对应关系。

## 实验 4：存储

```bash
df -hT; df -i
findmnt -t overlay -o TARGET,SOURCE,OPTIONS | head
crictl imagefsinfo
docker system df -v
du -sh /var/lib/docker /var/lib/containerd /var/lib/buildkitd-cache
```

验收：

- 能解释容器里 `df` 为什么是宿主机；
- 能解释 overlay 行不能相加；
- 能列出节点镜像/缓存/日志三类占用。

## 实验 5：安全审计

```bash
# 哪些 Pod privileged/hostNetwork
kubectl get pods -A -o json | jq -r '
  .items[] | select(.spec.hostNetwork==true or
    ([.spec.containers[].securityContext.privileged] | any))
  | [.metadata.namespace,.metadata.name,.spec.hostNetwork] | @tsv'

# 单个容器的 capability
crictl inspect <id> | jq '.info.runtimeSpec.process.capabilities'

# Docker
docker inspect <container> | jq '.[0].HostConfig | {Privileged,CapAdd,CapDrop,SecurityOpt}'
```

验收：

- 能说出哪些是平台组件、哪些是业务；
- 能解释 `CAP_SYS_ADMIN` 的风险；
- 能写一个 `drop: ["ALL"]` + `RuntimeDefault` 的 securityContext。

## 实验 6：排障一个异常 Pod

```bash
kubectl get pods -A | grep -v -E 'Running|Completed' | head
kubectl describe pod -n <ns> <pod>
kubectl logs -n <ns> <pod> --previous --tail=100
crictl ps -a | grep <pod-name>
crictl inspect <id>
journalctl -u containerd -n 100 --no-pager
journalctl -u kubelet -n 100 --no-pager
```

验收：

- 能区分 `ImagePullBackOff`/`CreateContainerConfigError`/`CrashLoopBackOff`；
- 能判断是镜像、运行时、存储、网络还是应用问题。

## 实验 7（可选）：在实验机跑一个受限容器

只在**非生产**实验机执行：

```bash
# 用本地已有镜像，避免拉取
docker run --rm --network none --cap-drop ALL \
  --security-opt no-new-privileges \
  --memory 64m --pids-limit 32 \
  <local-image> sh -c 'id; cat /proc/self/status | grep -E "Cap|Seccomp"'
```

验收：

- 容器里 `CapEff` 为空/最小；
- 内存/PIDs 限制生效；
- 删除后 `docker ps -a` 无残留。

## 清理

```bash
# 只清理自己创建的实验容器/镜像
docker ps -a
docker rm <id>
docker rmi <image>

# 不要在生产节点执行全量 prune
```

> 生产节点只做只读查询；`crictl rm`、`docker system prune`、`buildctl prune` 都要先确认影响。
