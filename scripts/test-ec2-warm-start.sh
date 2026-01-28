#!/bin/bash
# 测试 EC2 Warm Pool 启动时间
# 从 Stopped 状态启动预热实例

set -e

REGION="${AWS_REGION:-ap-southeast-1}"
CLUSTER_NAME="fargate-warm-pool-test"
ASG_NAME="fargate-warm-pool-test-ecs-asg"
SERVICE_NAME="fargate-warm-pool-test-ec2-service"

echo "=========================================="
echo "  EC2 Warm Pool 启动时间测试"
echo "=========================================="

# 获取当前 ASG 状态
echo ""
echo "--- 当前 ASG 状态 ---"
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize}' \
  --output table

# 获取 Warm Pool 状态
echo ""
echo "--- Warm Pool 状态 ---"
WARM_POOL_INFO=$(aws autoscaling describe-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --region "$REGION" 2>/dev/null || echo "{}")

WARM_INSTANCES=$(echo "$WARM_POOL_INFO" | jq -r '.Instances[]?.InstanceId // empty' 2>/dev/null | wc -l)
echo "Warm Pool 实例数: $WARM_INSTANCES"

if [ "$WARM_INSTANCES" -eq 0 ]; then
  echo ""
  echo "⚠️  Warm Pool 为空，需要先预热实例"
  echo "运行: aws autoscaling set-desired-capacity --auto-scaling-group-name $ASG_NAME --desired-capacity 1"
  echo "等待实例启动并被放入 Warm Pool..."
  exit 1
fi

echo "$WARM_POOL_INFO" | jq '.Instances[] | {InstanceId, LifecycleState}' 2>/dev/null

# 获取当前运行的 ECS 任务数
CURRENT_TASKS=$(aws ecs list-tasks \
  --cluster "$CLUSTER_NAME" \
  --service-name "$SERVICE_NAME" \
  --region "$REGION" \
  --query 'taskArns | length(@)' \
  --output text 2>/dev/null || echo "0")
echo ""
echo "当前运行的 ECS 任务数: $CURRENT_TASKS"

# 记录开始时间
START_TIME=$(date +%s%3N)
echo ""
echo "--- 开始测试 ---"
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S.%3N')"

# 增加 desired capacity，触发从 Warm Pool 启动
CURRENT_DESIRED=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].DesiredCapacity' \
  --output text)

NEW_DESIRED=$((CURRENT_DESIRED + 1))
echo "增加 ASG Desired Capacity: $CURRENT_DESIRED -> $NEW_DESIRED"

aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity "$NEW_DESIRED" \
  --region "$REGION"

# 等待新实例进入 InService 状态
echo ""
echo "等待实例从 Warm Pool 启动..."
INSTANCE_READY=false
TIMEOUT=120
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  INSTANCE_COUNT=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`] | length(@)' \
    --output text)

  if [ "$INSTANCE_COUNT" -ge "$NEW_DESIRED" ]; then
    INSTANCE_READY_TIME=$(date +%s%3N)
    INSTANCE_READY=true
    break
  fi

  sleep 1
  ELAPSED=$((ELAPSED + 1))
  echo -ne "\r等待中... ${ELAPSED}s (InService 实例: $INSTANCE_COUNT / $NEW_DESIRED)"
done

echo ""

if [ "$INSTANCE_READY" = true ]; then
  INSTANCE_DURATION=$((INSTANCE_READY_TIME - START_TIME))
  echo "✓ EC2 实例就绪: ${INSTANCE_DURATION}ms"
else
  echo "✗ EC2 实例启动超时 (${TIMEOUT}s)"
  exit 1
fi

# 等待 ECS 任务启动
echo ""
echo "等待 ECS 任务启动..."
TASK_READY=false
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  TASK_COUNT=$(aws ecs list-tasks \
    --cluster "$CLUSTER_NAME" \
    --service-name "$SERVICE_NAME" \
    --desired-status RUNNING \
    --region "$REGION" \
    --query 'taskArns | length(@)' \
    --output text 2>/dev/null || echo "0")

  if [ "$TASK_COUNT" -gt "$CURRENT_TASKS" ]; then
    TASK_READY_TIME=$(date +%s%3N)
    TASK_READY=true
    break
  fi

  sleep 1
  ELAPSED=$((ELAPSED + 1))
  echo -ne "\r等待中... ${ELAPSED}s (运行任务: $TASK_COUNT)"
done

echo ""

if [ "$TASK_READY" = true ]; then
  TASK_DURATION=$((TASK_READY_TIME - START_TIME))
  echo "✓ ECS 任务运行: ${TASK_DURATION}ms"
else
  echo "✗ ECS 任务启动超时 (${TIMEOUT}s)"
fi

# 总结
TOTAL_DURATION=$(($(date +%s%3N) - START_TIME))
echo ""
echo "=========================================="
echo "  测试结果"
echo "=========================================="
echo "EC2 实例启动 (Warm Pool → InService): ${INSTANCE_DURATION}ms"
if [ "$TASK_READY" = true ]; then
  echo "ECS 任务启动 (总时间): ${TASK_DURATION}ms"
fi
echo "总耗时: ${TOTAL_DURATION}ms"
echo ""

# 恢复 desired capacity
echo "恢复 ASG Desired Capacity: $NEW_DESIRED -> $CURRENT_DESIRED"
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity "$CURRENT_DESIRED" \
  --region "$REGION"

echo "完成"
