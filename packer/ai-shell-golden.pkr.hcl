# ==============================================================================
# AI Shell Golden AMI - Packer 配置
# ==============================================================================
#
# 构建包含预拉取 Docker 镜像的 Golden AMI，减少 EC2 冷启动时间。
#
# 使用方法:
#   packer init .
#   packer build -var="ecr_image_tag=latest" ai-shell-golden.pkr.hcl
#
# ==============================================================================

packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# ==============================================================================
# 变量
# ==============================================================================

variable "aws_region" {
  type        = string
  default     = "ap-southeast-1"
  description = "AWS 区域"
}

variable "ecs_cluster_name" {
  type        = string
  default     = "optima-prod-cluster"
  description = "ECS 集群名称（写入 ecs.config）"
}

variable "ecr_repository" {
  type        = string
  default     = "585891120210.dkr.ecr.ap-southeast-1.amazonaws.com/optima-ai-shell"
  description = "ECR 仓库地址"
}

variable "ecr_image_tag" {
  type        = string
  default     = "latest"
  description = "要预拉取的镜像 tag"
}

variable "instance_type" {
  type        = string
  default     = "t3.medium"
  description = "构建实例类型"
}

variable "ami_name_prefix" {
  type        = string
  default     = "ai-shell-golden"
  description = "AMI 名称前缀"
}

variable "subnet_id" {
  type        = string
  default     = ""
  description = "构建用子网 ID（可选，留空使用默认 VPC）"
}

variable "iam_instance_profile" {
  type        = string
  default     = "packer-ecr-access"
  description = "IAM Instance Profile（需要 ECR 读取权限）"
}

# ==============================================================================
# 数据源 - 获取最新的 ECS 优化 AMI
# ==============================================================================

data "amazon-ami" "ecs_optimized" {
  filters = {
    name                = "al2023-ami-ecs-hvm-*-x86_64"
    virtualization-type = "hvm"
    root-device-type    = "ebs"
  }
  owners      = ["amazon"]
  most_recent = true
  region      = var.aws_region
}

# ==============================================================================
# Source - EC2 构建实例
# ==============================================================================

source "amazon-ebs" "golden" {
  ami_name        = "${var.ami_name_prefix}-${formatdate("YYYYMMDD-hhmm", timestamp())}"
  ami_description = "AI Shell Golden AMI with pre-pulled Docker image"
  instance_type   = var.instance_type
  region          = var.aws_region
  source_ami      = data.amazon-ami.ecs_optimized.id

  # 网络配置
  subnet_id                   = var.subnet_id != "" ? var.subnet_id : null
  associate_public_ip_address = true

  # IAM Instance Profile（用于访问 ECR）
  iam_instance_profile = var.iam_instance_profile

  # SSH 配置
  ssh_username         = "ec2-user"
  ssh_timeout          = "10m"
  ssh_interface        = "public_ip"

  # EBS 配置 - 启用加密以支持 Hibernation
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 30
    volume_type           = "gp3"
    iops                  = 3000
    throughput            = 125
    encrypted             = true
    delete_on_termination = true
  }

  # 标签
  tags = {
    Name        = "${var.ami_name_prefix}-${formatdate("YYYYMMDD-hhmm", timestamp())}"
    Project     = "optima-ai-shell"
    Environment = "prod"
    ManagedBy   = "packer"
    SourceAMI   = data.amazon-ami.ecs_optimized.id
    ImageTag    = var.ecr_image_tag
  }

  # 快照标签
  snapshot_tags = {
    Name        = "${var.ami_name_prefix}-${formatdate("YYYYMMDD-hhmm", timestamp())}"
    Project     = "optima-ai-shell"
    ManagedBy   = "packer"
  }
}

# ==============================================================================
# Build - 构建步骤
# ==============================================================================

build {
  sources = ["source.amazon-ebs.golden"]

  # 1. 配置 ECS Agent
  provisioner "shell" {
    inline = [
      "echo '=== 配置 ECS Agent ==='",
      "sudo tee /etc/ecs/ecs.config > /dev/null <<EOF",
      "ECS_CLUSTER=${var.ecs_cluster_name}",
      "ECS_WARM_POOLS_CHECK=true",
      "ECS_ENABLE_TASK_IAM_ROLE=true",
      "ECS_IMAGE_PULL_BEHAVIOR=prefer-cached",
      "ECS_CONTAINER_STOP_TIMEOUT=120s",
      "ECS_ENABLE_SPOT_INSTANCE_DRAINING=true",
      "EOF",
      "cat /etc/ecs/ecs.config"
    ]
  }

  # 2. 等待 Docker 服务启动
  provisioner "shell" {
    inline = [
      "echo '=== 等待 Docker 服务 ==='",
      "sudo systemctl start docker || true",
      "for i in {1..30}; do sudo docker info && break || sleep 2; done"
    ]
  }

  # 3. 登录 ECR 并预拉取镜像
  provisioner "shell" {
    inline = [
      "echo '=== 预拉取 Docker 镜像 ==='",
      "REGION=${var.aws_region}",
      "ECR_URL=${var.ecr_repository}",
      "IMAGE_TAG=${var.ecr_image_tag}",
      "",
      "# 登录 ECR",
      "aws ecr get-login-password --region $REGION | sudo docker login --username AWS --password-stdin $(echo $ECR_URL | cut -d'/' -f1)",
      "",
      "# 拉取镜像",
      "echo \"Pulling $ECR_URL:$IMAGE_TAG\"",
      "sudo docker pull $ECR_URL:$IMAGE_TAG",
      "",
      "# 验证",
      "sudo docker images | grep ai-shell || true"
    ]
  }

  # 4. 预热 EBS（读取关键文件，触发从 S3 加载）
  provisioner "shell" {
    inline = [
      "echo '=== 预热 EBS ==='",
      "# 读取 Docker 镜像层（最重要）",
      "sudo find /var/lib/docker -type f -exec cat {} \\; > /dev/null 2>&1 || true",
      "",
      "# 读取系统关键文件",
      "sudo find /usr/bin /usr/lib64 -type f -exec cat {} \\; > /dev/null 2>&1 || true",
      "",
      "# 同步写入",
      "sync",
      "",
      "echo 'EBS 预热完成'"
    ]
  }

  # 5. 清理
  provisioner "shell" {
    inline = [
      "echo '=== 清理 ==='",
      "# 清理 Docker 登录凭证",
      "sudo rm -f /root/.docker/config.json",
      "rm -f ~/.docker/config.json",
      "",
      "# 清理日志",
      "sudo rm -f /var/log/cloud-init*.log",
      "sudo rm -f /var/log/messages",
      "",
      "# 清理 SSH keys（Packer 会在构建后删除）",
      "rm -f ~/.ssh/authorized_keys",
      "",
      "echo 'Golden AMI 构建完成!'"
    ]
  }

  # 输出 AMI 信息
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
