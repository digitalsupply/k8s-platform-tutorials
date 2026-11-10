#!/usr/bin/env python3
"""只读集群盘点：生成 Markdown 或 JSON 快照。

依赖：python3（标准库）+ kubectl，可选 helm / ceph。
不会修改集群，不会读取 Secret 内容。

用法：
    python3 cluster_inventory.py --format md   > cluster.md
    python3 cluster_inventory.py --format json > cluster.json
    python3 cluster_inventory.py --format md --context prod
"""
import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone


def run(cmd, timeout=30):
    """执行命令，失败返回空字符串。"""
    if not shutil.which(cmd[0]):
        return ""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.stdout.strip()
    except Exception:
        return ""


def kubectl_json(args):
    out = run(args + ["-o", "json"])
    if not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def collect(context=None):
    k = ["kubectl"] + (["--context", context] if context else [])
    data = {
        "collected_at": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        "context": context or run(k + ["config", "current-context"]),
        "version": run(k + ["version"]),
        "nodes": [],
        "namespaces": [],
        "helm": [],
        "argocd_apps": [],
        "storage_classes": [],
        "pv_phases": {},
        "pvc_count": 0,
        "cilium": {},
        "ceph": run(["ceph", "-s"]) if shutil.which("ceph") else "",
        "counts": {},
    }

    nodes = kubectl_json(k + ["get", "nodes"])
    for n in (nodes or {}).get("items", []):
        meta, status, spec = n["metadata"], n.get("status", {}), n.get("spec", {})
        addrs = {a["type"]: a["address"] for a in status.get("addresses", [])}
        data["nodes"].append({
            "name": meta["name"],
            "roles": ",".join(r for r in ("control-plane", "master", "worker")
                              if "node-role.kubernetes.io/" + r in meta.get("labels", {})) or "worker",
            "ready": next((c["status"] for c in status.get("conditions", [])
                           if c["type"] == "Ready"), "Unknown"),
            "version": status.get("nodeInfo", {}).get("kubeletVersion", ""),
            "os": status.get("nodeInfo", {}).get("osImage", ""),
            "runtime": status.get("nodeInfo", {}).get("containerRuntimeVersion", ""),
            "internal_ip": addrs.get("InternalIP", ""),
            "cpu": status.get("capacity", {}).get("cpu", ""),
            "memory": status.get("capacity", {}).get("memory", ""),
            "pods": status.get("capacity", {}).get("pods", ""),
            "pod_cidr": spec.get("podCIDR", ""),
        })

    ns = kubectl_json(k + ["get", "namespaces"])
    data["namespaces"] = sorted(i["metadata"]["name"] for i in (ns or {}).get("items", []))

    helm = run(["helm", "list", "-A", "--no-headers"])
    for line in helm.splitlines():
        cols = line.split("\t")
        if len(cols) >= 8:
            data["helm"].append({
                "name": cols[0].strip(), "namespace": cols[1].strip(),
                "revision": cols[2].strip(), "updated": cols[3].strip(),
                "status": cols[4].strip(), "chart": cols[5].strip(),
                "app_version": cols[6].strip(),
            })

    apps = kubectl_json(k + ["-n", "argocd", "get", "applications"])
    for a in (apps or {}).get("items", []):
        data["argocd_apps"].append({
            "name": a["metadata"]["name"],
            "sync": a.get("status", {}).get("sync", {}).get("status", ""),
            "health": a.get("status", {}).get("health", {}).get("status", ""),
        })
    data["argocd_apps"].sort(key=lambda x: x["name"])

    sc = kubectl_json(k + ["get", "storageclasses"])
    for s in (sc or {}).get("items", []):
        data["storage_classes"].append({
            "name": s["metadata"]["name"],
            "provisioner": s.get("provisioner", ""),
            "reclaim_policy": s.get("reclaimPolicy", ""),
            "binding_mode": s.get("volumeBindingMode", ""),
            "allow_expansion": bool(s.get("allowVolumeExpansion", False)),
        })

    pv = kubectl_json(k + ["get", "pv"])
    for item in (pv or {}).get("items", []):
        phase = item.get("status", {}).get("phase", "Unknown")
        data["pv_phases"][phase] = data["pv_phases"].get(phase, 0) + 1
    pvc = kubectl_json(k + ["get", "pvc", "-A"])
    data["pvc_count"] = len((pvc or {}).get("items", []))

    cm = kubectl_json(k + ["-n", "kube-system", "get", "cm", "cilium-config"])
    if cm:
        d = cm.get("data", {})
        data["cilium"] = {
            "version": run(k + ["-n", "kube-system", "get", "ds", "cilium",
                                "-o", "jsonpath={.spec.template.spec.containers[0].image}"]),
            "kube_proxy_replacement": d.get("kube-proxy-replacement", ""),
            "routing_mode": d.get("routing-mode", ""),
            "l2_announcements": d.get("enable-l2-announcements", ""),
            "ipam": d.get("ipam", ""),
        }

    pods = kubectl_json(k + ["get", "pods", "-A"])
    if pods:
        items = pods.get("items", [])
        data["counts"]["pods"] = len(items)
        data["counts"]["running"] = sum(1 for p in items
                                        if p.get("status", {}).get("phase") == "Running")
        data["counts"]["not_ready"] = sum(
            1 for p in items
            if p.get("status", {}).get("phase") == "Running"
            and any(c.get("type") == "Ready" and c.get("status") != "True"
                    for c in p.get("status", {}).get("conditions", [])))
    data["counts"]["services"] = len((kubectl_json(k + ["get", "svc", "-A"]) or {}).get("items", []))
    data["counts"]["crds"] = len((kubectl_json(k + ["get", "crd"]) or {}).get("items", []))
    return data


def to_markdown(d):
    lines = [f"# 集群盘点快照", "",
             f"> 采集时间：{d['collected_at']}  ",
             f"> context：`{d['context']}`", ""]
    lines += ["## 版本", "```text", d["version"] or "kubectl 不可用", "```", ""]
    lines += ["## 节点", "| 节点 | 角色 | Ready | 版本 | 系统 | 运行时 | 内网 IP | CPU | 内存 | PodCIDR |",
              "|---|---|---|---|---|---|---|---|---|---|"]
    for n in d["nodes"]:
        lines.append("| {name} | {roles} | {ready} | {version} | {os} | {runtime} | {internal_ip} | {cpu} | {memory} | {pod_cidr} |".format(**n))
    lines += ["", "## 资源对象", "| 项 | 数量 |", "|---|---|"]
    for k, v in d["counts"].items():
        lines.append(f"| {k} | {v} |")
    lines += ["", "## Helm Releases", "| Release | Namespace | Chart | App | 状态 |", "|---|---|---|---|---|"]
    for h in d["helm"]:
        lines.append(f"| {h['name']} | {h['namespace']} | {h['chart']} | {h['app_version']} | {h['status']} |")
    lines += ["", "## ArgoCD Applications", "| App | Sync | Health |", "|---|---|---|"]
    for a in d["argocd_apps"]:
        lines.append(f"| {a['name']} | {a['sync']} | {a['health']} |")
    lines += ["", "## CNI", "```json", json.dumps(d["cilium"], ensure_ascii=False, indent=2), "```"]
    lines += ["", "## 存储", "| StorageClass | Provisioner | Reclaim | Binding | 扩容 |", "|---|---|---|---|---|"]
    for s in d["storage_classes"]:
        lines.append(f"| {s['name']} | {s['provisioner']} | {s['reclaim_policy']} | {s['binding_mode']} | {s['allow_expansion']} |")
    lines += ["", f"PV 状态：`{json.dumps(d['pv_phases'], ensure_ascii=False)}`；PVC 总数：`{d['pvc_count']}`"]
    if d["ceph"]:
        lines += ["", "## Ceph", "```text", d["ceph"], "```"]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=("md", "json"), default="md")
    ap.add_argument("--context", default=None)
    args = ap.parse_args()
    data = collect(args.context)
    if args.format == "json":
        json.dump(data, sys.stdout, ensure_ascii=False, indent=2)
        print()
    else:
        print(to_markdown(data))


if __name__ == "__main__":
    main()
