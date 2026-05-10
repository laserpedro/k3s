# ── Server security group ──────────────────────────────────────────────────────
resource "aws_security_group" "server" {
  name        = "k3s-server"
  description = "k3s control-plane: API server, Cilium, kubelet"
  vpc_id      = aws_vpc.k3s.id

  # SSH (management)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Kubernetes API — accessed by agents and external kubectl clients
  ingress {
    description     = "Kubernetes API (agent)"
    from_port       = 6443
    to_port         = 6443
    protocol        = "tcp"
    security_groups = [aws_security_group.agent.id]
  }

  ingress {
    description = "Kubernetes API (admin)"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Cilium VXLAN tunnel — used when cilium_routing_mode = "tunnel"
  ingress {
    description     = "Cilium VXLAN tunnel"
    from_port       = 8472
    to_port         = 8472
    protocol        = "udp"
    security_groups = [aws_security_group.agent.id]
  }

  # Cilium health check probes (agent-to-agent on TCP 4240)
  ingress {
    description     = "Cilium health check"
    from_port       = 4240
    to_port         = 4240
    protocol        = "tcp"
    security_groups = [aws_security_group.agent.id]
  }

  # kubelet API — used by the API server to stream logs/exec
  ingress {
    description     = "kubelet API"
    from_port       = 10250
    to_port         = 10250
    protocol        = "tcp"
    security_groups = [aws_security_group.agent.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "k3s-server" })
}

# ── Agent security group ───────────────────────────────────────────────────────
resource "aws_security_group" "agent" {
  name        = "k3s-agent"
  description = "k3s agent: kubelet, Cilium"
  vpc_id      = aws_vpc.k3s.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "k3s-agent" })
}

# Rules that reference both SGs are declared outside their definitions to
# avoid a circular dependency between aws_security_group resources.

resource "aws_security_group_rule" "agent_kubelet_from_server" {
  description              = "kubelet API from server"
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.server.id
  security_group_id        = aws_security_group.agent.id
}

resource "aws_security_group_rule" "agent_vxlan_from_server" {
  description              = "Cilium VXLAN tunnel from server"
  type                     = "ingress"
  from_port                = 8472
  to_port                  = 8472
  protocol                 = "udp"
  source_security_group_id = aws_security_group.server.id
  security_group_id        = aws_security_group.agent.id
}

resource "aws_security_group_rule" "agent_cilium_health_from_server" {
  description              = "Cilium health check from server"
  type                     = "ingress"
  from_port                = 4240
  to_port                  = 4240
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.server.id
  security_group_id        = aws_security_group.agent.id
}
