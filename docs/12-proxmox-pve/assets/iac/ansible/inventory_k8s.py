#!/usr/bin/env python3
"""从 kubectl 动态生成 Ansible inventory（K8s 节点）。

用法:
    python3 inventory_k8s.py --list
    ansible-inventory -i inventory_k8s.py --graph

可选环境变量:
    KUBECONFIG=/path/to/config
    ANSIBLE_K8S_USER=root
    ANSIBLE_K8S_KEY=~/.ssh/id_rsa
    ANSIBLE_PYTHON=/usr/bin/python3

只读：只执行 `kubectl get nodes -o json`，不修改集群。
"""

import json
import os
import subprocess
import sys

USER = os.environ.get("ANSIBLE_K8S_USER", "root")
KEY = os.environ.get("ANSIBLE_K8S_KEY", "~/.ssh/id_rsa")
PYTHON = os.environ.get("ANSIBLE_PYTHON", "/usr/bin/python3")


def kubectl_nodes():
    r = subprocess.run(
        ["kubectl", "get", "nodes", "-o", "json"],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        sys.exit(r.returncode)
    return json.loads(r.stdout)["items"]


def main():
    nodes = kubectl_nodes()

    cp, worker = {}, {}
    for n in nodes:
        name = n["metadata"]["name"]
        labels = n["metadata"].get("labels", {})
        addrs = n.get("status", {}).get("addresses", [])
        ip = next((a["address"] for a in addrs if a["type"] == "InternalIP"), "")
        host = {
            "ansible_host": ip,
            "ansible_user": USER,
            "ansible_ssh_private_key_file": KEY,
            "ansible_python_interpreter": PYTHON,
            "node_role": "control-plane"
            if "node-role.kubernetes.io/control-plane" in labels
            else "worker",
            "zone": labels.get("topology.kubernetes.io/zone")
            or labels.get("zone", ""),
        }
        if host["node_role"] == "control-plane":
            cp[name] = host
        else:
            worker[name] = host

    inv = {
        "_meta": {"hostvars": {**cp, **worker}},
        "k8s_all": {"children": ["k8s_cp", "k8s_worker"]},
        "k8s_cp": {"hosts": cp},
        "k8s_worker": {"hosts": worker},
    }
    json.dump(inv, sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
