output "vpn_gw_public_ip" {
  description = "The WireGuard endpoint clients connect to."
  value       = aws_eip.vpn_gw.public_ip
}

output "vpn_gw_private_ip" {
  value = aws_instance.vpn_gw.private_ip
}

output "gitlab_private_ip" {
  value = aws_instance.gitlab.private_ip
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}

output "bootstrap_ssh" {
  description = "Only works while bootstrap_ssh_cidr is set to your IP."
  value       = "ssh ubuntu@${aws_eip.vpn_gw.public_ip}"
}

output "restore_vm_private_ip" {
  value = var.create_restore_vm ? aws_instance.gitlab_restore[0].private_ip : null
}
