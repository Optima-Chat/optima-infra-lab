#!/bin/bash
# 构建并推送测试镜像到 ECR

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Fargate Warm Pool Test - Deploy${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 检查环境变量
if [ -z "$ECR_REPOSITORY_URL" ]; then
    echo -e "${YELLOW}ECR_REPOSITORY_URL not set, trying to get from terraform...${NC}"

    cd "$PROJECT_DIR/terraform"
    ECR_REPOSITORY_URL=$(terraform output -raw ecr_repository_url 2>/dev/null || echo "")

    if [ -z "$ECR_REPOSITORY_URL" ]; then
        echo -e "${RED}ERROR: ECR_REPOSITORY_URL not found${NC}"
        echo "Please run 'terraform apply' first or set ECR_REPOSITORY_URL"
        exit 1
    fi
fi

echo "ECR Repository: $ECR_REPOSITORY_URL"
echo ""

# 获取 AWS 账号和区域
AWS_ACCOUNT_ID=$(echo "$ECR_REPOSITORY_URL" | cut -d'.' -f1)
AWS_REGION=$(echo "$ECR_REPOSITORY_URL" | cut -d'.' -f4)

echo "AWS Account: $AWS_ACCOUNT_ID"
echo "AWS Region: $AWS_REGION"
echo ""

# 登录 ECR
echo -e "${YELLOW}Logging in to ECR...${NC}"
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# 构建镜像
echo ""
echo -e "${YELLOW}Building Docker image...${NC}"
cd "$PROJECT_DIR/docker"
docker build -t fargate-warm-pool-test:latest .

# 标记镜像
echo ""
echo -e "${YELLOW}Tagging image...${NC}"
docker tag fargate-warm-pool-test:latest "$ECR_REPOSITORY_URL:latest"

# 推送镜像
echo ""
echo -e "${YELLOW}Pushing image to ECR...${NC}"
docker push "$ECR_REPOSITORY_URL:latest"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Deploy completed!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Image: $ECR_REPOSITORY_URL:latest"
echo ""
echo "Next steps:"
echo "  1. Update ECS service to use new image:"
echo "     aws ecs update-service --cluster fargate-warm-pool-test --service fargate-warm-pool-test-warm-pool --force-new-deployment"
echo "  2. Watch task logs:"
echo "     aws logs tail /ecs/fargate-warm-pool-test --follow"
