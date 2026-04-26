#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/k3s-server-init.log) 2>&1

# ── Jumbo frames ───────────────────────────────────────────────────────────────
# AWS VPC supports 9001-byte MTU (jumbo frames) on all instance types.
# Raising the physical MTU reduces per-packet overhead for bulk transfers and
# lets Flannel use a larger pod-network MTU after subtracting encapsulation
# headers (VXLAN: -50 B → 8951; host-gw: no overhead → 9001).
ip link set eth0 mtu 9001

# Persist MTU so it survives reboots and netplan reconciliation.
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

# ── Resolve instance IPs via IMDSv2 ───────────────────────────────────────────
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")

PRIVATE_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4 || echo "")

# ── Install k3s server ─────────────────────────────────────────────────────────
%{ if k3s_version != "" ~}
export INSTALL_K3S_VERSION="${k3s_version}"
%{ endif ~}

# Key flags:
#   --flannel-backend   : ${flannel_backend}
#                         host-gw  = zero encapsulation, lowest latency (same subnet)
#                         vxlan    = UDP tunnel, works across subnets
#   --flannel-iface     : bind Flannel to the primary private interface
#   --node-ip           : advertise the private IP as the node address
#   --advertise-address : private IP for the API server listener
#   --tls-san           : add public IP so external kubeconfigs are valid
#   --disable=traefik   : ship without the built-in ingress (add your own)
TLS_SAN_FLAGS="--tls-san=$PRIVATE_IP"
if [ -n "$PUBLIC_IP" ]; then
  TLS_SAN_FLAGS="$TLS_SAN_FLAGS --tls-san=$PUBLIC_IP"
fi

EXTRA_ARGS="${extra_args}"

# shellcheck disable=SC2086
curl -sfL https://get.k3s.io | sh -s - server \
  --token="${k3s_token}" \
  --node-ip="$PRIVATE_IP" \
  --advertise-address="$PRIVATE_IP" \
  $TLS_SAN_FLAGS \
  --flannel-backend="${flannel_backend}" \
  --flannel-iface=eth0 \
  --cluster-cidr="${cluster_cidr}" \
  --service-cidr="${service_cidr}" \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  $EXTRA_ARGS

# ── Wait for the node to reach Ready ──────────────────────────────────────────
until k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  sleep 5
done

echo "k3s server is ready"
