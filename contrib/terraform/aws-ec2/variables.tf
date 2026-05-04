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
  description = "CIDR block for the subnet (both nodes share it to allow Cilium native routing)"
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

# ── Cilium CNI configuration ───────────────────────────────────────────────────
variable "cilium_version" {
  description = "Cilium Helm chart version (e.g. 1.17.0). Leave empty for the latest chart version."
  type        = string
  default     = ""
}

# cilium_routing_mode controls how pod packets travel between nodes:
#   native  – zero encapsulation; Cilium installs a kernel route per peer node so
#             packets are forwarded directly. Requires nodes on the same L2 subnet
#             and source_dest_check = false on the instances.
#   tunnel  – VXLAN encapsulation (UDP 8472); works across different subnets.
variable "cilium_routing_mode" {
  description = "Cilium routing mode. 'native' has zero overhead when nodes share a subnet."
  type        = string
  default     = "native"

  validation {
    condition     = contains(["native", "tunnel"], var.cilium_routing_mode)
    error_message = "cilium_routing_mode must be 'native' or 'tunnel'."
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
