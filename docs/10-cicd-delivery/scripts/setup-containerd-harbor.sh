#!/bin/bash
# Configure containerd on a node to pull from Harbor (self-signed TLS) at 192.168.67.202:8443
# Idempotent; safe to run on every node.
set -euo pipefail

HARBOR_HOST="192.168.67.202:8443"
CERTS_DIR="/etc/containerd/certs.d"

mkdir -p "${CERTS_DIR}/${HARBOR_HOST}"

# hosts.toml: trust self-signed Harbor by skipping verification
cat > "${CERTS_DIR}/${HARBOR_HOST}/hosts.toml" <<EOF
server = "https://${HARBOR_HOST}"

[host."https://${HARBOR_HOST}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

echo "[$(hostname)] wrote ${CERTS_DIR}/${HARBOR_HOST}/hosts.toml"

# Restart containerd only if needed to pick up certs.d changes
systemctl restart containerd
sleep 5
# bring the runtime back online for this node
systemctl is-active --quiet containerd && echo "[$(hostname)] containerd active" || echo "[$(hostname)] containerd NOT active"
