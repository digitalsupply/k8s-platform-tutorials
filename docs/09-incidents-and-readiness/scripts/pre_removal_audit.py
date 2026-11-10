#!/usr/bin/env python3
"""按关键字盘点待下线组件的 API 表面（只读）。

用法：
    python3 pre_removal_audit.py knative
    python3 pre_removal_audit.py compassio --namespace compassio

输出：命名空间、CRD、CR 实例数、APIService、Webhook、ClusterRole/Binding。
不会删除任何资源。
"""
import argparse
import json
import subprocess
import sys


def kget(args):
    p = subprocess.run(["kubectl"] + args + ["-o", "json"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return {"items": []}
    try:
        return json.loads(p.stdout)
    except json.JSONDecodeError:
        return {"items": []}


def match(name, labels, keyword):
    if keyword.lower() in name.lower():
        return True
    return any(keyword.lower() in f"{k}={v}".lower() for k, v in (labels or {}).items())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("keyword", help="组件关键字，例如 knative / tekton / compassio")
    ap.add_argument("--namespace", help="只检查指定命名空间")
    args = ap.parse_args()
    kw = args.keyword

    print(f"# 下线前审计：{kw}\n")

    print("## 命名空间")
    for ns in kget(["get", "ns"])["items"]:
        name = ns["metadata"]["name"]
        if kw.lower() in name.lower():
            print(f"- {name} ({ns['status']['phase']})")

    print("\n## CRD / CR 实例")
    for crd in kget(["get", "crd"])["items"]:
        meta = crd["metadata"]
        name = meta["name"]
        if not match(name, meta.get("labels"), kw):
            continue
        group = crd["spec"]["group"]
        kind = crd["spec"]["names"]["plural"]
        version = next((v["name"] for v in crd["spec"]["versions"] if v.get("storage")), None)
        if not version:
            continue
        resources = kget(["get", f"{kind}.{group}"])
        count = len(resources.get("items", []))
        print(f"- {name}  CR 实例: {count}")
        if count:
            for item in resources["items"][:10]:
                m = item["metadata"]
                print(f"    - {m.get('namespace', '-')}/{m['name']}")

    print("\n## APIService")
    for svc in kget(["get", "apiservice"])["items"]:
        name = svc["metadata"]["name"]
        if kw.lower() in name.lower():
            backend = svc.get("spec", {}).get("service") or {}
            print(f"- {name}  service={backend.get('namespace', '-')}/{backend.get('name', '-')}")

    print("\n## Webhook")
    for kind in ("validatingwebhookconfiguration", "mutatingwebhookconfiguration"):
        for wh in kget(["get", kind])["items"]:
            name = wh["metadata"]["name"]
            hits = [w["name"] for w in wh.get("webhooks", [])
                    if kw.lower() in w.get("name", "").lower()
                    or any(kw.lower() in r.get("apiGroups", []) or kw.lower() in r.get("resources", [])
                           for r in w.get("rules", []))]
            if kw.lower() in name.lower() or hits:
                print(f"- {kind}/{name}  webhooks={hits}")

    print("\n## RBAC")
    for role in kget(["get", "clusterrole"])["items"]:
        meta = role["metadata"]
        if match(meta["name"], meta.get("labels"), kw):
            print(f"- ClusterRole/{meta['name']}")
    for binding in kget(["get", "clusterrolebinding"])["items"]:
        meta = binding["metadata"]
        subjects = binding.get("subjects", [])
        ns_hit = bool(args.namespace) and any(
            subject.get("namespace") == args.namespace for subject in subjects)
        name_hit = any(kw.lower() in subject.get("name", "").lower() for subject in subjects)
        if match(meta["name"], meta.get("labels"), kw) or ns_hit or name_hit:
            print(f"- ClusterRoleBinding/{meta['name']}")

    print("\n> 删除前请确认：零业务引用、已备份、先卸载 Operator，再删 CR/CRD/Webhook。")
    print("> 名字不含关键字的 RBAC 需要按 label + binding subject 双重确认。")


if __name__ == "__main__":
    main()
