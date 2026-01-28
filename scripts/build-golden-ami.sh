#!/bin/bash
# 构建 Golden AMI - 预烘焙 Docker 镜像和 ECS 配置
# 可减少冷启动时间 ~25-30s

set -ex

REGION="${AWS_REGION:-ap-southeast-1}"
PROJECT_NAME="fargate-warm-pool-test"
AMI_NAME="${PROJECT_NAME}-golden-$(date +%Y%m%d%H%M)"

# 预拉取的镜像列表
IMAGES=(
  "585891120210.dkr.ecr.ap-southeast-1.amazonaws.com/optima-ai-shell:latest"
)

echo "=============================================="
echo "  Golden AMI 构建脚本"
echo "=============================================="
echo ""

# Step 1: 获取最新的 ECS 优化 AMI 作为基础
BASE_AMI=$(aws ssm get-parameter \
  --name "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id" \
  --region "$REGION" \
  --query "Parameter.Value" \
  --output text)

echo "基础 AMI: $BASE_AMI"

# Step 2: 创建临时实例
echo ""
echo "[步骤 1] 启动临时实例..."

# 获取默认 VPC 的 subnet
SUBNET_ID=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=default-for-az,Values=true" \
  --query "Subnets[0].SubnetId" \
  --output text)

# 获取 IAM Instance Profile
INSTANCE_PROFILE=$(aws iam list-instance-profiles \
  --query "InstanceProfiles[?contains(InstanceProfileName, '${PROJECT_NAME}')].InstanceProfileName | [0]" \
  --output text)

if [ -z "$INSTANCE_PROFILE" ] || [ "$INSTANCE_PROFILE" = "None" ]; then
  echo "错误: 找不到 Instance Profile，请先运行 terraform apply"
  exit 1
fi

INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$BASE_AMI" \
  --instance-type "t3.small" \
  --subnet-id "$SUBNET_ID" \
  --iam-instance-profile "Name=$INSTANCE_PROFILE" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=golden-ami-builder}]" \
  --region "$REGION" \
  --query "Instances[0].InstanceId" \
  --output text)

echo "临时实例: $INSTANCE_ID"

# 等待实例运行
echo "等待实例启动..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "实例已运行"

# 等待 SSM Agent 就绪
echo "等待 SSM Agent 就绪..."
sleep 30

# Step 3: 在实例上预拉取镜像
echo ""
echo "[步骤 2] 预拉取 Docker 镜像..."

# ECR 登录并拉取镜像
PULL_COMMANDS="
set -ex
# ECR 登录
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin 585891120210.dkr.ecr.$REGION.amazonaws.com

# 拉取镜像
"

for IMAGE in "${IMAGES[@]}"; do
  PULL_COMMANDS+="docker pull $IMAGE
"
done

PULL_COMMANDS+="
# 列出已拉取的镜像
docker images

# 清理缓存
docker system prune -f
"

COMMAND_ID=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$INSTANCE_ID" \
  --parameters "commands=[\"$PULL_COMMANDS\"]" \
  --timeout-seconds 600 \
  --region "$REGION" \
  --query "Command.CommandId" \
  --output text)

echo "SSM 命令: $COMMAND_ID"

# 等待命令完成
echo "等待镜像拉取完成..."
aws ssm wait command-executed \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION" 2>/dev/null || true

# 获取命令输出
aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --region "$REGION" \
  --query "StandardOutputContent" \
  --output text

# Step 4: 停止实例
echo ""
echo "[步骤 3] 停止实例..."
aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "实例已停止"

# Step 5: 创建 AMI
echo ""
echo "[步骤 4] 创建 Golden AMI..."
AMI_ID=$(aws ec2 create-image \
  --instance-id "$INSTANCE_ID" \
  --name "$AMI_NAME" \
  --description "Golden AMI with pre-pulled Docker images" \
  --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=$AMI_NAME},{Key=Project,Value=$PROJECT_NAME}]" \
  --region "$REGION" \
  --query "ImageId" \
  --output text)

echo "Golden AMI: $AMI_ID"
echo "AMI 名称: $AMI_NAME"

# 等待 AMI 创建完成
echo "等待 AMI 创建完成 (可能需要几分钟)..."
aws ec2 wait image-available --image-ids "$AMI_ID" --region "$REGION"
echo "AMI 创建完成!"

# Step 6: 清理临时实例
echo ""
echo "[步骤 5] 清理临时实例..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
echo "临时实例已终止"

# Step 7: 输出结果
echo ""
echo "=============================================="
echo "  Golden AMI 构建完成"
echo "=============================================="
echo ""
echo "AMI ID: $AMI_ID"
echo "AMI 名称: $AMI_NAME"
echo ""
echo "使用方法:"
echo "在 terraform.tfvars 中添加:"
echo ""
echo "  golden_ami_id = \"$AMI_ID\""
echo ""
echo "或者更新 Launch Template:"
echo ""
echo "  aws ec2 create-launch-template-version \\"
echo "    --launch-template-name ${PROJECT_NAME}-ecs- \\"
echo "    --source-version '\$Latest' \\"
echo "    --launch-template-data '{\"ImageId\":\"$AMI_ID\"}' \\"
echo "    --region $REGION"
echo ""
