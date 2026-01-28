#!/bin/bash
# 测试不同 Warm Pool 状态的唤醒时间
# Usage: ./test-warm-pool-state.sh [Running|Hibernated|Stopped]

set -e

REGION="${AWS_REGION:-ap-southeast-1}"
ASG_NAME="fargate-warm-pool-test-ecs-asg"
CLUSTER_NAME="fargate-warm-pool-test"
STATE="${1:-Running}"  # 默认测试 Running 状态

# 颜色
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo "=============================================="
echo "  Warm Pool 状态唤醒时间测试"
echo "=============================================="
echo -e "测试状态: ${CYAN}${STATE}${NC}"
echo ""

# 1. 设置 Warm Pool 状态
echo "[步骤 1] 配置 Warm Pool 状态为 ${STATE}..."
aws autoscaling put-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --min-size 1 \
  --max-group-prepared-capacity 3 \
  --pool-state "$STATE" \
  --instance-reuse-policy '{"ReuseOnScaleIn":true}' \
  --region "$REGION"

echo "等待 Warm Pool 实例准备..."
sleep 10

# 2. 确认有实例在 Warm Pool 中
WARM_COUNT=0
ATTEMPTS=0
MAX_ATTEMPTS=60

while [ "$WARM_COUNT" -eq 0 ] && [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
  WARM_COUNT=$(aws autoscaling describe-warm-pool \
    --auto-scaling-group-name "$ASG_NAME" \
    --region "$REGION" \
    --query 'length(Instances)' \
    --output text 2>/dev/null || echo "0")

  if [ "$WARM_COUNT" -eq 0 ]; then
    sleep 5
    ATTEMPTS=$((ATTEMPTS + 1))
    echo -ne "\r  等待 Warm Pool 实例... ${ATTEMPTS}*5s"
  fi
done
echo ""

if [ "$WARM_COUNT" -eq 0 ]; then
  echo "错误: Warm Pool 中没有实例，请先确保有实例"
  exit 1
fi

echo -e "${GREEN}[✓]${NC} Warm Pool 中有 ${WARM_COUNT} 个实例 (状态: ${STATE})"

# 获取 Warm Pool 实例 ID
WARM_INSTANCE=$(aws autoscaling describe-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --region "$REGION" \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "  Warm Pool 实例: $WARM_INSTANCE"

# 3. 获取当前 Desired Capacity
CURRENT_DESIRED=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].DesiredCapacity' \
  --output text)

echo ""
echo "[步骤 2] 当前 Desired Capacity: $CURRENT_DESIRED"

# 4. 开始计时
NEW_DESIRED=$((CURRENT_DESIRED + 1))
T_START=$(date +%s%3N)

echo ""
echo "=============================================="
echo "  开始唤醒测试 (${STATE})"
echo "=============================================="
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "增加 Desired Capacity: $CURRENT_DESIRED → $NEW_DESIRED"
echo ""

aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity "$NEW_DESIRED" \
  --region "$REGION"

# 5. 等待实例进入 InService
echo "[阶段 1] 等待实例从 Warm Pool 唤醒..."
TIMEOUT=120
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  LIFECYCLE=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query "AutoScalingGroups[0].Instances[?InstanceId=='$WARM_INSTANCE'].LifecycleState" \
    --output text 2>/dev/null || echo "Warmed")

  if [ "$LIFECYCLE" = "InService" ]; then
    T_INSERVICE=$(date +%s%3N)
    DURATION=$((T_INSERVICE - T_START))
    echo ""
    echo -e "${GREEN}[✓]${NC} 实例 InService! 耗时: ${DURATION}ms (~$((DURATION/1000))s)"
    break
  fi

  sleep 1
  ELAPSED=$((ELAPSED + 1))
  echo -ne "\r  等待中... ${ELAPSED}s (状态: $LIFECYCLE)"
done
echo ""

if [ "$LIFECYCLE" != "InService" ]; then
  echo "错误: 等待超时"
  exit 1
fi

# 6. 等待 ECS Agent 注册
echo ""
echo "[阶段 2] 等待 ECS Agent 注册..."
ELAPSED=0

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  CONTAINER_INSTANCE=$(aws ecs list-container-instances \
    --cluster "$CLUSTER_NAME" \
    --filter "ec2InstanceId==$WARM_INSTANCE" \
    --region "$REGION" \
    --query 'containerInstanceArns[0]' \
    --output text 2>/dev/null || echo "None")

  if [ "$CONTAINER_INSTANCE" != "None" ] && [ -n "$CONTAINER_INSTANCE" ]; then
    T_ECS=$(date +%s%3N)
    DURATION=$((T_ECS - T_START))
    echo -e "${GREEN}[✓]${NC} ECS Agent 注册! 耗时: ${DURATION}ms (~$((DURATION/1000))s)"
    break
  fi

  sleep 1
  ELAPSED=$((ELAPSED + 1))
  echo -ne "\r  等待中... ${ELAPSED}s"
done
echo ""

# 7. 汇总结果
T_END=$(date +%s%3N)
TOTAL=$((T_END - T_START))

echo ""
echo "=============================================="
echo "  测试结果汇总"
echo "=============================================="
echo ""
echo "| 阶段 | 耗时 |"
echo "|------|------|"
[ -n "$T_INSERVICE" ] && echo "| ASG InService | $((($T_INSERVICE - $T_START)/1000))s |"
[ -n "$T_ECS" ] && echo "| ECS Agent 注册 | $((($T_ECS - $T_START)/1000))s |"
echo ""
echo -e "Warm Pool 状态: ${CYAN}${STATE}${NC}"
echo -e "总唤醒时间: ${GREEN}$((TOTAL/1000))s${NC}"
echo ""

# 8. 恢复配置
echo "[恢复] 恢复 Desired Capacity: $NEW_DESIRED → $CURRENT_DESIRED"
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$ASG_NAME" \
  --desired-capacity "$CURRENT_DESIRED" \
  --region "$REGION"

echo ""
echo "测试完成!"
echo ""
echo "提示: 比较不同状态的唤醒时间:"
echo "  ./test-warm-pool-state.sh Running      # 预计 ~1-5s"
echo "  ./test-warm-pool-state.sh Hibernated   # 预计 ~15-20s"
echo "  ./test-warm-pool-state.sh Stopped      # 预计 ~30-40s"
