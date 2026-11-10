# Ansible 用于 Kubernetes 升级：优缺点分析

**背景**：本次 K8s 1.29.8 → 1.35.9 逐级升级全程使用 Bash + sshpass，未使用 Ansible。本文分析原因及 Ansible 的适用性。

---

## 一、为什么本次没用 Ansible

### 1.1 环境现状（实测）

Ansible **确实已安装**，但处于「装了没用起来」的状态：

```
ansible [core 2.14.18]        # 控制端在 m01
/usr/bin/ansible-playbook
/root/ansible.cfg              # 全部是默认注释，无实际配置
```

**但 inventory `/etc/ansible/hosts` 里没有本次集群的任何节点**：

```ini
[data:children]
backup        # 172.16.1.41
nfs           # 172.16.1.31
db            # 172.16.1.51
[lb]           # 172.16.1.5-6
[web]          # 172.16.1.8
[sweb]         # 172.16.1.9-10
```

这是**旧机房的 LNMP 时代资产**（172.16.x.x 网段，Nginx/PHP/MySQL/NFS 剧本）。而本次集群用的是 10.0.0.x 网段的 PVE 虚拟机，**inventory 里一条都没有**。

现有 playbook 也印证了使用习惯：

| 文件 | 日期 | 用途 |
|---|---|---|
| `nginx.install.yml` | 2025-10-02 | Nginx 安装 |
| `testphp.yml` | 2025-10-02 | PHP 测试 |
| `nfs-server.yml` | 2025-10-02 | NFS 服务端 |
| `zabbix_agent2_deploy.yml` | 2025-10-17 | Zabbix Agent |
| `set-hostname-hosts.yml` | 2025-10-02 | 主机名 |

**全是单机安装类剧本，零编排、零批量、零幂等设计** —— 这套资产与「滚动升级 6 节点 Kubernetes」不是一个量级的东西。

### 1.2 真实原因（诚实版）

**根本原因：我没有在开工前做环境盘点，直接上手写了 Bash 脚本。**

这是一个流程失误。正确的顺序应该是：

1. 先查环境有什么工具、有什么既有资产
2. 判断是否该复用既有工具链
3. 再动手

如果一开始就看到 `ansible-playbook` 已装，我至少应该：
- 问你要不要用 Ansible
- 或者先补 inventory，然后用 Ansible 写

**实际发生的是**：我按「升级脚本」的思路直接开写，用 `sshpass + bash` 逐节点执行。写到中途才遇到 containerd 脚本的 tar 参数问题、runc 路径问题、kubeadm 顺序问题……这些问题本可以在 Ansible 的 `until` 重试循环、jinja2 模板、错误处理里少踩一些。

### 1.3 但也不完全是失误 — 有 3 个客观因素

#### 因素一：跨发行版

| 节点 | OS | 包管理 |
|---|---|---|
| m01 | openEuler / EL9 系 | `dnf` |
| master01/02、worker01-03 | Ubuntu | `apt` |

Ansible 要写两套 `package` 分支或条件判断。本次我是分别用 `dnf install` 和 `apt-get install` 处理的，反而更直白。

> 注：`ansible.cfg` 里 `forks` 等参数未调优，说明这套 Ansible 从没认真用于过批量场景。

#### 因素二：升级过程需要大量人工介入判断

本次升级遇到的真实问题，**没有一个是纯幂等命令能解决的**：

| 问题 | 需要的判断 |
|---|---|
| `kubeadm upgrade apply` 版本拒绝 | 需要先装包再 apply，还要区分 CP/Worker |
| kubeadm 1.33 改成功提示语 | 需要人工确认输出，改 grep 模式 |
| master01 健康检查超时 | 需要人工 uncordon 后重试 |
| `crictl rm -a` 清掉镜像导致 Pod 重建失败 | 需要人工判断补镜像 |
| kube-state-metrics 镜像内容损坏 | 需要人工逐节点验证导出大小 |
| DNS/Kafka 验证误报 3 次 | 需要人工实测推翻脚本结论 |

**这些都需要「看着输出、临时改逻辑、继续跑」的循环**。Ansible 的 playbook 写死了以后，同样要临时改，只是改的地方从 Bash 脚本变成 YAML。

#### 因素三：单集群 6 节点，规模不大

Ansible 的核心价值在**几十到上百台**的批量管理。6 个节点手动控制，完全hold得住。

---

## 二、Ansible 用于 K8s 升级的优势

### 2.1 真正的强项

#### ✅ 幂等性

这是最实在的价值。本次升级我踩的坑里，至少 3 个用幂等能避免：

```bash
# 幂等：已装就不装，版本不对才升
- name: 安装指定版本 kubeadm
  apt:
    name: "kubeadm={{ kubeadm_version }}"
    state: present
    update_cache: yes
  when: kubeadm_version != ansible_facts.packages['kubeadm'][0]['version']
  # 或者直接用 kubeadm 模块的 check_mode
```

对比我这次的手工判断：
```bash
# 我写的：每台都执行，不判断
apt-get install -y -qq kubeadm=1.33.13-1.1
```

#### ✅ 自动重试（这个本次最需要）

我为 `registry.k8s.io insufficient_scope` 反复重试、换源验证，全是手工循环：

```yaml
- name: 预拉镜像（带重试）
  command: "crictl pull {{ item }}"
  register: pull_result
  until: pull_result.rc == 0
  retries: 5
  delay: 5
  loop: "{{ images_to_prepull }}"
```

Ansible 的 `until/retries/delay` 是原生能力，Bash 里要自己写循环 + 判断。

#### ✅ 批量并发与失败隔离

```yaml
- name: 并发升级 worker（serial: 1 保证逐台）
  hosts: workers
  serial: 1
  any_errors_fatal: false   # 一台失败不影响其他
```

`serial: 1` 天然实现滚动升级，一台失败 `--limit` 重跑即可。

#### ✅ 结构化的执行顺序

本次脚本里这段硬编码顺序，是 CP 节点踩坑的核心：
```bash
install_pkgs → kubeadm upgrade apply → restart kubelet
```

用 Ansible 就是 YAML 的线性结构，一眼看得懂，不会搞反：
```yaml
- include_tasks: install-packages.yml
- include_tasks: kubeadm-apply.yml
- include_tasks: restart-kubelet.yml
```

#### ✅ 变量集中管理

```yaml
vars:
  k8s_from: "1.35.9"
  k8s_to: "1.36.0"
  pause_image: "registry.aliyuncs.com/google_containers/pause:3.10"
  containerd_registry_mirror: "k8s.1ms.run"
```
改版本、改镜像源只改一处，不用 `sed` 脚本。

#### ✅ 结构化日志与可回溯

`json` callback plugin 输出结构化日志，便于事后审计。本次我只能靠翻 `series.log` 猜哪级失败了。

#### ✅ check_mode 预演

`--check` 可以先跑一遍看会改什么，不实际执行。

---

## 三、Ansible 用于 K8s 升级的劣势

### 3.1 硬伤

#### ❌ 安装到控制端不够，还得解决 6 节点的发行版差异

Ansible 本体只在 m01，装了不代表能用。inventory 里这 6 个节点一条都没有 —— **这是本次没用 Ansible 的直接原因**：用之前得先补资产，而补资产这件事本次跳过了。

#### ❌ 集群状态类操作本质上不适合声明式

`kubeadm upgrade apply` 是**有状态的、顺序敏感的**操作。Ansible 的模型是「声明目标状态 → 让它变成那样」，而 K8s 升级是「走一串有序步骤」。用 `command` 模块强行表达，本质上只是把 Bash 包了一层。

#### ❌ 幂等反而可能掩盖问题

`kubeadm upgrade` 是**天然不幂等**的。写成幂等 playbook 时，必须小心：

```yaml
# 危险：第二次运行这个 task 会被 skip，但它可能需要再跑
- name: kubeadm upgrade apply
  command: kubeadm upgrade apply v{{ k8s_to }}
  changed_when: "'SUCCESS' in result.stdout"   # ← 靠输出判断，脆
```

本次就有真实的踩坑：**kubeadm 1.33 改了成功提示语**，导致幂等判断失效。这个问题在 Ansible 里同样存在。

#### ❌ 大集群执行时间可能超过 SSH 超时

6 个节点无所谓，几百节点时 `serial` + `forks` 的组合需要仔细调优。本次 `ansible.cfg` 里 `forks` 都没设置过。

---

## 四、本次升级的实际数据（对比）

| 环节 | 本次实际耗时 | 说明 |
|---|---|---|
| containerd 升级（6 节点） | ~90 分钟 | 含 5 个脚本 bug 修复 |
| Calico 两步升级 | ~40 分钟 | 顺利 |
| K8s 1.30 | ~60 分钟 | 遇 bind-address 问题 |
| K8s 1.31 | ~30 分钟 | 顺利 |
| K8s 1.32 | ~90 分钟 | **遇 kubeadm 顺序 bug，apply 静默失败** |
| K8s 1.33 | ~60 分钟 | 遇版本拒绝 + 成功提示语变更 |
| K8s 1.34 | ~30 分钟 | 顺利 |
| K8s 1.35 | ~32 分钟 | 顺利 |
| 镜像通道排查 | ~40 分钟 | 1ms.run 配置 |
| n8n 镜像修复 | ~10 分钟 | SWR 路径 |

**总计约 8 小时**（跨多次会话），其中**约 3 小时消耗在脚本 bug 和镜像问题上**。

如果用 Ansible 重写，这 3 小时里至少能省下 1 小时（重试逻辑、幂等判断、并发控制）。但**版本拒绝、成功提示语变更、镜像损坏**这三类问题，Ansible 同样解决不了 —— 那是需要对环境的真实理解。

---

## 五、结论与建议

### 5.1 本次不用 Ansible 是否合理？

**不完全合理，但可接受。**

- **不合理的地方**：开工前没查环境，漏掉了已有的 Ansible 资产
- **可接受的地方**：6 节点规模不大；升级过程需要大量人工介入判断；跨发行版增加 playbook 复杂度

### 5.2 Ansible 升级 Kubernetes 的最佳实践

如果重来一次，我会这样组织：

```
/root/k8s-ansible/
├── inventory/
│   └── hosts                    # ← 必须先补：6 节点 + 分组
│       [k8s_cp]  m01 master01 master02
│       [k8s_worker] worker01 worker02 worker03
├── group_vars/
│   ├── all.yml                  # 版本、镜像源等公共变量
│   └── k8s_cp.yml              # CP 专用：kubeadm apply
├── roles/
│   ├── k8s-preflight/           # 版本检查、etcd 健康、快照
│   ├── containerd/              # containerd + runc 升级
│   ├── calico/                  # Calico 升级
│   └── k8s-upgrade/             # 逐级升级主逻辑
├── playbooks/
│   └── upgrade.yml
└── README.md
```

**核心 task 结构**（对比本次 Bash 的教训）：

```yaml
- name: 升级 control-plane
  hosts: k8s_cp
  serial: 1
  any_errors_fatal: false
  tasks:
    - name: 创建 etcd 快照
      include_tasks: snapshot.yml

    - name: 预拉镜像（带重试）
      include_tasks: prepull.yml

    # ★ 本次踩坑：顺序必须是 装包 → apply → 重启
    #   提前重启 kubelet 会让静态 Pod 用旧 manifest 重建
    - name: 安装 kubeadm/kubelet/kubectl
      include_tasks: install-packages.yml

    - name: kubeadm upgrade apply
      command: >
        kubeadm upgrade apply v{{ k8s_to }}
        -y
        --ignore-preflight-errors=CoreDNSUnsupportedPlugins
      register: apply_result
      # ★ kubeadm ≤1.32 是 "[upgrade/successful]"，≥1.33 是 "[upgrade] SUCCESS!"
      until: apply_result.rc == 0
      retries: 2
      delay: 30
      failed_when:
        - apply_result.rc != 0
        - "'SUCCESS' not in apply_result.stdout"
        - "'upgrade/successful' not in apply_result.stdout"

    - name: 重启 kubelet
      systemd:
        name: kubelet
        state: restarted

    - name: 修复 metrics bind-address（kubeadm 1.30+ 会重置为 127.0.0.1）
      command: >
        sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/'
        /etc/kubernetes/manifests/kube-controller-manager.yaml
        /etc/kubernetes/manifests/kube-scheduler.yaml
```

### 5.3 三点核心建议

1. **先补 inventory** —— 这是使用 Ansible 的前置条件。`/etc/ansible/hosts` 里现在还是 172.16.x.x 的旧资产，K8s 集群一条都没有。

2. **Ansible 解决「重复执行」，解决不了「判断对错」**
   本次真正的难点是 kubeadm 版本规则、镜像源可达性、容器内容完整性 —— 这些需要人理解环境，工具替代不了。

3. **`serial: 1` + `until/retries` 是最大收益点**
   滚动控制和自动重试是 Ansible 在这个场景下最实用的两个能力。

---

## 六、一句话总结

**Ansible 能让 Kubernetes 升级更幂等、更可重试、更结构化，但不能让你不用理解 kubeadm 的版本规则和镜像源的真实可达性。本次没用 Ansible 是流程疏漏（没先查环境），但升级中遇到的真实障碍也大多超出了 Ansible 的能力范围。**