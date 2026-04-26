#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/k3s-agent-init.log) 2>&1

# ── Jumbo frames ───────────────────────────────────────────────────────────────
# Match the server MTU so the full 9001-byte path is end-to-end; mismatched
# MTUs would cause silent fragmentation on Flannel traffic.
ip link set eth0 mtu 9001

cat > /etc/netplan/99-k3s-mtu.yaml << 'NETPLAN'
network:
  version: 2
  ethernets:
    eth0:
      mtu: 9001
NETPLAN
netplan apply 2>/dev/null || true

# ── Dependencies ───────────────────────────────────────────────────────────────
apt-get update -y
apt-get install -y curl netcat-openbsd

# ── Wait for k3s API server ────────────────────────────────────────────────────
# Terraform already orders creation (server before agent), but the OS-level
# userdata runs asynchronously; poll until the API port is reachable.
echo "Waiting for k3s server at ${server_private_ip}:6443 ..."
until nc -z "${server_private_ip}" 6443; do
  sleep 5
done
echo "k3s server is reachable"

# ── Resolve agent private IP via IMDSv2 ───────────────────────────────────────
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")

PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

# ── Install k3s agent ──────────────────────────────────────────────────────────
%{ if k3s_version != "" ~}
export INSTALL_K3S_VERSION="${k3s_version}"
%{ endif ~}

EXTRA_ARGS="${extra_args}"

# shellcheck disable=SC2086
curl -sfL https://get.k3s.io | \
  K3S_URL="https://${server_private_ip}:6443" \
  K3S_TOKEN="${k3s_token}" \
  sh -s - agent \
    --node-ip="$PRIVATE_IP" \
    --flannel-iface=eth0 \
    $EXTRA_ARGS

echo "k3s agent joined the cluster"
