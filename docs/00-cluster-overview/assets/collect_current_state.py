#!/usr/bin/env python3
"""采集"当前状态"的唯一数字源（只读，不修改集群）。

用法：
    python3 docs/00-cluster-overview/assets/collect_current_state.py > /tmp/cs.md

输出是 Markdown，直接替换 current-state.md 里 <!-- BEGIN GENERATED --> 与
<!-- END GENERATED --> 之间的内容。所有"现在是多少"的数字只能来自这里。
"""
import json
import subprocess
import sys

def k(*args, js=False):
    p = subprocess.run(["kubectl", *args], capture_output=True, text=True)
    if p.returncode != 0:
        return None if js else ""
    return json.loads(p.stdout) if js else p.stdout.strip()

def sh(cmd):
    p = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return p.stdout.strip()

def table(rows, head):
    if not rows:
        return "（无）"
    out = ["| " + " | ".join(head) + " |", "|" + "|".join(["---"] * len(head)) + "|"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)

def prom(path, pod):
    raw = k("-n", "monitoring", "exec", pod, "-c", "prometheus", "--",
            "wget", "-qO-", f"http://127.0.0.1:9090{path}")
    return json.loads(raw) if raw else None

sections = []

# ---- 1. 版本 ----
ver = k("version", "-o", "json", js=True) or {}
sections.append(("1. 版本", table([
    ["Kubernetes", f"server {ver.get('serverVersion',{}).get('gitVersion','?')} / client {ver.get('clientVersion',{}).get('gitVersion','?')}"],
], ["组件", "版本"])))

# ---- 2. 节点 ----
nodes = k("get", "nodes", "-o", "json", js=True)["items"]
def tag(image):
    """从 image 里取 tag：剥掉 @sha256 摘要，再取最后一个冒号后的部分。"""
    if not image:
        return "?"
    image = image.split("@")[0]
    return image.rsplit(":", 1)[-1] if ":" in image.rsplit("/", 1)[-1] else "latest"

def short_os(s):
    s = s.replace("Rocky Linux ", "Rocky ").replace(" (Blue Onyx)", "")
    s = s.replace("Ubuntu ", "Ubuntu ").replace(" LTS", "")
    return s
rows = []
for n in nodes:
    cap = n["status"]["capacity"]; info = n["status"]["nodeInfo"]
    labels = " ".join(n["metadata"].get("labels", {}))
    mem_gib = int(cap["memory"][:-2]) / 1024 / 1024
    rows.append([n["metadata"]["name"],
                 "control-plane" if "control-plane" in labels else "worker",
                 info["kubeletVersion"], info["containerRuntimeVersion"].split("//")[-1],
                 short_os(info["osImage"]),
                 f'{cap["cpu"]}C / {round(mem_gib,1)}Gi (allocatable {n["status"]["allocatable"]["memory"]})'])
sections.append(("2. 节点与容量", table(rows, ["节点", "角色", "kubelet", "runtime", "OS", "CPU/内存"])))

# ---- 3. 对象计数 ----
counts = [
    ("namespaces", "namespaces"), ("pods", "pods"), ("deployments", "deployments"),
    ("statefulsets", "statefulsets"), ("daemonsets", "daemonsets"),
    ("services", "services"), ("cronjobs", "cronjobs"),
    ("PVC", "persistentvolumeclaims"), ("PV", "persistentvolumes"),
    ("StorageClass", "storageclasses"),
    ("ServiceMonitor", "servicemonitors.monitoring.coreos.com"),
    ("PodMonitor", "podmonitors.monitoring.coreos.com"),
    ("PrometheusRule", "prometheusrules.monitoring.coreos.com"),
    ("IngressRoute", "ingressroutes.traefik.io"),
    ("ArgoCD Application", "applications.argoproj.io"),
]
rows = []
for label, res in counts:
    out = sh(f"kubectl get {res} -A --no-headers 2>/dev/null | wc -l")
    rows.append([label, out])
sections.append(("3. 对象计数", table(rows, ["对象", "数量"])))

# ---- 4. 组件版本 ----
def img(ns, kind, name):
    return tag(k("-n", ns, "get", kind, name, "-o", "jsonpath={.spec.template.spec.containers[0].image}"))

def img_sts(ns, name):
    return tag(k("-n", ns, "get", "sts", name, "-o", "jsonpath={.spec.template.spec.containers[0].image}"))

rows = [
    ["CNI", "Cilium", tag(sh("kubectl -n kube-system get pod -l k8s-app=cilium -o jsonpath='{.items[0].spec.containers[0].image}'"))],
    ["数据面", "kube-proxy", "已移除（Cilium KPR 取代）"],
    ["运行时", "containerd", nodes[0]["status"]["nodeInfo"]["containerRuntimeVersion"].split("//")[-1]],
    ["etcd", "etcd", tag(sh("kubectl -n kube-system get pod -l component=etcd -o jsonpath='{.items[0].spec.containers[0].image}'"))],
    ["DNS", "CoreDNS", img("kube-system", "deploy", "coredns")],
    ["监控", "Prometheus", img_sts("monitoring", "prometheus-prometheus-prometheus")],
    ["监控", "Grafana", img("monitoring", "deploy", "prometheus-grafana")],
    ["监控", "Alertmanager", img_sts("monitoring", "alertmanager-prometheus-alertmanager")],
    ["日志", "Loki", img_sts("logging", "loki-write")],
    ["追踪", "Tempo", img_sts("logging", "tempo3-backend-worker")],
    ["采集", "Alloy", img("logging", "ds", "alloy")],
    ["GitOps", "ArgoCD", img("argocd", "deploy", "argocd-server")],
    ["入口", "Traefik", img("traefik", "deploy", "traefik")],
    ["数据库", "CNPG operator", tag(sh("kubectl -n cnpg-system get deploy -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'"))],
    ["存储", "Ceph-CSI RBD", tag(sh("kubectl -n ceph-csi-rbd get ds -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null"))],
]
sections.append(("4. 组件版本", table(rows, ["层", "组件", "版本"])))

# ---- 5. Prometheus 运行态 ----
pod = sh("kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}'")
al = prom("/api/v1/rules?type=alert", pod); rc = prom("/api/v1/rules?type=record", pod)
tg = prom("/api/v1/targets?state=active", pod); fl = prom("/api/v1/status/flags", pod)
firing = prom("/api/v1/query?query=ALERTS%7Balertstate%3D%22firing%22%7D", pod)
rows = [
    ["alerting rules", f"{len(al['data']['groups'])} 组 / {sum(len(g['rules']) for g in al['data']['groups'])} 条"],
    ["recording rules", f"{len(rc['data']['groups'])} 组 / {sum(len(g['rules']) for g in rc['data']['groups'])} 条"],
    ["规则求值错误", str(sum(1 for g in al['data']['groups'] for r in g['rules'] if r.get('health') == 'err'))],
    ["target", f"{len(tg['data']['activeTargets'])} 个，up {sum(1 for t in tg['data']['activeTargets'] if t['health']=='up')}"],
    ["retention.time", fl['data'].get('storage.tsdb.retention.time', '?')],
    ["retention.size", fl['data'].get('storage.tsdb.retention.size', '?')],
    ["firing", ", ".join(sorted({r['metric'].get('alertname') for r in (firing or {'data':{'result':[]}})['data']['result']})) or "none"],
]
sections.append(("5. Prometheus 运行态", table(rows, ["指标", "值"])))

# ---- 6. 存储 / Ceph ----
sc = k("get", "sc", "--no-headers")
pv = sh("kubectl get pv --no-headers | wc -l").strip()
pvbad = sh("kubectl get pv -o custom-columns=N:.metadata.name,S:.status.phase --no-headers | awk '$2!=\"Bound\"' | wc -l").strip()
pvc = sh("kubectl get pvc -A --no-headers | wc -l").strip()
pvcbad = sh("kubectl get pvc -A --no-headers | awk '$3!=\"Bound\"' | wc -l").strip()
ceph = sh("kubectl -n rook-ceph get cephcluster 2>/dev/null") or ""
sections.append(("6. 存储", table([
    ["StorageClass", ", ".join(sorted(l.split()[0] for l in sc.splitlines() if l.strip()))],
    ["PV 总数 / 非 Bound", f"{pv} / {pvbad}"],
    ["PVC 总数 / 非 Bound", f"{pvc} / {pvcbad}"],
    ["默认 SC 回收策略", "ceph-rbd-sc = Retain（删除后需手工清 RBD 镜像）"],
], ["项", "值"])))

# ---- 7. 入口 ----
tr = k("-n", "traefik", "get", "svc", "traefik", "-o", "json", js=True) or {}
lb = ((tr.get("status") or {}).get("loadBalancer") or {}).get("ingress") or [{}]
sections.append(("7. 入口", table([
    ["Traefik Service 类型", tr.get("spec", {}).get("type", "?")],
    ["Traefik LB 地址", lb[0].get("ip", "?")],
    ["API VIP", sh("kubectl -n kube-system get ds kube-vip-ds -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{\"\\n\"}{end}' 2>/dev/null | grep -i vip_address | cut -d= -f2") or "?"],
], ["项", "值"])))

print("<!-- BEGIN GENERATED -->")
print()
for title, body in sections:
    print(f"### {title}")
    print()
    print(body)
    print()
print("<!-- END GENERATED -->")
