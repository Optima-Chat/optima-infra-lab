#!/bin/bash
# 测试 EC2 冷启动时间（作为对比）
# 启动全新实例，不使用 Warm Pool

set -e

REGION="${AWS_REGION:-ap-southeast-1}"
CLUSTER_NAME="fargate-warm-pool-test"
ASG_NAME="fargate-warm-pool-test-ecs-asg"

echo "=========================================="
echo "  EC2 冷启动时间测试"
echo "=========================================="
echo ""
echo "此测试会启动一个新的 EC2 实例（绕过 Warm Pool），"
echo "用于测量完全冷启动的时间作为对比。"
echo ""

# 获取 Launch Template
LAUNCH_TEMPLATE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].LaunchTemplate.LaunchTemplateId' \
  --output text)

LAUNCH_TEMPLATE_VERSION=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].LaunchTemplate.Version' \
  --output text)

# 获取子网
SUBNET_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].VPCZoneIdentifier' \
  --output text | cut -d',' -f1)

echo "Launch Template: $LAUNCH_TEMPLATE_ID (version: $LAUNCH_TEMPLATE_VERSION)"
echo "Subnet: $SUBNET_ID"

# 记录开始时间
START_TIME=$(date +%s%3N)
echo ""
echo "--- 开始冷启动测试 ---"
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S.%3N')"

# 直接启动 EC2 实例（不通过 ASG，绕过 Warm Pool）
echo ""
echo "启动新 EC2 实例..."
INSTANCE_ID=$(aws ec2 run-instances \
  --launch-template "LaunchTemplateId=$LAUNCH_TEMPLATE_ID,Version=$LAUNCH_TEMPLATE_VERSION" \
  --subnet-id "$SUBNET_ID" \
  --region "$REGION" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "Instance ID: $INSTANCE_ID"

# 等待实例 running
echo ""
echo "等待实例 running..."
TIMEOUT=300
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  STATE=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "pending")

  if [ "$STATE" = "running" ]; then
    RUNNING_TIME=$(date +%s%3N)
    break
  fi

  sleep 1
  ELAPSED=$((ELAPSED + 1))
  echo -ne "\r等待中... ${ELAPSED}s (状态: $STATE)"
done

echo ""
RUNNING_DURATION=$((RUNNING_TIME - START_TIME))
echo "✓ EC2 实例 running: ${RUNNING_DURATION}ms"

# 等待实例通过状态检查
echo ""
echo "等待实例状态检查..."
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  STATUS=$(aws ec2 describe-instance-status \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'InstanceStatuses[0].InstanceStatus.Status' \
    --output text 2>/dev/null || echo "initializing")

  if [ "$STATUS" = "ok" ]; then
    STATUS_OK_TIME=$(date +%s%3N)
    break
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
  echo -ne "\r等待中... ${ELAPSED}s (状态检查: $STATUS)"
done

echo ""
if [ -n "$STATUS_OK_TIME" ]; then
  STATUS_DURATION=$((STATUS_OK_TIME - START_TIME))
  echo "✓ 实例状态检查通过: ${STATUS_DURATION}ms"
fi

# 等待 ECS Agent 注册到集群
echo ""
echo "等待 ECS Agent 注册..."
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  CONTAINER_INSTANCE=$(aws ecs list-container-instances \
    --cluster "$CLUSTER_NAME" \
    --filter "ec2InstanceId==$INSTANCE_ID" \
    --region "$REGION" \
    --query 'containerInstanceArns[0]' \
    --output text 2>/dev/null || echo "None")

  if [ "$CONTAINER_INSTANCE" != "None" ] && [ -n "$CONTAINER_INSTANCE" ]; then
    ECS_READY_TIME=$(date +%s%3N)
    break
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
  echo -ne "\r等待中... ${ELAPSED}s"
done

echo ""
if [ -n "$ECS_READY_TIME" ]; then
  ECS_DURATION=$((ECS_READY_TIME - START_TIME))
  echo "✓ ECS Agent 注册: ${ECS_DURATION}ms"
  echo "Container Instance: $CONTAINER_INSTANCE"
fi

# 总结
TOTAL_DURATION=$(($(date +%s%3N) - START_TIME))
echo ""
echo "=========================================="
echo "  冷启动测试结果"
echo "=========================================="
echo "EC2 实例 running:      ${RUNNING_DURATION}ms (~$((RUNNING_DURATION/1000))s)"
if [ -n "$STATUS_DURATION" ]; then
  echo "实例状态检查通过:      ${STATUS_DURATION}ms (~$((STATUS_DURATION/1000))s)"
fi
if [ -n "$ECS_DURATION" ]; then
  echo "ECS Agent 注册:        ${ECS_DURATION}ms (~$((ECS_DURATION/1000))s)"
fi
echo "总耗时:                ${TOTAL_DURATION}ms (~$((TOTAL_DURATION/1000))s)"
echo ""

# 清理：终止测试实例
echo "清理：终止测试实例 $INSTANCE_ID ..."
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" > /dev/null

echo "完成"
