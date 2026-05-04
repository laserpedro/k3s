#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/k3s-server-init.log) 2>&1

# ── Jumbo frames ───────────────────────────────────────────────────────────────
# AWS VPC supports 9001-byte MTU. A higher physical MTU lets Cilium use a
# larger pod-network MTU after subtracting encapsulation headers:
#   native routing : no overhead  → pod MTU 9001
#   VXLAN tunnel   : -50 B        → pod MTU 8951
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

# Flannel is replaced entirely by Cilium, so we disable it along with the
# built-in network-policy controller and kube-proxy (Cilium replaces both
# via eBPF, eliminating all iptables overhead for service routing).
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
  --flannel-backend=none \
  --disable-network-policy \
  --disable-kube-proxy \
  --cluster-cidr="${cluster_cidr}" \
  --service-cidr="${service_cidr}" \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  $EXTRA_ARGS

# Wait until the node appears (it will stay NotReady until Cilium provides CNI)
until k3s kubectl get nodes 2>/dev/null | grep -q "$(hostname)"; do
  sleep 5
done

# ── Install Helm ───────────────────────────────────────────────────────────────
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── Install Cilium via Helm ────────────────────────────────────────────────────
helm repo add cilium https://helm.cilium.io/
helm repo update

%{ if cilium_version != "" ~}
CILIUM_VERSION_ARG="--version ${cilium_version}"
%{ else ~}
CILIUM_VERSION_ARG=""
%{ endif ~}

# native routing: Cilium installs a kernel route per peer node (autoDirectNodeRoutes)
# so pod packets are forwarded as plain IP without any encapsulation.
# tunnel mode:   Cilium wraps packets in VXLAN (UDP 8472), works across subnets.
%{ if cilium_routing_mode == "native" ~}
ROUTING_FLAGS="--set routingMode=native --set autoDirectNodeRoutes=true --set ipv4NativeRoutingCIDR=${cluster_cidr}"
%{ else ~}
ROUTING_FLAGS="--set routingMode=tunnel --set tunnelProtocol=vxlan"
%{ endif ~}

# shellcheck disable=SC2086
helm install cilium cilium/cilium \
  $CILIUM_VERSION_ARG \
  --namespace kube-system \
  --set k8sServiceHost="$PRIVATE_IP" \
  --set k8sServicePort=6443 \
  --set kubeProxyReplacement=true \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  $ROUTING_FLAGS \
  --kubeconfig /etc/rancher/k3s/k3s.yaml

# ── Wait for Cilium DaemonSet and node Ready ───────────────────────────────────
until k3s kubectl -n kube-system rollout status daemonset/cilium --timeout=5s 2>/dev/null; do
  sleep 5
done

until k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; do
  sleep 5
done

echo "k3s server with Cilium CNI is ready"
