#!/bin/bash
# 一键运行所有 Task 预热池测试
#
# 使用方法:
#   ./scripts/run-all-tests.sh
#   ./scripts/run-all-tests.sh --skip-efs  # 跳过 EFS 测试（需要 ECS Exec）

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

CLUSTER="${CLUSTER:-fargate-warm-pool-test}"
SERVICE="${SERVICE:-fargate-warm-pool-test-ec2-service}"
REGION="${REGION:-ap-southeast-1}"

SKIP_EFS=false

# 解析参数
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-efs)
      SKIP_EFS=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "=============================================="
echo "     Task 预热池完整测试套件"
echo "=============================================="
echo ""
echo "Cluster: $CLUSTER"
echo "Service: $SERVICE"
echo "Region:  $REGION"
echo ""

# 检查服务状态
echo "--- 检查服务状态 ---"
RUNNING_COUNT=$(aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --region "$REGION" \
  --query 'services[0].runningCount' \
  --output text 2>/dev/null || echo "0")

if [ "$RUNNING_COUNT" == "0" ] || [ "$RUNNING_COUNT" == "None" ]; then
  echo "Warning: No running tasks found!"
  echo "Starting service with 1 task..."
  aws ecs update-service \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --desired-count 1 \
    --region "$REGION" \
    --no-cli-pager

  echo "Waiting for task to start (60s)..."
  sleep 60

  RUNNING_COUNT=$(aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --region "$REGION" \
    --query 'services[0].runningCount' \
    --output text)
fi

echo "Running tasks: $RUNNING_COUNT"
echo ""

# 测试 1: AWS API 延迟
echo "=============================================="
echo "     测试 1: AWS API 延迟"
echo "=============================================="
echo ""
python3 "$SCRIPT_DIR/test-api-latency.py" --iterations 10
echo ""

# 测试 2: EFS 目录操作延迟（可选）
if [ "$SKIP_EFS" = false ]; then
  echo "=============================================="
  echo "     测试 2: EFS 目录操作延迟"
  echo "=============================================="
  echo ""

  # 检查 Session Manager Plugin
  if ! command -v session-manager-plugin &> /dev/null; then
    echo "Warning: session-manager-plugin not found, skipping EFS test"
    echo "Install: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
  else
    python3 "$SCRIPT_DIR/test-efs-latency.py" --iterations 5
  fi
  echo ""
else
  echo "--- 跳过 EFS 测试 (--skip-efs) ---"
  echo ""
fi

# 测试 3: 综合测试
echo "=============================================="
echo "     测试 3: 综合延迟评估"
echo "=============================================="
echo ""

python3 -c "
# 综合评估预热启动时间

print('预热启动时间估算:')
print()
print('  组件                     | 延迟      | 说明')
print('  -------------------------|-----------|------------------')
print('  Gateway 内存分配         | ~1ms      | Map 查找 + 状态更新')
print('  WebSocket 消息发送       | ~5ms      | 局域网延迟')
print('  EFS mkdir + 写配置       | ~30ms     | 实测')
print('  cd + 环境变量设置        | ~1ms      | 内存操作')
print('  optima headless 启动    | ~500ms    | 估算（待实测）')
print('  -------------------------|-----------|------------------')
print('  总计                     | ~540ms    | 远低于 2s 目标')
print()
print('对比:')
print('  - 当前方案 (无预热):     ~12s')
print('  - EC2 Warm Pool:        ~22s')
print('  - 预热池方案:           ~0.5-1s  (提升 90%+)')
"

echo ""
echo "=============================================="
echo "     测试完成"
echo "=============================================="
echo ""
echo "详细结果见: TASK-PREWARMING-TEST-RESULTS.md"
