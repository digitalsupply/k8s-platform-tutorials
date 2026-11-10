#!/usr/bin/env python3
import json, subprocess, hashlib, sys, os, time

NODES = {
    "worker01": "10.0.0.122",
    "worker02": "10.0.0.123",
    "worker03": "10.0.0.124",
    "master02": "10.0.0.120",
    "master01": "10.0.0.121",
    "m01": "10.0.0.61",
}
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=5"]

def ssh(node, cmd, timeout=600):
    return subprocess.run(["ssh"] + SSH_OPTS + ["root@" + NODES[node], cmd],
                          capture_output=True, text=True, timeout=timeout)

def kube(args, timeout=60):
    return subprocess.run(["kubectl"] + args, capture_output=True, text=True, timeout=timeout)

def image_tags(node):
    r = ssh(node, "crictl images -o json", 60)
    if r.returncode != 0:
        return set()
    try:
        d = json.loads(r.stdout)
    except Exception:
        return set()
    s = set()
    for i in d.get("images", []):
        for t in (i.get("repoTags") or []):
            s.add(t)
        for t in (i.get("repoDigests") or []):
            s.add(t)
    return s

def present(ref, tags):
    if ref in tags:
        return True
    # digest form: repo:tag@sha256:xxx -> match repo@sha256:xxx or bare digest
    if "@" in ref:
        repo, dig = ref.split("@", 1)
        if dig in tags or (repo + "@" + dig) in tags:
            return True
        base = dig.split(":")[-1][:12]
        return any(base in t for t in tags)
    return False

def copy_image(src, dst, ref):
    h = hashlib.md5(ref.encode()).hexdigest()[:10]
    tar = f"/tmp/imgcopy-{h}.tar"
    exp = ssh(src, f"rm -f {tar}; ctr -n k8s.io images export --platform linux/amd64 {tar} '{ref}'", 600)
    if exp.returncode != 0:
        # retry by image id from crictl
        ins = ssh(src, f"crictl inspecti '{ref}' 2>/dev/null")
        iid = ""
        try:
            iid = json.loads(ins.stdout)["status"]["id"]
        except Exception:
            pass
        if iid:
            exp = ssh(src, f"rm -f {tar}; ctr -n k8s.io images export --platform linux/amd64 {tar} {iid}", 600)
    if exp.returncode != 0:
        return False, "export-failed: " + (exp.stderr.strip().splitlines()[-1] if exp.stderr.strip() else "")[:160]
    sz = ssh(src, f"stat -c %s {tar}", 30).stdout.strip()
    cp = subprocess.run(["scp"] + SSH_OPTS + [f"root@{NODES[src]}:{tar}", f"root@{NODES[dst]}:{tar}"],
                        capture_output=True, text=True, timeout=900)
    if cp.returncode != 0:
        ssh(src, f"rm -f {tar}", 30)
        return False, "scp-failed"
    imp = ssh(dst, f"ctr -n k8s.io images import {tar} >/dev/null 2>&1; rc=$?; rm -f {tar}; exit $rc", 600)
    ssh(src, f"rm -f {tar}", 30)
    if imp.returncode != 0:
        return False, "import-failed"
    return True, f"{sz} bytes"

def main():
    print("== collecting images ==", flush=True)
    tags = {n: image_tags(n) for n in NODES}
    pods = json.loads(kube(["get", "pods", "-A", "-o", "json"]).stdout)["items"]
    need = {}  # ref -> set(nodes)
    for p in pods:
        if p.get("status", {}).get("phase") == "Running":
            continue
        node = p["spec"].get("nodeName")
        if node not in NODES:
            continue
        refs = [c["image"] for c in p["spec"].get("initContainers", [])] + \
               [c["image"] for c in p["spec"].get("containers", [])]
        for r in refs:
            need.setdefault(r, set()).add(node)

    ok = fail = 0
    for ref, targets in sorted(need.items()):
        for dst in sorted(targets):
            if present(ref, tags[dst]):
                print(f"OK      {dst:9s} {ref[:110]}", flush=True)
                continue
            srcs = [n for n in NODES if n != dst and present(ref, tags[n])]
            if not srcs:
                # try direct pull on target
                pr = ssh(dst, f"crictl pull '{ref}'", 180)
                if pr.returncode == 0:
                    print(f"PULLED  {dst:9s} {ref[:110]}", flush=True)
                    ok += 1
                else:
                    print(f"NOPULL  {dst:9s} {ref[:110]} :: {pr.stderr.strip().splitlines()[-1][:120] if pr.stderr.strip() else ''}", flush=True)
                    fail += 1
                continue
            src = srcs[0]
            good, msg = copy_image(src, dst, ref)
            if good:
                print(f"COPIED  {src:9s}->{dst:9s} {ref[:100]} ({msg})", flush=True)
                tags[dst].add(ref)
                ok += 1
            else:
                print(f"FAILED  {src:9s}->{dst:9s} {ref[:100]} :: {msg}", flush=True)
                fail += 1
    print(f"== done ok={ok} fail={fail} ==", flush=True)

if __name__ == "__main__":
    main()
