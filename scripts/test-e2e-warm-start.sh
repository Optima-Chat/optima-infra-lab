#!/bin/bash
# 端到端测试：从 Warm Pool 启动 EC2 + ECS 任务
# 模拟：预热池满 → 用户需要新实例 → 从 Warm Pool 启动

set -e

REGION="${AWS_REGION:-ap-southeast-1}"
CLUSTER_NAME="fargate-warm-pool-test"
ASG_NAME="fargate-warm-pool-test-ecs-asg"
SERVICE_NAME="fargate-warm-pool-test-ec2-service"

echo "=========================================="
echo "  端到端 Warm Pool 启动测试"
echo "=========================================="
echo ""

# 1. 获取当前状态
echo "--- 当前状态 ---"
CURRENT_ASG=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].DesiredCapacity' \
  --output text)
echo "ASG Desired Capacity: $CURRENT_ASG"

CURRENT_ECS=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$REGION" \
  --query 'services[0].desiredCount' \
  --output text)
echo "ECS Service Desired Count: $CURRENT_ECS"

WARM_COUNT=$(aws autoscaling describe-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --region "$REGION" \
  --query 'Instances | length(@)' \
  --output text 2>/dev/null || echo "0")
echo "Warm Pool 实例数: $WARM_COUNT"

if [ "$WARM_COUNT" -eq 0 ]; then
  echo "⚠️  没有预热实例，退出"
  exit 1
fi

# 显示 Warm Pool 实例状态
aws autoscaling describe-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --region "$REGION" \
  --query 'Instances[*].{InstanceId:InstanceId,State:LifecycleState}' 2>/dev/null

echo ""
echo "--- 开始测试 ---"
START_TIME=$(date +%s%3N)
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S.%3N')"

# 2. 同时增加 ASG 和 ECS Service 的 desired count
NEW_ASG=$((CURRENT_ASG + 1))
NEW_ECS=$((CURRENT_ECS + 1))
echo "增加容量: ASG $CURRENT_ASG→$NEW_ASG, ECS $CURRENT_ECS→$NEW_ECS"

# 增加 ASG（触发从 Warm Pool 启动）
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity "$NEW_ASG" \
  --region "$REGION"

# 增加 ECS Service（触发任务调度）
aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --desired-count "$NEW_ECS" \
  --region "$REGION" \
  --query 'service.desiredCount' \
  --output text > /dev/null

echo ""
echo "等待 EC2 实例从 Warm Pool 启动..."
EC2_READY=false
for i in {1..120}; do
  IN_SERVICE=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`] | length(@)' \
    --output text)

  if [ "$IN_SERVICE" -ge "$NEW_ASG" ]; then
    EC2_READY_TIME=$(date +%s%3N)
    EC2_READY=true
    echo -e "\n✓ EC2 InService: $((EC2_READY_TIME - START_TIME))ms"
    break
  fi

  echo -ne "\r  等待中... ${i}s (InService: $IN_SERVICE / $NEW_ASG)"
  sleep 1
done

if [ "$EC2_READY" = false ]; then
  echo -e "\n✗ EC2 启动超时"
  exit 1
fi

echo ""
echo "等待 ECS 任务启动..."
TASK_READY=false
for i in {1..120}; do
  RUNNING=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].runningCount' \
    --output text)

  if [ "$RUNNING" -ge "$NEW_ECS" ]; then
    TASK_READY_TIME=$(date +%s%3N)
    TASK_READY=true
    echo -e "\n✓ ECS 任务运行: $((TASK_READY_TIME - START_TIME))ms"
    break
  fi

  echo -ne "\r  等待中... ${i}s (Running: $RUNNING / $NEW_ECS)"
  sleep 1
done

if [ "$TASK_READY" = false ]; then
  echo -e "\n✗ ECS 任务启动超时"
fi

# 总结
echo ""
echo "=========================================="
echo "  测试结果"
echo "=========================================="
echo "EC2 从 Warm Pool 启动 (Stopped→InService): $((EC2_READY_TIME - START_TIME))ms"
if [ "$TASK_READY" = true ]; then
  echo "ECS 任务启动 (总时间): $((TASK_READY_TIME - START_TIME))ms"
  echo "任务调度时间 (EC2 就绪后): $((TASK_READY_TIME - EC2_READY_TIME))ms"
fi
echo ""

# 恢复
echo "恢复原始配置: ASG→$CURRENT_ASG, ECS→$CURRENT_ECS"
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity "$CURRENT_ASG" \
  --region "$REGION"
aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --desired-count "$CURRENT_ECS" \
  --region "$REGION" \
  --query 'service.desiredCount' \
  --output text > /dev/null
echo "完成"
