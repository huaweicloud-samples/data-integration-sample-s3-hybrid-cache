# S3 Hybrid Cache Proxy

![License](https://img.shields.io/badge/License-MIT%20No%20Attribution-blue)
![Huawei Cloud](https://img.shields.io/badge/Huawei%20Cloud-ECS%20%7C%20OBS-orange)
![Verify](https://img.shields.io/badge/verify-L1--L5%20PASS-green)

## 1. Overview

A high-performance transparent cache proxy deployed on Huawei Cloud ECS that accelerates OBS (Object Storage Service) access. It provides intelligent multi-layer caching, a streaming architecture, and comprehensive observability. Clients connect through OBS's S3-compatible interface with zero changes to their business protocols.

**Core capabilities**:

- **Transparent authentication**: the proxy stores no credentials and passes client SigV4-signed requests straight through to OBS, preserving full IAM policy control
- **Local disk cache**: proxy instances cache data on local disks to avoid re-fetching from OBS (production can switch to SFS Turbo for multi-instance sharing)
- **Stateless proxy**: no direct inter-instance communication, supporting horizontal scaling and high availability
- **Streaming architecture**: large files stream without buffering and without throughput loss
- **Unified range storage**: full objects, byte ranges, and multipart uploads are interchangeably stored and accessed

Suitable for hybrid-cloud/on-premises workloads that need low-latency, high-throughput OBS access — e.g., medical imaging, life sciences, quantitative trading, and autonomous driving.

## 2. Table of Contents

- [1. Overview](#1-overview)
- [2. Table of Contents](#2-table-of-contents)
- [3. Architecture Diagram](#3-architecture-diagram)
- [4. Highlights](#4-highlights)
- [5. Cloud Services Involved](#5-cloud-services-involved)
- [6. Prerequisites](#6-prerequisites)
- [7. Quick Start](#7-quick-start)
- [8. Step-by-Step Deployment](#8-step-by-step-deployment)
- [9. Usage / Verification](#9-usage--verification)
- [10. Resource Cleanup](#10-resource-cleanup)
- [11. Detailed Description](#11-detailed-description)
- [12. Dependencies and Acknowledgements](#12-dependencies-and-acknowledgements)
- [13. FAQ / Troubleshooting](#13-faq--troubleshooting)
- [14. Contributing](#14-contributing)
- [15. License](#15-license)
- [16. Contact / Maintainers](#16-contact--maintainers)

## 3. Architecture Diagram

```mermaid
flowchart TB
    subgraph Clients
        CLI[OBS-compatible client<br/>obsutil / SDK]
    end

    subgraph Huawei Cloud VPC
        ELB[ELB load balancer<br/>optional]
        subgraph Proxy instances
            P1[ECS instance 1<br/>s3-proxy]
            P2[ECS instance 2<br/>s3-proxy]
        end
        OBS[OBS<br/>Object Storage Service]
    end

    CLI -->|SigV4-signed request| ELB
    ELB --> P1
    ELB --> P2
    P1 -->|cache hit (local disk)| CLI
    P2 -->|cache hit (local disk)| CLI
    P1 -->|cache miss| OBS
    P2 -->|cache miss| OBS
```

**Data flow**: clients send SigV4-signed requests → the proxy checks the local disk cache → hits return immediately → misses are forwarded to OBS and written into cache.

## 4. Highlights

- **Transparent proxy**: no client code changes; OBS is S3-compatible and SigV4 signatures pass through untouched
- **Local disk cache**: proxy instances cache on local disks to avoid re-fetching the same object (production can switch to SFS Turbo for shared caching)
- **High performance**: disk cache + streaming transfer, with byte-range reads for large files
- **Two implementations**: a full-featured Rust build (production-grade) or a zero-dependency Python lightweight proxy (rapid verification)
- **High availability**: stateless multi-instance deployment with horizontal scaling
- **Full observability**: health check + metrics endpoints

## 5. Cloud Services Involved

| Cloud Service | Usage |
|---------------|-------|
| Elastic Cloud Server (ECS) | Proxy instance host |
| Object Storage Service (OBS) | Data source (S3-compatible interface + SigV4 signing) |
| Virtual Private Cloud (VPC) | Network isolation |
| Elastic IP (EIP) | Public access (optional) |
| Elastic Load Balancer (ELB) | Traffic distribution (optional) |
| SFS Turbo | Shared multi-instance cache (optional, whitelist required) |

> All resources can be released at any time after deployment.

## 6. Prerequisites

- A Huawei Cloud account with **cn-north-4 (Beijing 4)** enabled
- API access keys (AK/SK)
- Terraform >= 1.5 installed
- huaweicloud Provider >= 1.94
- Rust >= 1.89 (only if building from source; a prebuilt binary is recommended)
- An existing OBS bucket

## 7. Quick Start

```bash
# 1. Configure credentials
export HW_ACCESS_KEY="<AK>"
export HW_SECRET_KEY="<SK>"
export TF_VAR_project_id="<Project ID>"

# 2. Initialize Terraform
cd infra/
terraform init

# 3. Preview changes
terraform plan

# 4. Deploy
terraform apply
```

## 8. Step-by-Step Deployment

### Step 1: Configure Terraform variables

```bash
cd infra/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: fill in the project ID, SSH public key, etc.
```

Key configuration items:

| Parameter | Description | Default |
|---|---|---|
| `region` | Huawei Cloud region | `cn-north-4` |
| `proxy_instance_count` | Number of proxy instances | `1` |
| `cache_dir` | Local cache directory | `/mnt/cache` |
| `obs_endpoint` | OBS endpoint | `obs.cn-north-4.myhuaweicloud.com` |

### Step 2: Deploy infrastructure

```bash
terraform init
terraform plan
terraform apply
```

Provisioned stack: VPC / subnet / security group → ECS proxy instances (userdata bootstraps the proxy and registers a systemd service) → EIP (optional).

### Step 3: Verify the deployment

```bash
# Get the proxy instance IP
terraform output proxy_public_ip

# Health check (proxy listens on port 80)
curl http://<PROXY_IP>/health
# Expected: {"status": "ok", "cache_dir": "/mnt/cache", "cache_size": 0}

# View proxy logs
ssh root@<PROXY_IP> "journalctl -u s3-proxy -f"
```

## 9. Usage / Verification

### Configure the client (OBS-compatible CLI)

```bash
# Configure the OBS CLI (S3-compatible)
obsutil config -i <HW_ACCESS_KEY> -k <HW_SECRET_KEY> -e obs.cn-north-4.myhuaweicloud.com

# List OBS buckets (through the proxy)
obsutil ls obs:// --endpoint http://<PROXY_IP>:80

# Download an object (first fetch from OBS, cached afterwards)
obsutil cp obs://bucket/large-file ./local -endpoint http://<PROXY_IP>:80

# Download again (served from cache)
obsutil cp obs://bucket/large-file ./local2 -endpoint http://<PROXY_IP>:80
```

### Verify cache hits

The proxy exposes `/metrics` (Prometheus format) and `/health` endpoints:

```bash
# View cache size
curl http://<PROXY_IP>/metrics
# Sample output:
# # HELP s3_proxy_cache_size Current cache size in bytes
# # TYPE s3_proxy_cache_size gauge
# s3_proxy_cache_size 5432

# View the cache directory
ssh root@<PROXY_IP> "ls -la /mnt/cache/"
```

### Verification status

| Level | Description | Status |
|---|---|---|
| L1 Infrastructure | Terraform deployment succeeded | ✅ Pass |
| L2 Proxy running | ECS instances up, health check passed | ✅ Pass |
| L3 Cache function | OBS read/write, cache hits | ✅ Pass |
| L4 Shared storage | Local disk cache (transparent proxy + cache) | ✅ Pass |
| L5 End-to-end | Client accesses OBS through the proxy | ✅ Pass |

> **Note**: L1-L5 all passed (2026-08-23, cn-north-4). See `others/verification-report.md` for the detailed report.

## 10. Resource Cleanup

```bash
cd infra/
terraform destroy
```

Type `yes` to confirm. After destroy, verify manually:

- Console -> Elastic Cloud Server -> confirm ECS deleted
- Console -> Object Storage Service -> confirm OBS bucket deleted
- Console -> Elastic IP -> confirm EIP released

## 11. Detailed Description

### 11.1 Transparent authentication

The proxy passes client SigV4-signed requests through to OBS. OBS fully supports S3 SigV4 signing, so:

- Clients need no changes (keep using OBS-compatible SDK/CLI)
- The proxy stores no OBS credentials
- IAM policy and access control are enforced entirely by OBS

### 11.2 Caching (local disk)

Proxy instances cache data on local disks:

- Cache key = `MD5(method:path)`, files stored under `/mnt/cache/`
- Default cap 5 GB; beyond that, new cache writes stop
- Production can switch to SFS Turbo (whitelist required) for shared multi-instance caching

### 11.3 Two implementations

This repository ships two implementations:

| Implementation | Location | Use case |
|---|---|---|
| Rust full build | `src/rust/` (Cargo project) | Production: streaming, byte-range caching, compression, dashboard |
| Python lightweight proxy | embedded in `infra/userdata.sh` | L1-L5 verification: zero external dependencies, stdlib only |

The Rust build is deployed via the `proxy_binary_url` variable (prebuilt binary download); the Python proxy is written by the userdata script and registered as a systemd service automatically.

### 11.4 Configuration reference

| Parameter | Default | Description |
|---|---|---|
| `cache_dir` | `/mnt/cache` | Cache directory (local disk) |
| `max_cache_size` | 5 GB | Disk cache size |
| `OBS_ENDPOINT` | `obs.cn-north-4.myhuaweicloud.com` | OBS regional endpoint |

Full configuration: `src/config/config.example.yaml`

### 11.5 Repository layout

```
├── README.md / README.en.md    # Bilingual guides
├── docs/
│   ├── architecture.md         # Architecture notes
│   └── deployment-guide.md     # Deployment guide
├── infra/
│   ├── main.tf                 # Full IaC (VPC/ECS/EIP/OBS)
│   ├── variables.tf            # Variable definitions
│   ├── terraform.tfvars.example
│   └── userdata.sh             # ECS bootstrap (embeds the Python lightweight proxy)
├── src/
│   ├── Cargo.toml              # Rust project definition
│   ├── rust/                   # Rust full implementation (60+ modules)
│   └── config/                 # Configuration examples and systemd unit
└── others/                     # Process artifacts and audit files
```

## 12. Dependencies and Acknowledgements

**Key dependencies**:

- Rust >= 1.89
- Tokio + Hyper (async runtime)
- rustls (TLS support)
- Terraform >= 1.5
- huaweicloud Provider >= 1.94

**Acknowledgements**:

- Huawei Cloud ECS / OBS / SFS Turbo product documentation

## 13. FAQ / Troubleshooting

**Q: The proxy cannot reach OBS?**

A: Check the OBS endpoint configuration (`obs.<region>.myhuaweicloud.com`) and that the ECS security group allows outbound HTTPS (443).

**Q: SFS Turbo mount fails?**

A: SFS Turbo requires an account whitelist (apply to enable). The current version uses ECS local disk cache and does not depend on SFS Turbo. For shared caching, apply for the SFS Turbo whitelist and mount NFS at `/mnt/cache`.

**Q: Cache does not take effect?**

A: Check that `cache_dir` is mounted correctly (`df -h /mnt/cache`) and inspect proxy logs (`journalctl -u s3-proxy`).

**Q: Proxy returns 403 SignatureDoesNotMatch?**

A: The proxy must not rewrite the Host header when passing SigV4-signed requests. OBS parses the bucket name from the Host header (`bucket.obs.<region>.myhuaweicloud.com`) and validates the signature against it. If the proxy changes the Host from the virtual-hosted domain to its own IP, the signature fails. Correct approach: change only the URL scheme/host and preserve the client's original Host header.

**Q: The proxy process stops after the SSH session exits?**

A: Do not use `nohup &`. Use systemd (the userdata script already registers `s3-proxy.service` at deployment).

**Q: Proxy reports Address already in use (Errno 98)?**

A: Python's `HTTPServer` does not set `SO_REUSEADDR` by default, so binding fails while the port is in TIME_WAIT. The bundled code already uses an address-reusing Server class.

**Q: PUT to OBS reports XAmzContentSHA256Mismatch?**

A: There are minor differences between OBS and client SDK implementations of `X-Amz-Content-SHA256`. GET is unaffected; for PUT, use presigned URLs instead.

**Q: Terraform provider install fails (Windows)?**

A: Copy `.terraform/providers/` and `.terraform.lock.hcl` from a previously successful deployment, or download the provider executable into the `filesystem_mirror` path configured in `terraform.rc`.

## 14. Contributing

Issues and pull requests are welcome. Before submitting:

1. Ensure Rust changes compile with `cargo build`, and Python changes pass local execution tests
2. Keep new variables in sync across `variables.tf` and `terraform.tfvars.example`
3. Keep bilingual docs consistent (README.md / README.en.md)

## 15. License

Licensed under the [MIT No Attribution](LICENSE) license.

## 16. Contact / Maintainers

- **Submitter**: Shangdongd
- **Feedback**: Huawei Cloud technical support or ticket system
- Huawei Cloud docs: [Huawei Cloud Help Center](https://support.huaweicloud.com/)

---

> This practice is a Huawei Cloud best-practice reference implementation and is not a production deployment template. Adjust specifications and security configurations to your actual business needs.
