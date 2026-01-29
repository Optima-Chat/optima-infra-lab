#!/bin/bash
# ==============================================================================
# Golden AMI 构建脚本
# ==============================================================================
#
# 用法:
#   ./build.sh                    # 使用默认配置
#   ./build.sh --tag v1.2.3       # 指定镜像 tag
#   ./build.sh --cluster optima-stage-cluster  # 指定集群
#
# ==============================================================================

set -e

# 默认值
ECR_IMAGE_TAG="latest"
ECS_CLUSTER="optima-prod-cluster"
AWS_REGION="ap-southeast-1"

# 解析参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --tag)
      ECR_IMAGE_TAG="$2"
      shift 2
      ;;
    --cluster)
      ECS_CLUSTER="$2"
      shift 2
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    -h|--help)
      echo "用法: $0 [选项]"
      echo ""
      echo "选项:"
      echo "  --tag TAG        Docker 镜像 tag (默认: latest)"
      echo "  --cluster NAME   ECS 集群名称 (默认: optima-prod-cluster)"
      echo "  --region REGION  AWS 区域 (默认: ap-southeast-1)"
      echo "  -h, --help       显示帮助"
      exit 0
      ;;
    *)
      echo "未知参数: $1"
      exit 1
      ;;
  esac
done

echo "========================================"
echo "Golden AMI 构建"
echo "========================================"
echo "镜像 Tag: $ECR_IMAGE_TAG"
echo "ECS 集群: $ECS_CLUSTER"
echo "AWS 区域: $AWS_REGION"
echo "========================================"

# 切换到 packer 目录
cd "$(dirname "$0")"

# 初始化 Packer（首次运行需要）
if [ ! -d ".packer.d" ]; then
  echo ">>> 初始化 Packer..."
  packer init .
fi

# 验证配置
echo ">>> 验证 Packer 配置..."
packer validate \
  -var="ecr_image_tag=$ECR_IMAGE_TAG" \
  -var="ecs_cluster_name=$ECS_CLUSTER" \
  -var="aws_region=$AWS_REGION" \
  ai-shell-golden.pkr.hcl

# 构建 AMI
echo ">>> 开始构建 Golden AMI..."
packer build \
  -var="ecr_image_tag=$ECR_IMAGE_TAG" \
  -var="ecs_cluster_name=$ECS_CLUSTER" \
  -var="aws_region=$AWS_REGION" \
  ai-shell-golden.pkr.hcl

# 读取输出
if [ -f "manifest.json" ]; then
  AMI_ID=$(jq -r '.builds[-1].artifact_id' manifest.json | cut -d':' -f2)
  echo ""
  echo "========================================"
  echo "Golden AMI 构建完成!"
  echo "========================================"
  echo "AMI ID: $AMI_ID"
  echo ""
  echo "更新 Terraform 配置:"
  echo "  golden_ami_id = \"$AMI_ID\""
  echo ""
  echo "或更新 Launch Template:"
  echo "  aws ec2 create-launch-template-version \\"
  echo "    --launch-template-name ai-shell-prod-ecs \\"
  echo "    --source-version '\$Latest' \\"
  echo "    --launch-template-data '{\"ImageId\":\"$AMI_ID\"}' \\"
  echo "    --region $AWS_REGION"
fi
