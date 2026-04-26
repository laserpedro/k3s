resource "aws_vpc" "k3s" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = "k3s-vpc" })
}

# Single subnet shared by both nodes — required for host-gw flannel backend
# (hosts must be on the same L2 segment so they can use each other as the
# next-hop gateway for pod CIDR routes).
resource "aws_subnet" "k3s" {
  vpc_id                  = aws_vpc.k3s.id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "k3s-subnet" })
}

resource "aws_internet_gateway" "k3s" {
  vpc_id = aws_vpc.k3s.id

  tags = merge(local.common_tags, { Name = "k3s-igw" })
}

resource "aws_route_table" "k3s" {
  vpc_id = aws_vpc.k3s.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.k3s.id
  }

  tags = merge(local.common_tags, { Name = "k3s-rt" })
}

resource "aws_route_table_association" "k3s" {
  subnet_id      = aws_subnet.k3s.id
  route_table_id = aws_route_table.k3s.id
}
