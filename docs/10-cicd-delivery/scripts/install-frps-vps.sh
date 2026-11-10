#!/bin/bash
# Deploy frps (frp server) on the public VPS.
set -euo pipefail

FRP_VERSION="0.61.2"
ARCH="amd64"
BIND_PORT="${FRP_BIND_PORT:-7000}"
VHOST_HTTP_PORT="${FRP_VHOST_HTTP_PORT:-8089}"
VHOST_HTTPS_PORT="${FRP_VHOST_HTTPS_PORT:-8449}"
TOKEN="${FRP_TOKEN:-}"

echo "==> Installing frp v${FRP_VERSION}"
cd /tmp
curl -fsSL -o frp.tar.gz "https://ghfast.top/https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_linux_${ARCH}.tar.gz"
tar xzf frp.tar.gz
sudo install -m 0755 "frp_${FRP_VERSION}_linux_${ARCH}/frps" /usr/local/bin/frps
sudo install -m 0755 "frp_${FRP_VERSION}_linux_${ARCH}/frpc" /usr/local/bin/frpc
frps --version

echo "==> Writing /etc/frp/frps.toml"
sudo mkdir -p /etc/frp
sudo tee /etc/frp/frps.toml >/dev/null <<EOF
bindAddr = "0.0.0.0"
bindPort = ${BIND_PORT}

# HTTP proxy traffic (plain http, since port 80 is blocked for un-备案 domains
# on Tencent Cloud mainland nodes).
vhostHTTPPort = ${VHOST_HTTP_PORT}
# HTTPS support for later; requires certificates in /etc/frp/certs.
vhostHTTPSPort = ${VHOST_HTTPS_PORT}

# Only the tunnel control port is expected to face the internet directly;
# proxy traffic arrives on vhostHTTPPort.
auth.method = "token"
auth.token = "${TOKEN}"

transport.tcpMux = true
transport.tcpMuxKeepaliveInterval = 30

log.to = "console"
log.level = "info"

# Private pools: only this VPS may publish proxies.
allowPorts = [{ single = ${VHOST_HTTP_PORT} }, { single = ${VHOST_HTTPS_PORT} }]
EOF

echo "==> systemd unit"
sudo tee /etc/systemd/system/frps.service >/dev/null <<'EOF'
[Unit]
Description=frp server (reverse tunnel endpoint)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable frps >/dev/null 2>&1 || true
sudo systemctl restart frps
sleep 4
echo "==> Status"
sudo systemctl is-active frps
sudo ss -ltn 2>/dev/null | grep -E ":${BIND_PORT}|:${VHOST_HTTP_PORT}" || true