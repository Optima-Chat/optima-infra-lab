#!/bin/bash
# 测试 Fargate 冷启动时间

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Fargate Cold Start Test${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 检查环境变量
if [ -z "$ECS_CLUSTER_NAME" ] || [ -z "$ECS_TASK_DEFINITION" ]; then
    echo -e "${YELLOW}Loading environment from terraform...${NC}"
    cd "$SCRIPT_DIR/../terraform"
    eval "$(terraform output -raw env_exports 2>/dev/null)"
fi

if [ -z "$ECS_CLUSTER_NAME" ]; then
    echo -e "${RED}ERROR: ECS_CLUSTER_NAME not set${NC}"
    exit 1
fi

echo "Cluster: $ECS_CLUSTER_NAME"
echo "Task Definition: $ECS_TASK_DEFINITION"
echo ""

# 获取网络配置
echo -e "${YELLOW}Getting network configuration...${NC}"
cd "$SCRIPT_DIR/../terraform"
SUBNET_IDS=$(terraform output -json private_subnet_ids 2>/dev/null | jq -r 'join(",")' || echo "")
SECURITY_GROUP_ID=$(terraform output -raw security_group_tasks_id 2>/dev/null || echo "")

if [ -z "$SUBNET_IDS" ] || [ -z "$SECURITY_GROUP_ID" ]; then
    echo -e "${RED}ERROR: Could not get network configuration from terraform${NC}"
    exit 1
fi

echo "Subnets: $SUBNET_IDS"
echo "Security Group: $SECURITY_GROUP_ID"
echo ""

# 记录开始时间
echo -e "${YELLOW}Starting Fargate task...${NC}"
START_TIME=$(date +%s%N)

# 启动任务
TASK_ARN=$(aws ecs run-task \
    --cluster "$ECS_CLUSTER_NAME" \
    --task-definition "$ECS_TASK_DEFINITION" \
    --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_IDS],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=DISABLED}" \
    --query 'tasks[0].taskArn' \
    --output text)

echo "Task ARN: $TASK_ARN"
echo ""

# 等待任务进入 RUNNING 状态
echo -e "${YELLOW}Waiting for task to reach RUNNING state...${NC}"
aws ecs wait tasks-running --cluster "$ECS_CLUSTER_NAME" --tasks "$TASK_ARN"

# 记录 RUNNING 时间
RUNNING_TIME=$(date +%s%N)
RUNNING_LATENCY=$(( (RUNNING_TIME - START_TIME) / 1000000 ))

echo -e "${GREEN}Task is RUNNING!${NC}"
echo ""

# 停止任务（清理）
echo -e "${YELLOW}Stopping task...${NC}"
aws ecs stop-task --cluster "$ECS_CLUSTER_NAME" --task "$TASK_ARN" --reason "Cold start test completed" > /dev/null

# 输出结果
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Cold Start Test Results${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Task ARN:        $TASK_ARN"
echo "Cold Start Time: ${RUNNING_LATENCY}ms"
echo ""

if [ "$RUNNING_LATENCY" -lt 40000 ]; then
    echo -e "${GREEN}PASS: Cold start time < 40s${NC}"
else
    echo -e "${RED}FAIL: Cold start time >= 40s${NC}"
fi
