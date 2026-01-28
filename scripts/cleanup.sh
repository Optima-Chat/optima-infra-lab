#!/bin/bash
# 清理测试资源

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Fargate Warm Pool Test - Cleanup${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 加载环境变量
echo -e "${YELLOW}Loading environment from terraform...${NC}"
cd "$SCRIPT_DIR/../terraform"
eval "$(terraform output -raw env_exports 2>/dev/null)" || true

# 停止所有运行中的任务
if [ -n "$ECS_CLUSTER_NAME" ]; then
    echo ""
    echo -e "${YELLOW}Stopping all running tasks...${NC}"

    TASK_ARNS=$(aws ecs list-tasks --cluster "$ECS_CLUSTER_NAME" --query 'taskArns[]' --output text 2>/dev/null || echo "")

    if [ -n "$TASK_ARNS" ]; then
        for TASK_ARN in $TASK_ARNS; do
            echo "Stopping: $TASK_ARN"
            aws ecs stop-task --cluster "$ECS_CLUSTER_NAME" --task "$TASK_ARN" --reason "Cleanup" > /dev/null 2>&1 || true
        done
        echo "All tasks stopped"
    else
        echo "No tasks running"
    fi
fi

# 缩容 ECS Service
if [ -n "$ECS_CLUSTER_NAME" ] && [ -n "$ECS_SERVICE_NAME" ]; then
    echo ""
    echo -e "${YELLOW}Scaling down ECS service to 0...${NC}"
    aws ecs update-service \
        --cluster "$ECS_CLUSTER_NAME" \
        --service "$ECS_SERVICE_NAME" \
        --desired-count 0 > /dev/null 2>&1 || true
    echo "Service scaled to 0"
fi

# 删除 ECR 镜像
if [ -n "$ECR_REPOSITORY_URL" ]; then
    echo ""
    echo -e "${YELLOW}Deleting ECR images...${NC}"
    REPO_NAME=$(echo "$ECR_REPOSITORY_URL" | cut -d'/' -f2)

    aws ecr batch-delete-image \
        --repository-name "$REPO_NAME" \
        --image-ids imageTag=latest > /dev/null 2>&1 || true
    echo "Images deleted"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Cleanup completed!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "To destroy all infrastructure:"
echo "  cd terraform && terraform destroy"
