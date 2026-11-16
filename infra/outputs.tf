output "proxy_instance_ips" {
  description = "Private IP addresses of proxy instances"
  value       = huaweicloud_compute_instance.proxy[*].access_ip_v4
}

output "proxy_instance_public_ips" {
  description = "Public IP addresses of proxy instances (EIP)"
  value       = huaweicloud_vpc_eip.proxy[*].address
}

output "cache_directory" {
  description = "Cache directory on the proxy instance (local disk for L2-L5 verification)"
  value       = "/mnt/cache"
}

output "vpc_id" {
  description = "VPC ID"
  value       = huaweicloud_vpc.main.id
}

output "subnet_id" {
  description = "Subnet ID"
  value       = huaweicloud_vpc_subnet.main.id
}

output "proxy_security_group_id" {
  description = "Proxy security group ID"
  value       = huaweicloud_networking_secgroup.proxy.id
}

output "proxy_config_command" {
  description = "OBS endpoint configuration for clients"
  value       = <<-EOT
# Configure OBS (S3-compatible) client
# Use obsutil with --endpoint-url
# Example (obsutil):
#   obsutil config -i <HW_ACCESS_KEY> -k <HW_SECRET_KEY> -e ${var.obs_endpoint}
#   obsutil ls obs:// --endpoint https://${var.obs_endpoint}
  EOT
}
