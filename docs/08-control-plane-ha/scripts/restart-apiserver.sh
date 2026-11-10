#!/bin/bash
# Restart the kube-apiserver static pod container on a control-plane node.
# Usage: restart-apiserver.sh <node> <node-ip>
set -euo pipefail
NODE=$1
IP=$2
POD="apiserver-restart-${NODE}"
MAN="/tmp/opencode/${POD}.yaml"
cat > "$MAN" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: default
spec:
  restartPolicy: Never
  nodeName: ${NODE}
  hostPID: true
  tolerations:
  - operator: Exists
  containers:
  - name: c
    image: 192.168.67.202:8443/deeptutor/busybox:1.36
    imagePullPolicy: IfNotPresent
    securityContext:
      privileged: true
    command: ["nsenter","-t","1","-m","-u","-i","-n","-p","--","sh","-c"]
    args:
      - |
        set -eu
        CID=\$(crictl ps --name kube-apiserver -q | head -1)
        echo "stopping kube-apiserver container \$CID"
        crictl stop "\$CID" || true
        sleep 15
        crictl ps --name kube-apiserver
EOF
kubectl -n default delete pod "$POD" --ignore-not-found >/dev/null 2>&1
kubectl apply -f "$MAN" >/dev/null
for i in $(seq 1 40); do
  p=$(kubectl -n default get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$p" = "Succeeded" ] || [ "$p" = "Failed" ] && break
  sleep 3
done
kubectl -n default logs "$POD" 2>&1 | tail -10 || true
kubectl -n default delete pod "$POD" --ignore-not-found >/dev/null 2>&1
echo "--- waiting for apiserver $IP ---"
for i in $(seq 1 30); do
  if kubectl --kubeconfig /etc/kubernetes/admin.conf --server="https://${IP}:6443" get --raw /healthz >/dev/null 2>&1; then
    echo "apiserver ${IP} healthy after ${i}0s"; break
  fi
  sleep 5
done
kubectl get nodes 2>&1 | tail -6
