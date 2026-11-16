# 部署指南 — sample-s3-hybrid-cache

> 本文档描述 S3 透明缓存代理在华为云上的完整部署流程，包括前置检查、Terraform 部署、代理服务安装与验证。

## 1. 部署架构

```
┌─────────────────────────────────────────────────┐
│                  华为云 VPC                       │
│                                                 │
│  ┌──────────────┐   ┌──────────────────────┐   │
│  │  安全组 SG    │   │  ECS 代理实例         │   │
│  │  80/443/22   │──▶│  s3-proxy.py         │   │
│  │  /metrics    │   │  /mnt/cache (本地盘)  │   │
│  └──────────────┘   └──────────┬───────────┘   │
│                                │ HTTPS         │
│  ┌─────────────────────────────▼─────────────┐  │
│  │              OBS 对象存储                  │  │
│  │        (S3 兼容, SigV4 签名)              │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

## 2. 前置检查

### 2.1 账号与区域

- [ ] 华为云账号已实名认证
- [ ] 已开通 **cn-north-4（北京四）** 区域
- [ ] 已创建 IAM 用户并获取 **AK/SK**
- [ ] 已获取 **Project ID**（控制台 → 我的凭证 → 项目列表）

### 2.2 本地工具

```bash
# 检查 Terraform
terraform version        # 需要 >= 1.5

# 检查 huaweicloud Provider
# 在 infra/ 目录执行 terraform init 时会自动下载

# 检查 Python（代理脚本运行在 ECS 上，本机仅需 Terraform）
python3 --version        # 本机可选
```

### 2.3 网络规划

| 项目 | 规划值 | 说明 |
|---|---|---|
| VPC CIDR | `192.168.0.0/16` | 网络隔离 |
| Subnet CIDR | `192.168.1.0/24` | 子网划分 |
| 安全组 | 放行 80/443/22 | 代理端口 + SSH |
| 客户端访问 | `0.0.0.0/0` | 生产环境建议限制来源 IP |

## 3. Terraform 部署

### 3.1 配置凭据

```bash
export HW_ACCESS_KEY="<你的AK>"
export HW_SECRET_KEY="<你的SK>"
export TF_VAR_project_id="<你的Project ID>"
```

### 3.2 初始化与部署

```bash
cd sample-s3-hybrid-cache/infra/

# 创建 tfvars（首次）
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars   # 按需修改

# 初始化（下载 Provider）
terraform init

# 预览变更
terraform plan

# 部署
terraform apply -auto-approve
```

### 3.3 部署输出

部署完成后，`terraform output` 提供关键信息：

```bash
terraform output
# proxy_public_ip   = "114.116.235.140"
# proxy_private_ip  = "192.168.1.185"
# obs_bucket        = "custom-nlp-pipeline-demo"
```

## 4. 代理服务管理

代理通过 **systemd** 管理，部署时由 userdata 脚本自动安装。

### 4.1 服务状态检查

```bash
ssh root@<PROXY_IP>

# 查看服务状态
systemctl status s3-proxy

# 查看实时日志
journalctl -u s3-proxy -f

# 手动启停
systemctl restart s3-proxy
systemctl stop s3-proxy
```

### 4.2 systemd 单元文件

代理服务使用以下 systemd 配置（部署时自动创建）：

```ini
[Unit]
Description=S3 Hybrid Cache Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/s3-proxy.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

> **注意**：不要使用 `nohup &` 启动代理，SSH 会话退出后进程会被终止。必须使用 systemd 管理。

### 4.3 缓存目录

缓存默认存储在 `/mnt/cache`：

```bash
# 查看缓存大小
du -sh /mnt/cache/

# 查看缓存文件
ls -la /mnt/cache/
```

## 5. 客户端配置

### 5.1 obsutil（华为云官方 CLI）

```bash
# 配置 OBS 访问
obsutil config -i <AK> -k <SK> -e obs.cn-north-4.myhuaweicloud.com

# 通过代理访问
obsutil ls obs://bucket/ --endpoint http://<PROXY_IP>:80
```

### 5.2 S3 兼容 CLI（可选）

OBS 兼容 S3 协议，任何 S3 协议 CLI 均可通过代理访问：

```bash
# 以 S3 协议 CLI 为例，通过代理访问 OBS
s3-cli ls s3://bucket/ \
  --endpoint-url http://<PROXY_IP>:80 \
  --no-verify-ssl
```

> 客户端工具需将 endpoint 指向代理地址，签名参数仍使用华为云 AK/SK。

### 5.3 Python boto3

```python
import boto3
from botocore.client import Config

s3 = boto3.client(
    's3',
    aws_access_key_id='<AK>',
    aws_secret_access_key='<SK>',
    region_name='cn-north-4',
    endpoint_url='http://<PROXY_IP>:80',
    config=Config(s3={'addressing_style': 'path'})
)
```

## 6. 部署验证

### 6.1 代理健康检查

```bash
curl http://<PROXY_IP>/health
# 预期: {"status": "ok", "cache_dir": "/mnt/cache", "cache_size": 0}
```

### 6.2 缓存指标

```bash
curl http://<PROXY_IP>/metrics
# 预期: s3_proxy_cache_size <bytes>
```

### 6.3 端到端测试

```bash
# 上传文件
obsutil cp ./test.txt obs://bucket/test.txt --endpoint http://<PROXY_IP>:80

# 下载（首次：缓存未命中，回源 OBS）
obsutil cp obs://bucket/test.txt ./test1.txt --endpoint http://<PROXY_IP>:80

# 再次下载（缓存命中）
obsutil cp obs://bucket/test.txt ./test2.txt --endpoint http://<PROXY_IP>:80

# 验证缓存已生成
ssh root@<PROXY_IP> "ls /mnt/cache/"
```

## 7. 多实例扩展（可选）

如需水平扩展，可增加 `proxy_instance_count`：

```hcl
# terraform.tfvars
proxy_instance_count = 3
```

在 ECS 前接入 ELB 负载均衡器实现流量分发（参考 `main.tf` 中的 ELB 配置）。

> **注意**：多实例场景下，默认使用**本地磁盘缓存**，各实例缓存独立。如需共享缓存，可申请 SFS Turbo 白名单后挂载至 `/mnt/cache`。

## 8. 安全加固建议

1. **限制客户端来源 IP**：`client_cidr` 从 `0.0.0.0/0` 改为具体网段
2. **启用 HTTPS**：在代理前接入 ELB + 证书（SCM）
3. **最小化 AK/SK 权限**：IAM 策略仅授予 OBS 读写所需权限
4. **定期轮换 AK/SK**：遵循华为云密钥管理规范
5. **监控审计**：通过 LTS 收集代理日志，CES 监控 ECS 指标

## 9. 故障排查

| 现象 | 可能原因 | 解决方案 |
|---|---|---|
| `Address already in use` | Python 3.6 HTTPServer 无 SO_REUSEADDR | 使用 `ReuseServer` 类（已在代码中处理） |
| 进程随 SSH 退出 | 使用 `nohup &` 启动 | 改用 systemd 管理 |
| `SignatureDoesNotMatch` | 代理改写 Host 头 | 透明代理保留客户端 Host 头 |
| 403 AccessDenied | 匿名访问私有桶 | 使用带签名的请求 |
| 无法连接代理 | 安全组未放行 80 端口 | 检查安全组规则 |

## 10. 清理资源

```bash
cd sample-s3-hybrid-cache/infra/
terraform destroy -auto-approve
```

验证清理：
- ECS 已删除（控制台 → 弹性云服务器）
- EIP 已释放（控制台 → 弹性公网 IP）
- OBS 桶已删除（控制台 → 对象存储服务）
