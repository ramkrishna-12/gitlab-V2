data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "admin" {
  key_name   = "lab-admin"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# ---- Non-secret settings handed to the gateway scripts ----------------------
locals {
  gw_env = <<-EOT
    VPC_CIDR="${var.vpc_cidr}"
    PRIVATE_CIDR="${var.private_subnet_cidr}"
    VPN_CIDR="${var.vpn_cidr}"
    VPN_GW_WG_IP="${var.vpn_gw_wg_ip}"
    WG_PORT="${var.wg_port}"
    GITLAB_IP="${var.gitlab_private_ip}"
    BOOTSTRAP_SSH_CIDR="${var.bootstrap_ssh_cidr}"
  EOT

  # Scripts are gzip+base64 encoded into cloud-init so the cloud-config stays well under the 16 KB user_data limit.
  vpn_gw_user_data = templatefile("${path.module}/templates/vpn-gw.cloud-init.yaml.tftpl", {
    gw_env         = base64gzip(local.gw_env)
    gw_lib         = base64gzip(file("${path.module}/../vpn/gw-lib.sh"))
    gw_firewall    = base64gzip(file("${path.module}/../vpn/gw-firewall.sh"))
    gw_bootstrap   = base64gzip(file("${path.module}/../vpn/gw-bootstrap.sh"))
    gw_add_peer    = base64gzip(file("${path.module}/../vpn/add-peer.sh"))
    gw_revoke_peer = base64gzip(file("${path.module}/../vpn/revoke-peer.sh"))
  })
}

# ---- vpn-gw: WireGuard server + bastion + NAT -------------------------------
resource "aws_instance" "vpn_gw" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.vpn_gw_instance_type
  subnet_id                   = aws_subnet.public.id
  private_ip                  = var.vpn_gw_private_ip
  vpc_security_group_ids      = [aws_security_group.vpn_gw.id]
  key_name                    = aws_key_pair.admin.key_name
  associate_public_ip_address = true # temporary address so cloud-init can reach apt; the EIP below replaces it

  # REQUIRED for a router/NAT box: AWS normally drops packets whose source or
  # destination is not the instance itself. vpn-gw forwards other hosts' packets.
  source_dest_check = false

  user_data = local.vpn_gw_user_data

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "vpn-gw" }

  lifecycle {
    # Do not rebuild (and regenerate the WireGuard server key) just because a newer
    # AMI or an edited script appeared. Rebuild deliberately:
    #   terraform apply -replace=aws_instance.vpn_gw
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_eip" "vpn_gw" {
  domain     = "vpc"
  instance   = aws_instance.vpn_gw.id
  tags       = { Name = "vpn-gw-eip" }
  depends_on = [aws_internet_gateway.igw]
}

# ---- gitlab: private subnet, no public IP -----------------------------------
resource "aws_instance" "gitlab" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.gitlab_instance_type
  subnet_id                   = aws_subnet.private.id
  private_ip                  = var.gitlab_private_ip
  vpc_security_group_ids      = [aws_security_group.gitlab.id]
  key_name                    = aws_key_pair.admin.key_name
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.gitlab.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1 # containers (runner jobs) cannot reach the instance role credentials
  }

  root_block_device {
    volume_size = var.gitlab_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "gitlab" }

  lifecycle {
    ignore_changes = [ami]
  }

  # It needs the NAT route to install packages on first boot.
  depends_on = [aws_route.private_default_via_gw, aws_route.private_vpn_via_gw]
}

# ---- Part 6: fresh instance for the restore test (count = 0 unless requested) -------
# Same subnet, security group and S3-only role as gitlab. Not reachable from the VPN firewall rules
# (WG_PEERS only allows 10.20.2.10); the admin reaches it with ProxyJump via vpn-gw.
resource "aws_instance" "gitlab_restore" {
  count                       = var.create_restore_vm ? 1 : 0
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.gitlab_instance_type
  subnet_id                   = aws_subnet.private.id
  private_ip                  = var.restore_private_ip
  vpc_security_group_ids      = [aws_security_group.gitlab.id]
  key_name                    = aws_key_pair.admin.key_name
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.gitlab.name

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.gitlab_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "gitlab-restore-test" }

  lifecycle {
    ignore_changes = [ami]
  }

  depends_on = [aws_route.private_default_via_gw, aws_route.private_vpn_via_gw]
}
