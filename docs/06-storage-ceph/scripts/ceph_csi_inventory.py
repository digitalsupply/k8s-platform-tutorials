#!/usr/bin/env python3
"""Ceph-CSI RBD 只读盘点。

用法:
    python3 ceph_csi_inventory.py
    python3 ceph_csi_inventory.py --format json

依赖: kubectl（当前 context 需有读取权限），只使用标准库。
"""

import argparse
import json
import subprocess
import sys


def kube(args):
    r = subprocess.run(["kubectl"] + args, capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError:
        return None


def items(obj):
    return (obj or {}).get("items", [])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["md", "json"], default="md")
    ap.add_argument("--operator-ns", default="ceph-csi-operator-system")
    ap.add_argument("--driver-ns", default="ceph-csi-rbd")
    args = ap.parse_args()

    op_deploys = items(kube(["-n", args.operator_ns, "get", "deploy", "-o", "json"]))
    drivers = items(kube(["-n", args.driver_ns, "get", "drivers.csi.ceph.io", "-o", "json"]))
    conns = items(kube(["-n", args.driver_ns, "get", "cephconnections.csi.ceph.io", "-o", "json"]))
    profiles = items(kube(["-n", args.driver_ns, "get", "clientprofiles.csi.ceph.io", "-o", "json"]))
    csidrivers = items(kube(["get", "csidriver", "-o", "json"]))
    scs = items(kube(["get", "storageclass", "-o", "json"]))
    pvs = items(kube(["get", "pv", "-o", "json"]))
    pvcs = items(kube(["get", "pvc", "-A", "-o", "json"]))
    pods = items(kube(["-n", args.driver_ns, "get", "pods", "-o", "json"]))
    helm = items(kube(["-n", args.driver_ns, "get", "secret", "-l", "owner=helm", "-o", "json"]))

    ceph_scs = [s for s in scs if s.get("provisioner", "").startswith("rbd.csi.ceph.com")]
    ceph_pvs = [p for p in pvs if p.get("spec", {}).get("csi", {}).get("driver") == "rbd.csi.ceph.com"]
    ceph_pvcs = [p for p in pvcs if p.get("spec", {}).get("storageClassName") in
                 {s["metadata"]["name"] for s in ceph_scs}]

    pv_phase, pvc_phase = {}, {}
    for p in ceph_pvs:
        k = p.get("status", {}).get("phase", "Unknown")
        pv_phase[k] = pv_phase.get(k, 0) + 1
    for p in ceph_pvcs:
        k = p.get("status", {}).get("phase", "Unknown")
        pvc_phase[k] = pvc_phase.get(k, 0) + 1

    warnings = []
    if helm:
        warnings.append(f"{args.driver_ns} 仍存在 {len(helm)} 个 Helm release secret，可能与 ArgoCD 争管")
    for s in ceph_scs:
        if s.get("reclaimPolicy") != "Retain":
            warnings.append(f"StorageClass {s['metadata']['name']} reclaimPolicy={s.get('reclaimPolicy')}（数据库卷建议 Retain）")
    if pv_phase.get("Released"):
        warnings.append(f"存在 {pv_phase['Released']} 个 Released PV（Retain 遗留，需人工核销）")
    if pvc_phase.get("Pending"):
        warnings.append(f"存在 {pvc_phase['Pending']} 个 Pending PVC")
    for d in drivers:
        if d.get("status", {}).get("phase") not in (None, "Ready"):
            warnings.append(f"Driver {d['metadata']['name']} phase={d['status'].get('phase')}")

    nodeplugin = [p for p in pods if "-nodeplugin" in p["metadata"]["name"]]
    ctrlplugin = [p for p in pods if "-ctrlplugin" in p["metadata"]["name"]]
    not_ready = [p["metadata"]["name"] for p in pods
                 if p.get("status", {}).get("phase") != "Running"]
    if not_ready:
        warnings.append("非 Running Pod: " + ", ".join(not_ready))

    high_restart = []
    for p in pods:
        for cs in p.get("status", {}).get("containerStatuses", []) or []:
            if cs.get("restartCount", 0) >= 5:
                high_restart.append(f"{p['metadata']['name']}/{cs.get('name')}={cs['restartCount']}")
    if high_restart:
        warnings.append("容器重启偏多: " + ", ".join(high_restart))

    result = {
        "operator": {
            "namespace": args.operator_ns,
            "deployments": [
                {"name": d["metadata"]["name"],
                 "ready": f"{d.get('status', {}).get('readyReplicas', 0)}/{d.get('spec', {}).get('replicas', 0)}",
                 "image": (d.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [{}])[0].get("image"))}
                for d in op_deploys
            ],
        },
        "driverNamespace": args.driver_ns,
        "drivers": [d["metadata"]["name"] for d in drivers],
        "cephConnections": [d["metadata"]["name"] for d in conns],
        "clientProfiles": [d["metadata"]["name"] for d in profiles],
        "csidrivers": [d["metadata"]["name"] for d in csidrivers],
        "storageClasses": [
            {"name": s["metadata"]["name"], "reclaimPolicy": s.get("reclaimPolicy"),
             "volumeBindingMode": s.get("volumeBindingMode")} for s in ceph_scs
        ],
        "pods": {"nodeplugin": len(nodeplugin), "ctrlplugin": len(ctrlplugin)},
        "pv": {"total": len(ceph_pvs), "phase": pv_phase},
        "pvc": {"total": len(ceph_pvcs), "phase": pvc_phase},
        "helmReleaseSecrets": len(helm),
        "warnings": warnings,
    }

    if args.format == "json":
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
        print()
        return

    print("# Ceph-CSI RBD 盘点\n")
    print(f"- Operator 命名空间: `{args.operator_ns}`")
    print(f"- Driver 命名空间: `{args.driver_ns}`")
    print(f"- Driver: {', '.join(result['drivers']) or '-'}")
    print(f"- CephConnection: {', '.join(result['cephConnections']) or '-'}")
    print(f"- ClientProfile: {', '.join(result['clientProfiles']) or '-'}")
    print(f"- CSIDriver: {', '.join(result['csidrivers']) or '-'}")
    print(f"- NodePlugin Pod: {len(nodeplugin)}；ControllerPlugin Pod: {len(ctrlplugin)}")
    print(f"- Helm release secret: {len(helm)}")
    print()
    print("## Operator Deployment\n")
    print("| Deployment | Ready | Image |")
    print("|---|---|---|")
    for d in result["operator"]["deployments"]:
        print(f"| {d['name']} | {d['ready']} | `{d['image']}` |")
    print()
    print("## StorageClass\n")
    print("| Name | ReclaimPolicy | BindingMode |")
    print("|---|---|---|")
    for s in result["storageClasses"]:
        print(f"| {s['name']} | {s['reclaimPolicy']} | {s['volumeBindingMode']} |")
    print()
    print("## PV / PVC\n")
    print(f"- PV: {result['pv']['total']} {result['pv']['phase']}")
    print(f"- PVC: {result['pvc']['total']} {result['pvc']['phase']}")
    print()
    print("## 警告\n")
    if warnings:
        for w in warnings:
            print(f"- ⚠️ {w}")
    else:
        print("- 无")


if __name__ == "__main__":
    main()
