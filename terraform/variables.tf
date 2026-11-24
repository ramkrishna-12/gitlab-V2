variable "region" {
  description = "AWS region. Mumbai is the closest to Kolkata."
  type        = string
  default     = "ap-south-1"
}

# ---- Addressing plan -------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "Holds vpn-gw only."
  type        = string
  default     = "10.20.1.0/24"
}

variable "private_subnet_cidr" {
  description = "Holds gitlab only. No public IP, no route to the internet gateway."
  type        = string
  default     = "10.20.2.0/24"
}

variable "vpn_cidr" {
  description = "WireGuard overlay network. Must NOT overlap the VPC CIDR."
  type        = string
  default     = "10.99.0.0/24"
}

variable "vpn_gw_wg_ip" {
  description = "vpn-gw's own address inside the VPN network."
  type        = string
  default     = "10.99.0.1"
}

variable "vpn_gw_private_ip" {
  type    = string
  default = "10.20.1.10"
}

variable "gitlab_private_ip" {
  type    = string
  default = "10.20.2.10"
}

variable "wg_port" {
  description = "The only port exposed to the internet (UDP)."
  type        = number
  default     = 51820
}

# ---- Sizing ----------------------------------------------------------------
variable "vpn_gw_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "gitlab_instance_type" {
  description = "GitLab needs >= 4 GB RAM. t3.medium = 4 GB."
  type        = string
  default     = "t3.medium"
}

variable "gitlab_volume_gb" {
  type    = number
  default = 30
}

# ---- Access ----------------------------------------------------------------
variable "ssh_public_key_path" {
  description = "Public half of YOUR admin SSH key. The private key never goes near Terraform."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "bootstrap_ssh_cidr" {
  description = <<-EOT
    Your public IP as x.x.x.x/32. Opens TCP 22 on vpn-gw ONLY for the first setup,
    so you can create the admin VPN peer. Set it back to "" and re-apply once the
    VPN works: after that, nothing but UDP/WireGuard is exposed to the internet.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.bootstrap_ssh_cidr == "" || can(cidrhost(var.bootstrap_ssh_cidr, 0))
    error_message = "bootstrap_ssh_cidr must be empty or a valid CIDR such as 203.0.113.7/32."
  }
}

# ---- Part 6: disposable restore target ----------------------------------------
variable "create_restore_vm" {
  description = "Create a throw-away second GitLab host to test restores. Set true only for the test, then false + apply to destroy it."
  type        = bool
  default     = false
}

variable "restore_private_ip" {
  type    = string
  default = "10.20.2.11"
}
