# Security groups are the OUTER firewall (AWS). The iptables rules on vpn-gw and
# the host firewall on gitlab are the INNER layer. Both must agree.

resource "aws_security_group" "vpn_gw" {
  name        = "lab-vpn-gw"
  description = "vpn-gw: WireGuard from the internet, NAT for the private subnet"
  vpc_id      = aws_vpc.main.id

  # The ONE thing exposed to the internet.
  ingress {
    description = "WireGuard"
    from_port   = var.wg_port
    to_port     = var.wg_port
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Lets gitlab's outbound package/image downloads be NATed through vpn-gw.
  ingress {
    description = "NAT: HTTP from private subnet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    description = "NAT: HTTPS from private subnet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # Temporary, only while bootstrap_ssh_cidr is set.
  dynamic "ingress" {
    for_each = var.bootstrap_ssh_cidr == "" ? [] : [var.bootstrap_ssh_cidr]
    content {
      description = "TEMPORARY bootstrap SSH from admin IP"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab-vpn-gw" }
}

resource "aws_security_group" "gitlab" {
  name        = "lab-gitlab"
  description = "gitlab: reachable only from the VPN subnet and from vpn-gw (jump host)"
  vpc_id      = aws_vpc.main.id

  # Forwarded VPN client traffic keeps its 10.99.0.x source address (no NAT),
  # so the VPN CIDR is the right source to match.
  ingress {
    description = "HTTPS from VPN clients"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpn_cidr]
  }

  ingress {
    description = "Git/SSH from VPN clients"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpn_cidr]
  }

  # ProxyJump: the admin's SSH is opened by vpn-gw itself, so the source is vpn-gw.
  ingress {
    description     = "SSH from vpn-gw (ProxyJump / tunnels)"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.vpn_gw.id]
  }

  # Only web traffic out: apt, Docker Hub, GitLab package repo, S3 (via endpoint).
  egress {
    description = "HTTP out"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS out"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "lab-gitlab" }
}
