variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "Availability zone. Both instances must share the same AZ for the cluster placement group."
  type        = string
  default     = "us-east-1a"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the subnet (both nodes share it to allow host-gw routing)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "admin_cidr" {
  description = "CIDR allowed SSH and Kubernetes API access"
  type        = string
  default     = "0.0.0.0/0"
}

# ── Instance types ─────────────────────────────────────────────────────────────
# For best network throughput use network-optimised families: c5n, m5n, r5n.
# t3/t3a work fine for dev/test and support cluster placement groups.
variable "server_instance_type" {
  description = "EC2 instance type for the k3s control-plane node"
  type        = string
  default     = "t3.medium"
}

variable "agent_instance_type" {
  description = "EC2 instance type for the k3s agent node"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB (gp3)"
  type        = number
  default     = 20
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID. Leave empty to auto-discover the latest Canonical image."
  type        = string
  default     = ""
}

# ── k3s configuration ──────────────────────────────────────────────────────────
variable "k3s_version" {
  description = "k3s version to install (e.g. v1.30.2+k3s1). Leave empty for the latest stable release."
  type        = string
  default     = ""
}

variable "k3s_token" {
  description = "Shared cluster token. Leave empty to auto-generate a random token."
  type        = string
  default     = ""
  sensitive   = true
}

# flannel_backend controls pod-network performance:
#   host-gw        – no encapsulation, lowest latency; requires nodes on the same L2 subnet
#   vxlan          – UDP encapsulation, works across subnets; default k3s upstream choice
#   wireguard-native – encrypted; also open UDP 51820 in security groups when using this
variable "flannel_backend" {
  description = "Flannel backend. 'host-gw' gives the best performance when both nodes are in the same subnet."
  type        = string
  default     = "host-gw"

  validation {
    condition     = contains(["host-gw", "vxlan", "wireguard-native", "none"], var.flannel_backend)
    error_message = "flannel_backend must be one of: host-gw, vxlan, wireguard-native, none."
  }
}

variable "cluster_cidr" {
  description = "CIDR for pod networking"
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes services"
  type        = string
  default     = "10.43.0.0/16"
}

variable "server_extra_args" {
  description = "Additional flags passed verbatim to the k3s server process"
  type        = string
  default     = ""
}

variable "agent_extra_args" {
  description = "Additional flags passed verbatim to the k3s agent process"
  type        = string
  default     = ""
}
