#!/bin/bash
# 测试 EC2 冷启动时间分解
# 详细测量每个阶段的耗时

set -e

REGION="${AWS_REGION:-ap-southeast-1}"
ASG_NAME="fargate-warm-pool-test-ecs-asg"
CLUSTER_NAME="fargate-warm-pool-test"

echo "=============================================="
echo "  EC2 冷启动时间分解测试"
echo "=============================================="

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_time() {
  local label=$1
  local start=$2
  local end=$3
  local duration=$((end - start))
  echo -e "${GREEN}[✓]${NC} $label: ${duration}ms (~$((duration/1000))s)"
}

# 1. 准备: 暂停 Warm Pool，确保是真正的冷启动
echo ""
echo "[准备] 暂停 Warm Pool 自动补充..."
aws autoscaling put-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --min-size 0 \
  --max-group-prepared-capacity 3 \
  --pool-state Hibernated \
  --region "$REGION" 2>/dev/null || true

# 清空 Warm Pool
WARM_INSTANCES=$(aws autoscaling describe-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --region "$REGION" \
  --query 'Instances[*].InstanceId' \
  --output text 2>/dev/null || echo "")

if [ -n "$WARM_INSTANCES" ]; then
  echo "[准备] 清空 Warm Pool..."
  for INST in $WARM_INSTANCES; do
    aws ec2 terminate-instances --instance-ids "$INST" --region "$REGION" > /dev/null 2>&1 || true
  done
  sleep 5
fi

# 2. 获取当前状态
CURRENT_DESIRED=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].DesiredCapacity' \
  --output text)

CURRENT_INSERVICE=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
  --output text)

echo ""
echo "当前 Desired Capacity: $CURRENT_DESIRED"
echo "当前 InService 实例: $CURRENT_INSERVICE"

# 3. 开始测试
NEW_DESIRED=$((CURRENT_DESIRED + 1))
T_START=$(date +%s%3N)

echo ""
echo "=============================================="
echo "  开始冷启动测试"
echo "=============================================="
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "增加 Desired Capacity: $CURRENT_DESIRED → $NEW_DESIRED"
echo ""

aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity "$NEW_DESIRED" \
  --region "$REGION"

# 4. 监控各阶段

# 4.1 等待新实例出现 (Pending)
echo "[阶段 1] 等待新实例创建..."
TIMEOUT=300
ELAPSED=0
NEW_INSTANCE=""

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  INSTANCES=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
    --output text)

  for INST in $INSTANCES; do
    if [[ ! " $CURRENT_INSERVICE " =~ " $INST " ]]; then
      NEW_INSTANCE="$INST"
      T_INSTANCE_CREATED=$(date +%s%3N)
      log_time "新实例创建" $T_START $T_INSTANCE_CREATED
      echo "  Instance ID: $NEW_INSTANCE"
      break 2
    fi
  done

  sleep 1
  ELAPSED=$((ELAPSED + 1))
  echo -ne "\r  等待中... ${ELAPSED}s"
done
echo ""

if [ -z "$NEW_INSTANCE" ]; then
  echo "错误: 未能找到新实例"
  exit 1
fi

# 4.2 等待实例 Running
echo ""
echo "[阶段 2] 等待实例 Running..."
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  STATE=$(aws ec2 describe-instances \
    --instance-ids "$NEW_INSTANCE" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "pending")

  if [ "$STATE" = "running" ]; then
    T_RUNNING=$(date +%s%3N)
    log_time "实例 Running" $T_START $T_RUNNING
    break
  fi

  sleep 1
  ELAPSED=$((ELAPSED + 1))
  echo -ne "\r  等待中... ${ELAPSED}s (状态: $STATE)"
done
echo ""

# 4.3 等待状态检查通过
echo ""
echo "[阶段 3] 等待状态检查..."
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  INSTANCE_STATUS=$(aws ec2 describe-instance-status \
    --instance-ids "$NEW_INSTANCE" \
    --region "$REGION" \
    --query 'InstanceStatuses[0].InstanceStatus.Status' \
    --output text 2>/dev/null || echo "initializing")

  SYSTEM_STATUS=$(aws ec2 describe-instance-status \
    --instance-ids "$NEW_INSTANCE" \
    --region "$REGION" \
    --query 'InstanceStatuses[0].SystemStatus.Status' \
    --output text 2>/dev/null || echo "initializing")

  if [ "$INSTANCE_STATUS" = "ok" ] && [ "$SYSTEM_STATUS" = "ok" ]; then
    T_STATUS_OK=$(date +%s%3N)
    log_time "状态检查通过" $T_START $T_STATUS_OK
    break
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
  echo -ne "\r  等待中... ${ELAPSED}s (instance: $INSTANCE_STATUS, system: $SYSTEM_STATUS)"
done
echo ""

# 4.4 等待 ECS Agent 注册
echo ""
echo "[阶段 4] 等待 ECS Agent 注册..."
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  CONTAINER_INSTANCE=$(aws ecs list-container-instances \
    --cluster "$CLUSTER_NAME" \
    --filter "ec2InstanceId==$NEW_INSTANCE" \
    --region "$REGION" \
    --query 'containerInstanceArns[0]' \
    --output text 2>/dev/null || echo "None")

  if [ "$CONTAINER_INSTANCE" != "None" ] && [ -n "$CONTAINER_INSTANCE" ]; then
    T_ECS_REGISTERED=$(date +%s%3N)
    log_time "ECS Agent 注册" $T_START $T_ECS_REGISTERED
    break
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
  echo -ne "\r  等待中... ${ELAPSED}s"
done
echo ""

# 4.5 等待 ASG InService
echo ""
echo "[阶段 5] 等待 ASG InService..."
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  LIFECYCLE=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query "AutoScalingGroups[0].Instances[?InstanceId=='$NEW_INSTANCE'].LifecycleState" \
    --output text 2>/dev/null || echo "Pending")

  if [ "$LIFECYCLE" = "InService" ]; then
    T_INSERVICE=$(date +%s%3N)
    log_time "ASG InService" $T_START $T_INSERVICE
    break
  fi

  sleep 1
  ELAPSED=$((ELAPSED + 1))
  echo -ne "\r  等待中... ${ELAPSED}s (状态: $LIFECYCLE)"
done
echo ""

# 5. 获取 User Data 执行日志 (通过 SSM)
echo ""
echo "[阶段 6] 获取启动日志..."

# 等待 SSM Agent 就绪
sleep 5

BOOT_LOG=$(aws ssm send-command \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$NEW_INSTANCE" \
  --parameters 'commands=["cat /var/log/boot-timing.log 2>/dev/null || echo \"No boot timing log\""]' \
  --region "$REGION" \
  --query 'Command.CommandId' \
  --output text 2>/dev/null || echo "")

if [ -n "$BOOT_LOG" ]; then
  sleep 3
  BOOT_TIMING=$(aws ssm get-command-invocation \
    --command-id "$BOOT_LOG" \
    --instance-id "$NEW_INSTANCE" \
    --region "$REGION" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null || echo "无法获取")

  echo "启动时间日志:"
  echo "$BOOT_TIMING"
fi

# 6. 汇总
T_END=$(date +%s%3N)
TOTAL=$((T_END - T_START))

echo ""
echo "=============================================="
echo "  冷启动时间分解汇总"
echo "=============================================="
echo ""
echo "| 阶段 | 累计时间 | 阶段耗时 |"
echo "|------|---------|---------|"

[ -n "$T_INSTANCE_CREATED" ] && echo "| 实例创建 | $((($T_INSTANCE_CREATED - $T_START)/1000))s | $((($T_INSTANCE_CREATED - $T_START)/1000))s |"

if [ -n "$T_RUNNING" ]; then
  PREV=${T_INSTANCE_CREATED:-$T_START}
  echo "| Running | $((($T_RUNNING - $T_START)/1000))s | $((($T_RUNNING - $PREV)/1000))s |"
fi

if [ -n "$T_STATUS_OK" ]; then
  PREV=${T_RUNNING:-$T_START}
  echo "| 状态检查 | $((($T_STATUS_OK - $T_START)/1000))s | $((($T_STATUS_OK - $PREV)/1000))s |"
fi

if [ -n "$T_ECS_REGISTERED" ]; then
  PREV=${T_STATUS_OK:-$T_START}
  echo "| ECS 注册 | $((($T_ECS_REGISTERED - $T_START)/1000))s | $((($T_ECS_REGISTERED - $PREV)/1000))s |"
fi

if [ -n "$T_INSERVICE" ]; then
  PREV=${T_ECS_REGISTERED:-$T_START}
  echo "| InService | $((($T_INSERVICE - $T_START)/1000))s | $((($T_INSERVICE - $PREV)/1000))s |"
fi

echo ""
echo "总耗时: $((TOTAL/1000))s"

# 7. 恢复配置
echo ""
echo "=============================================="
echo "  恢复配置"
echo "=============================================="

echo "恢复 Desired Capacity: $NEW_DESIRED → $CURRENT_DESIRED"
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity "$CURRENT_DESIRED" \
  --region "$REGION"

echo "恢复 Warm Pool min_size: 2"
aws autoscaling put-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --min-size 2 \
  --max-group-prepared-capacity 3 \
  --pool-state Hibernated \
  --region "$REGION"

echo ""
echo "完成"
