# m01 实际配置快照（2026-11-10）

这些文件通过 SSH 从 `root@10.0.0.61` 只读采集，用于对照教程中的参数，不是凭空写的默认值。

| 文件 | 来源 |
|---|---|
| `nodes.txt` | `kubectl get nodes -o wide` |
| `kubeadm-config.yaml` | `kube-system/kubeadm-config` 的 `ClusterConfiguration` |
| `kubelet-config.yaml` | `kube-system/kubelet-config` 的 `kubelet` |
| `sysctl-k8s.conf` | `/etc/sysctl.d/k8s.conf` |
| `sysctl-rp-filter.conf` | `/etc/sysctl.d/99-zz-k8s-rp-filter.conf` |
| `modules-load-k8s.conf` | `/etc/modules-load.d/k8s.conf` |
| `containerd-key-settings.txt` | `/etc/containerd/config.toml` 的关键行 |
| `certs.d/all-hosts.toml` | `/etc/containerd/certs.d/*/hosts.toml` |

注意：

- 未采集任何 Secret、kubeconfig、证书或 token；
- `certs.d` 中的 registry/镜像加速地址是实验环境配置；
- `kubelet-config.yaml` 的 `systemReserved`/`kubeReserved` 是当前集群的实际值，新节点加入后会从 ConfigMap 继承。
