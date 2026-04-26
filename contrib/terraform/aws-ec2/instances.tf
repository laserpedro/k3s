# ── Cluster placement group ────────────────────────────────────────────────────
# Packs instances onto the same physical hardware rack for the lowest
# possible inter-node latency (~single-digit µs) and maximum network PPS.
# Both instances must be in the same AZ (enforced via var.availability_zone).
resource "aws_placement_group" "k3s" {
  name     = "k3s-cluster-pg"
  strategy = "cluster"

  tags = local.common_tags
}

# ── AMI lookup ─────────────────────────────────────────────────────────────────
data "aws_ami" "ubuntu_22_04" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  resolved_ami = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu_22_04[0].id
}

# ── Control-plane node ─────────────────────────────────────────────────────────
resource "aws_instance" "server" {
  ami               = local.resolved_ami
  instance_type     = var.server_instance_type
  key_name          = var.key_name
  subnet_id         = aws_subnet.k3s.id
  availability_zone = var.availability_zone
  placement_group   = aws_placement_group.k3s.id

  vpc_security_group_ids = [aws_security_group.server.id]

  # Required for host-gw flannel: packets originate from / are destined to
  # pod CIDRs, not the instance's own IP.
  source_dest_check = false

  # IMDSv2 — token-based metadata access; hop-limit 2 allows in-pod IMDS use.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    throughput  = 125
    iops        = 3000
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data/server.sh.tpl", {
    k3s_version      = var.k3s_version
    k3s_token        = local.k3s_token
    flannel_backend  = var.flannel_backend
    cluster_cidr     = var.cluster_cidr
    service_cidr     = var.service_cidr
    extra_args       = var.server_extra_args
  })

  tags = merge(local.common_tags, {
    Name = "k3s-server"
    Role = "control-plane"
  })
}

# ── Agent node ─────────────────────────────────────────────────────────────────
resource "aws_instance" "agent" {
  ami               = local.resolved_ami
  instance_type     = var.agent_instance_type
  key_name          = var.key_name
  subnet_id         = aws_subnet.k3s.id
  availability_zone = var.availability_zone
  placement_group   = aws_placement_group.k3s.id

  vpc_security_group_ids = [aws_security_group.agent.id]

  source_dest_check = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    throughput  = 125
    iops        = 3000
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data/agent.sh.tpl", {
    k3s_version       = var.k3s_version
    k3s_token         = local.k3s_token
    server_private_ip = aws_instance.server.private_ip
    extra_args        = var.agent_extra_args
  })

  # Terraform orders creation: server first. The agent's user_data also polls
  # port 6443 before running the installer for an extra runtime safety net.
  depends_on = [aws_instance.server]

  tags = merge(local.common_tags, {
    Name = "k3s-agent"
    Role = "agent"
  })
}
