data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az = data.aws_availability_zones.available.names[0]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "lab-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lab-igw" }
}

# ---- Subnets ---------------------------------------------------------------
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = false
  tags                    = { Name = "lab-public" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = local.az
  map_public_ip_on_launch = false
  tags                    = { Name = "lab-private" }
}

# ---- Public route table: default route -> internet gateway ------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lab-public-rt" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---- Private route table: NO internet gateway ------------------------------
# Everything leaves/enters through vpn-gw's network interface instead.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "lab-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# Outbound (apt, docker pulls): gitlab -> vpn-gw, which NATs it. Replaces a ~$32/month NAT Gateway.
resource "aws_route" "private_default_via_gw" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.vpn_gw.primary_network_interface_id
}

# Return path for VPN clients. Without this route gitlab would answer 10.99.0.x
# with no idea where to send it, and every connection would hang after the SYN.
resource "aws_route" "private_vpn_via_gw" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.vpn_cidr
  network_interface_id   = aws_instance.vpn_gw.primary_network_interface_id
}

# S3 over the AWS backbone, free, and it bypasses vpn-gw. Used for GitLab backups.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "lab-s3-endpoint" }
}
