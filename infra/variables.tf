variable "region" {
  description = "Huawei Cloud region"
  type        = string
  default     = "cn-north-4"
}

variable "project_id" {
  description = "Huawei Cloud project ID"
  type        = string
}

variable "stack_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "s3-hybrid-cache"
}

variable "vpc_cidr" {
  description = "CIDR for the VPC"
  type        = string
  default     = "192.168.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the subnet"
  type        = string
  default     = "192.168.1.0/24"
}

variable "client_cidr" {
  description = "CIDR allowed to access the proxy (client networks)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "admin_ip" {
  description = "IP allowed for SSH access"
  type        = string
  default     = "0.0.0.0/0"
}

variable "proxy_flavor" {
  description = "ECS flavor ID for proxy instances"
  type        = string
  default     = "c6.large.2"  # 2 vCPUs, 4 GB RAM
}

variable "proxy_image" {
  description = "ECS image name (must support Rust compilation or pre-built binary)"
  type        = string
  default     = "CentOS 7.9 64bit"
}

variable "proxy_instance_count" {
  description = "Number of proxy instances (shared cache via SFS Turbo)"
  type        = number
  default     = 2
}

variable "proxy_password" {
  description = "Admin password for ECS instance (8-26 chars, must contain uppercase, lowercase, digits)"
  type        = string
  default     = "Test@123456"
}

variable "sfs_turbo_size" {
  description = "SFS Turbo size in GB (disabled: SFS Turbo requires whitelist)"
  type        = number
  default     = 500
}

variable "proxy_binary_url" {
  description = "URL to download the pre-built s3-proxy binary (OBS or public URL)"
  type        = string
  default     = ""
}

variable "obs_endpoint" {
  description = "OBS endpoint for the upstream S3-compatible store"
  type        = string
  default     = "obs.cn-north-4.myhuaweicloud.com"
}
