#!/usr/bin/env python3
"""Traefik GitOps 收尾状态检查（只读）。

检查:
  - ArgoCD Application platform-traefik / platform-gateway-api 的 Sync/Health
  - traefik namespace 是否残留 Helm release secret
  - Deployment 副本数、更新策略、镜像
  - Service EXTERNAL-IP
  - Gateway API CRD 数量
  - IngressRoute 数量
  - Traefik 关键启动参数

用法: python3 traefik_gitops_audit.py [--format md|json]
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


def app_summary(name):
    obj = kube(["-n", "argocd", "get", "application", name, "-o", "json"])
    if not obj:
        return None
    src = (obj.get("spec", {}).get("source") or
           (obj.get("spec", {}).get("sources") or [{}])[0])
    auto = (obj.get("spec", {}).get("syncPolicy", {}) or {}).get("automated", {}) or {}
    return {
        "name": name,
        "sync": obj.get("status", {}).get("sync", {}).get("status"),
        "health": obj.get("status", {}).get("health", {}).get("status"),
        "repoURL": src.get("repoURL"),
        "path": src.get("path"),
        "targetRevision": src.get("targetRevision"),
        "prune": auto.get("prune"),
        "selfHeal": auto.get("selfHeal"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["md", "json"], default="md")
    args = ap.parse_args()

    deploy = kube(["-n", "traefik", "get", "deploy", "traefik", "-o", "json"])
    svc = kube(["-n", "traefik", "get", "svc", "traefik", "-o", "json"])
    helm = items(kube(["-n", "traefik", "get", "secret", "-l", "owner=helm", "name=traefik", "-o", "json"]))
    crds = items(kube(["get", "crd", "-o", "json"]))
    routes = items(kube(["get", "ingressroutes.traefik.io", "-A", "-o", "json"]))
    apps = [a for a in (app_summary("platform-traefik"), app_summary("platform-gateway-api")) if a]

    gw_crds = [c for c in crds if c.get("metadata", {}).get("name", "").endswith(".gateway.networking.k8s.io")]
    spec = (deploy or {}).get("spec", {})
    strategy = spec.get("strategy", {})
    containers = spec.get("template", {}).get("spec", {}).get("containers", [{}])
    image = containers[0].get("image") if containers else None
    traefik_args = containers[0].get("args", []) if containers else []

    warnings = []
    if helm:
        warnings.append(f"存在 {len(helm)} 个 Helm release secret（应只剩 ArgoCD 管理）")
    if (deploy or {}).get("status", {}).get("readyReplicas", 0) != spec.get("replicas", 1):
        warnings.append("Traefik 副本未全部 Ready")

    ru = strategy.get("rollingUpdate", {}) or {}
    if strategy.get("type") == "RollingUpdate" and (ru.get("maxSurge") not in (0, "0")):
        warnings.append(f"maxSurge={ru.get('maxSurge')}，内存紧张时可能瞬时起两个 Pod")
    for a in apps:
        if a["sync"] != "Synced" or a["health"] != "Healthy":
            warnings.append(f"ArgoCD {a['name']}: {a['sync']}/{a['health']}")

    result = {
        "deployment": {
            "replicas": spec.get("replicas"),
            "ready": (deploy or {}).get("status", {}).get("readyReplicas"),
            "strategy": strategy,
            "image": image,
            "args": traefik_args,
        },
        "service": {
            "type": (svc or {}).get("spec", {}).get("type"),
            "externalIP": (svc or {}).get("status", {}).get("loadBalancer", {}).get("ingress"),
        },
        "helmReleaseSecrets": len(helm),
        "gatewayAPICRDs": len(gw_crds),
        "ingressRoutes": len(routes),
        "argocd": apps,
        "warnings": warnings,
    }

    if args.format == "json":
        json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
        print()
        return

    d = result["deployment"]
    print("# Traefik GitOps 状态\n")
    print(f"- Deployment: {d['ready']}/{d['replicas']} Ready")
    print(f"- Image: `{d['image']}`")
    print(f"- Strategy: `{json.dumps(d['strategy'], ensure_ascii=False)}`")
    print(f"- Service: {result['service']['type']} {result['service']['externalIP']}")
    print(f"- Helm release secret: {result['helmReleaseSecrets']}")
    print(f"- Gateway API CRD: {result['gatewayAPICRDs']}")
    print(f"- IngressRoute: {result['ingressRoutes']}")
    print()
    print("## ArgoCD\n")
    print("| Application | Sync | Health | Path | Prune | SelfHeal |")
    print("|---|---|---|---|---|---|")
    for a in apps:
        print(f"| {a['name']} | {a['sync']} | {a['health']} | `{a['path']}` | {a['prune']} | {a['selfHeal']} |")
    print()
    print("## 关键启动参数\n")
    for arg in d["args"]:
        if any(x in arg for x in ("api", "providers", "entrypoints", "log")):
            print(f"- `{arg}`")
    print()
    print("## 警告\n")
    if warnings:
        for w in warnings:
            print(f"- ⚠️ {w}")
    else:
        print("- 无")


if __name__ == "__main__":
    main()
