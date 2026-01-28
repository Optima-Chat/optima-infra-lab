#!/bin/bash
# 初始化 EC2 Warm Pool
# 启动实例让它们预热，然后进入 Warm Pool

set -e

REGION="${AWS_REGION:-ap-southeast-1}"
ASG_NAME="fargate-warm-pool-test-ecs-asg"
CLUSTER_NAME="fargate-warm-pool-test"

echo "=========================================="
echo "  初始化 EC2 Warm Pool"
echo "=========================================="

# 获取当前状态
echo ""
echo "--- 当前状态 ---"

ASG_INFO=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0]' 2>/dev/null)

if [ -z "$ASG_INFO" ] || [ "$ASG_INFO" = "null" ]; then
  echo "❌ ASG 不存在，请先运行 terraform apply"
  exit 1
fi

echo "$ASG_INFO" | jq '{DesiredCapacity, MinSize, MaxSize, Instances: (.Instances | length)}'

# 获取 Warm Pool 配置
WARM_POOL=$(aws autoscaling describe-warm-pool \
  --auto-scaling-group-name "$ASG_NAME" \
  --region "$REGION" 2>/dev/null || echo "{}")

WARM_POOL_SIZE=$(echo "$WARM_POOL" | jq '.WarmPoolConfiguration.MinSize // 0')
WARM_INSTANCES=$(echo "$WARM_POOL" | jq '.Instances | length')

echo ""
echo "Warm Pool 配置:"
echo "  - Min Size: $WARM_POOL_SIZE"
echo "  - 当前实例数: $WARM_INSTANCES"

if [ "$WARM_INSTANCES" -ge "$WARM_POOL_SIZE" ] && [ "$WARM_POOL_SIZE" -gt 0 ]; then
  echo ""
  echo "✓ Warm Pool 已就绪"
  echo ""
  echo "Warm Pool 实例:"
  echo "$WARM_POOL" | jq '.Instances[] | {InstanceId, LifecycleState}'
  exit 0
fi

# 需要预热实例
echo ""
echo "--- 预热 Warm Pool ---"
echo ""
echo "步骤："
echo "1. 启动实例（会触发 EBS 预热和镜像拉取）"
echo "2. 等待实例进入 Warm Pool"
echo ""

# 临时增加 desired capacity 来创建实例
CURRENT_DESIRED=$(echo "$ASG_INFO" | jq '.DesiredCapacity')
WARM_TARGET=$((WARM_POOL_SIZE + 1))

if [ "$CURRENT_DESIRED" -lt "$WARM_TARGET" ]; then
  echo "设置 Desired Capacity: $CURRENT_DESIRED -> $WARM_TARGET"
  aws autoscaling set-desired-capacity \
    --auto-scaling-group-name "$ASG_NAME" \
    --desired-capacity "$WARM_TARGET" \
    --region "$REGION"
fi

# 等待实例启动并完成预热
echo ""
echo "等待实例启动和预热..."
echo "（这可能需要 3-5 分钟，因为需要："
echo "  - 启动 EC2 实例"
echo "  - 预热 EBS 卷"
echo "  - 从 ECR 拉取 Docker 镜像"
echo "  - 注册到 ECS 集群）"
echo ""

TIMEOUT=600
ELAPSED=0
READY=false

while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  # 检查 ECS 容器实例
  CONTAINER_INSTANCES=$(aws ecs list-container-instances \
    --cluster "$CLUSTER_NAME" \
    --region "$REGION" \
    --query 'containerInstanceArns | length(@)' \
    --output text 2>/dev/null || echo "0")

  # 检查 Warm Pool
  WARM_POOL=$(aws autoscaling describe-warm-pool \
    --auto-scaling-group-name "$ASG_NAME" \
    --region "$REGION" 2>/dev/null || echo "{}")
  WARM_INSTANCES=$(echo "$WARM_POOL" | jq '.Instances | length')

  echo -ne "\r[${ELAPSED}s] ECS 容器实例: $CONTAINER_INSTANCES, Warm Pool 实例: $WARM_INSTANCES   "

  # 如果有足够的实例在 ECS 中，可以开始缩容到 Warm Pool
  if [ "$CONTAINER_INSTANCES" -ge "$WARM_TARGET" ]; then
    echo ""
    echo ""
    echo "✓ 实例已注册到 ECS"

    # 缩容让实例进入 Warm Pool
    echo "缩容到 desired=1，让多余实例进入 Warm Pool..."
    aws autoscaling set-desired-capacity \
      --auto-scaling-group-name "$ASG_NAME" \
      --desired-capacity 1 \
      --region "$REGION"

    # 等待实例进入 Warm Pool
    echo "等待实例进入 Warm Pool..."
    sleep 30

    WARM_POOL=$(aws autoscaling describe-warm-pool \
      --auto-scaling-group-name "$ASG_NAME" \
      --region "$REGION" 2>/dev/null || echo "{}")
    WARM_INSTANCES=$(echo "$WARM_POOL" | jq '.Instances | length')

    if [ "$WARM_INSTANCES" -gt 0 ]; then
      READY=true
      break
    fi
  fi

  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

echo ""

if [ "$READY" = true ]; then
  echo ""
  echo "=========================================="
  echo "  ✓ Warm Pool 初始化完成"
  echo "=========================================="
  echo ""
  echo "Warm Pool 实例:"
  aws autoscaling describe-warm-pool \
    --auto-scaling-group-name "$ASG_NAME" \
    --region "$REGION" \
    | jq '.Instances[] | {InstanceId, LifecycleState}'
  echo ""
  echo "现在可以运行测试:"
  echo "  ./scripts/test-ec2-warm-start.sh   # 测试预热启动"
  echo "  ./scripts/test-ec2-cold-start.sh   # 测试冷启动（对比）"
else
  echo ""
  echo "⚠️  预热超时，请检查："
  echo "  - CloudWatch 日志"
  echo "  - EC2 实例状态"
  echo "  - ECS Agent 日志"
fi
