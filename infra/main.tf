# S3 Hybrid Cache Proxy - Huawei Cloud Deployment
# Terraform configuration for deploying the transparent caching proxy
# on Huawei Cloud ECS with SFS Turbo shared storage.

terraform {
  required_version = ">= 1.5"
  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = "= 1.94.0"
    }
  }
}

# Provider configuration (credentials via HW_ACCESS_KEY / HW_SECRET_KEY env vars)
provider "huaweicloud" {
  region = var.region
}

# ─── Data sources ────────────────────────────────────────────────────────────

data "huaweicloud_availability_zones" "default" {
  region = var.region
}

# ─── VPC ─────────────────────────────────────────────────────────────────────

resource "huaweicloud_vpc" "main" {
  name = "${var.stack_prefix}-vpc"
  cidr = var.vpc_cidr
}

resource "huaweicloud_vpc_subnet" "main" {
  name       = "${var.stack_prefix}-subnet"
  cidr       = var.subnet_cidr
  gateway_ip = cidrhost(var.subnet_cidr, 1)
  vpc_id     = huaweicloud_vpc.main.id
}

# ─── Security Groups ─────────────────────────────────────────────────────────

# Security group for proxy instances
resource "huaweicloud_networking_secgroup" "proxy" {
  name        = "${var.stack_prefix}-proxy-sg"
  description = "Security group for S3 hybrid cache proxy instances"
}

# Allow HTTP (port 80) from clients
resource "huaweicloud_networking_secgroup_rule" "proxy_http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = var.client_cidr
  security_group_id = huaweicloud_networking_secgroup.proxy.id
}

# Allow HTTPS passthrough (port 443)
resource "huaweicloud_networking_secgroup_rule" "proxy_https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = var.client_cidr
  security_group_id = huaweicloud_networking_secgroup.proxy.id
}

# Allow health check endpoint (port 8080)
resource "huaweicloud_networking_secgroup_rule" "proxy_health" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8080
  port_range_max    = 8080
  remote_ip_prefix  = var.client_cidr
  security_group_id = huaweicloud_networking_secgroup.proxy.id
}

# Allow metrics endpoint (port 9090)
resource "huaweicloud_networking_secgroup_rule" "proxy_metrics" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 9090
  port_range_max    = 9090
  remote_ip_prefix  = var.client_cidr
  security_group_id = huaweicloud_networking_secgroup.proxy.id
}

# Allow NFS from proxy instances to SFS Turbo (security group to itself)
resource "huaweicloud_networking_secgroup_rule" "proxy_nfs" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 2049
  port_range_max    = 2049
  remote_group_id   = huaweicloud_networking_secgroup.proxy.id
  security_group_id = huaweicloud_networking_secgroup.proxy.id
}

# Allow SSH from admin (optional)
resource "huaweicloud_networking_secgroup_rule" "proxy_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = var.admin_ip
  security_group_id = huaweicloud_networking_secgroup.proxy.id
}

# ─── SFS Turbo (shared cache storage) ────────────────────────────────────────
# NOTE: SFS Turbo requires service whitelist. Disabled for L2-L5 verification.
# Using ECS local disk cache instead.
# resource "huaweicloud_sfs_turbo" "cache" {
#   name          = "${var.stack_prefix}-cache"
#   size          = var.sfs_turbo_size  # GB
#   share_proto   = "NFS"
#   vpc_id        = huaweicloud_vpc.main.id
#   subnet_id     = huaweicloud_vpc_subnet.main.id
#   security_group_id = huaweicloud_networking_secgroup.proxy.id
#   availability_zone = data.huaweicloud_availability_zones.default.names[0]
# }

# ─── SSH Keypair ────────────────────────────────────────────────────────────

resource "huaweicloud_compute_keypair" "proxy" {
  name       = "${var.stack_prefix}-keypair"
  public_key = file("${path.module}/id_rsa.pub")
}

# ─── ECS Proxy Instances ─────────────────────────────────────────────────────

resource "huaweicloud_compute_instance" "proxy" {
  count             = var.proxy_instance_count
  name              = "${var.stack_prefix}-proxy-${count.index + 1}"
  flavor_id         = var.proxy_flavor
  image_name        = var.proxy_image
  security_group_ids = [huaweicloud_networking_secgroup.proxy.id]
  availability_zone = data.huaweicloud_availability_zones.default.names[0]

  network {
    uuid = huaweicloud_vpc_subnet.main.id
  }

  key_pair = huaweicloud_compute_keypair.proxy.name
  admin_pass = var.proxy_password

  system_disk_type = "SSD"
  system_disk_size = 40

  # User data script to install and start the proxy
  user_data = base64encode(templatefile("${path.module}/userdata.sh", {
    cache_dir       = "/mnt/cache"
    log_dir         = "/var/log/s3-proxy"
    config_url      = var.proxy_binary_url
    region          = var.region
    obs_endpoint    = var.obs_endpoint
  }))

  tags = {
    Name    = "${var.stack_prefix}-proxy-${count.index + 1}"
    Service = "s3-hybrid-cache"
  }
}

# ─── EIP for Proxy Instance ──────────────────────────────────────────────────

resource "huaweicloud_vpc_eip" "proxy" {
  count = var.proxy_instance_count
  publicip {
    type = "5_bgp"
  }
  bandwidth {
    name       = "${var.stack_prefix}-proxy-eip-bw-${count.index + 1}"
    size       = 5
    share_type = "PER"
  }
}

resource "huaweicloud_compute_eip_associate" "proxy" {
  count       = var.proxy_instance_count
  instance_id = huaweicloud_compute_instance.proxy[count.index].id
  public_ip   = huaweicloud_vpc_eip.proxy[count.index].address
}

# ─── Outputs (see outputs.tf) ────────────────────────────────────────────────
