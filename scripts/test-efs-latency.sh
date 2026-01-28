#!/bin/bash
# EFS 目录操作延迟测试脚本
# 在容器内部运行，测量真实的 EFS 延迟

set -e

CLUSTER="${CLUSTER:-fargate-warm-pool-test}"
SERVICE="${SERVICE:-fargate-warm-pool-test-ec2-service}"
REGION="${REGION:-ap-southeast-1}"
CONTAINER="${CONTAINER:-test}"

echo "=== EFS 目录操作延迟测试 ==="
echo "Cluster: $CLUSTER"
echo "Service: $SERVICE"
echo "Region: $REGION"
echo ""

# 获取 Task ARN
TASK_ARN=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --region "$REGION" --query 'taskArns[0]' --output text)

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" == "None" ]; then
  echo "Error: No running tasks found"
  exit 1
fi

echo "Task: ${TASK_ARN##*/}"
echo ""
echo "Running tests inside container..."
echo ""

# 创建临时脚本
SCRIPT='
echo "========================================"
echo "     EFS 延迟测试 (容器内部)"
echo "========================================"
echo

# 清理旧数据
rm -rf /mnt/efs/latency-test-* 2>/dev/null || true

echo "--- 1. mkdir 测试 (5 次) ---"
for i in 1 2 3 4 5; do
  time mkdir -p /mnt/efs/latency-test-$i/.optima 2>&1 | grep real || echo "  mkdir $i done"
done

echo
echo "--- 2. 写文件测试 (5 次) ---"
for i in 1 2 3 4 5; do
  time sh -c "echo test-data-$i > /mnt/efs/latency-test-$i/data.txt" 2>&1 | grep real || echo "  write $i done"
done

echo
echo "--- 3. 读文件测试 (5 次) ---"
for i in 1 2 3 4 5; do
  time cat /mnt/efs/latency-test-$i/data.txt 2>&1 | grep real || echo "  read $i done"
done

echo
echo "--- 4. 完整用户初始化模拟 (3 次) ---"
for i in 1 2 3; do
  USER_DIR=/mnt/efs/latency-test-init-$i
  time sh -c "mkdir -p $USER_DIR/.optima && echo token > $USER_DIR/.optima/token.json && cd $USER_DIR" 2>&1 | grep real || echo "  init $i done"
done

echo
echo "--- 清理 ---"
rm -rf /mnt/efs/latency-test-* /mnt/efs/latency-test-init-*

echo
echo "========================================"
echo "     测试完成"
echo "========================================"
'

# 在容器内运行测试
aws ecs execute-command \
  --cluster "$CLUSTER" \
  --task "$TASK_ARN" \
  --container "$CONTAINER" \
  --region "$REGION" \
  --interactive \
  --command "sh -c '$SCRIPT'"

echo ""
echo "Done."
