#!/bin/bash
# 综合基线测试脚本
# 分别测试各环节启动时间，建立基线数据
#
# 用法:
#   ./scripts/test-baseline.sh          # 交互式选择测试环节
#   ./scripts/test-baseline.sh -a       # 测试环节 A (热池分配)
#   ./scripts/test-baseline.sh -b       # 测试环节 B (Warm → InService)
#   ./scripts/test-baseline.sh -c       # 测试环节 C (冷启动)
#   ./scripts/test-baseline.sh --all    # 测试所有环节

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/docs/baseline-results"

REGION="${AWS_REGION:-ap-southeast-1}"
CLUSTER_NAME="fargate-warm-pool-test"
ASG_NAME="fargate-warm-pool-test-ecs-asg"
SERVICE_NAME="fargate-warm-pool-test-ec2-service"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 创建结果目录
mkdir -p "$RESULTS_DIR"

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

# 时间戳
timestamp() { date +%s%3N; }
timestamp_readable() { date '+%Y-%m-%d %H:%M:%S'; }

# ============================================================================
# 环节 A: 热池 Task 分配测试
# ============================================================================
test_phase_a() {
  echo ""
  echo "=============================================="
  echo "  环节 A: 热池 Task 分配测试"
  echo "=============================================="
  echo ""

  RESULT_FILE="$RESULTS_DIR/phase-a-$(date +%Y%m%d-%H%M%S).md"

  echo "# 环节 A 基线测试结果" > "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "**测试时间**: $(timestamp_readable)" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"

  # A1-A4: EFS 延迟测试
  log_info "测试 EFS 延迟..."

  if command -v session-manager-plugin &> /dev/null; then
    # 获取一个运行中的 Task
    TASK_ARN=$(aws ecs list-tasks \
      --cluster "$CLUSTER_NAME" \
      --service-name "$SERVICE_NAME" \
      --desired-status RUNNING \
      --region "$REGION" \
      --query 'taskArns[0]' \
      --output text 2>/dev/null || echo "")

    if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
      log_info "Task: $TASK_ARN"

      # 运行 EFS 延迟测试
      echo "" >> "$RESULT_FILE"
      echo "## EFS 操作延迟" >> "$RESULT_FILE"
      echo "" >> "$RESULT_FILE"

      python3 "$SCRIPT_DIR/test-efs-latency.py" --iterations 5 | tee -a "$RESULT_FILE"
    else
      log_warn "没有运行中的 Task，跳过 EFS 测试"
    fi
  else
    log_warn "session-manager-plugin 未安装，跳过 EFS 测试"
    echo "⚠️ 跳过 EFS 测试 (需要 session-manager-plugin)" >> "$RESULT_FILE"
  fi

  # A5: optima 启动时间（需要 AI Shell 镜像）
  echo "" >> "$RESULT_FILE"
  echo "## optima 启动时间" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "需要使用 AI Shell 镜像测试:" >> "$RESULT_FILE"
  echo '```bash' >> "$RESULT_FILE"
  echo 'terraform apply -var="use_ai_shell_image=true"' >> "$RESULT_FILE"
  echo '```' >> "$RESULT_FILE"

  echo "" >> "$RESULT_FILE"
  echo "## 汇总" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "| 子环节 | 延迟 | 备注 |" >> "$RESULT_FILE"
  echo "|--------|------|------|" >> "$RESULT_FILE"
  echo "| A1 Gateway 分配 | ~1ms | 内存操作 |" >> "$RESULT_FILE"
  echo "| A2 WebSocket | ~5ms | 局域网 |" >> "$RESULT_FILE"
  echo "| A3 EFS mkdir | 见上 | 实测 |" >> "$RESULT_FILE"
  echo "| A4 EFS write | 见上 | 实测 |" >> "$RESULT_FILE"
  echo "| A5 optima | 待测 | 需 AI Shell |" >> "$RESULT_FILE"

  log_success "结果保存到: $RESULT_FILE"
}

# ============================================================================
# 环节 B: EC2 Warm → InService 测试
# ============================================================================
test_phase_b() {
  echo ""
  echo "=============================================="
  echo "  环节 B: EC2 Warm → InService 测试"
  echo "=============================================="
  echo ""

  RESULT_FILE="$RESULTS_DIR/phase-b-$(date +%Y%m%d-%H%M%S).md"

  echo "# 环节 B 基线测试结果" > "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "**测试时间**: $(timestamp_readable)" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"

  # 获取当前 Warm Pool 状态
  WARM_POOL_INFO=$(aws autoscaling describe-warm-pool \
    --auto-scaling-group-name "$ASG_NAME" \
    --region "$REGION" 2>/dev/null || echo "{}")

  WARM_STATE=$(echo "$WARM_POOL_INFO" | jq -r '.WarmPoolConfiguration.PoolState // "Unknown"')
  WARM_COUNT=$(echo "$WARM_POOL_INFO" | jq -r '.Instances | length // 0')

  echo "## 环境信息" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "| 项目 | 值 |" >> "$RESULT_FILE"
  echo "|------|---|" >> "$RESULT_FILE"
  echo "| Warm Pool 状态 | $WARM_STATE |" >> "$RESULT_FILE"
  echo "| 预热实例数 | $WARM_COUNT |" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"

  if [ "$WARM_COUNT" -eq 0 ]; then
    log_error "Warm Pool 为空，无法测试"
    echo "⚠️ Warm Pool 为空，需要先创建预热实例" >> "$RESULT_FILE"
    return 1
  fi

  log_info "当前 Warm Pool 状态: $WARM_STATE, 实例数: $WARM_COUNT"

  # 记录开始时间
  START_TIME=$(timestamp)
  log_info "开始时间: $(timestamp_readable)"

  # 获取当前 desired capacity
  CURRENT_DESIRED=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].DesiredCapacity' \
    --output text)

  NEW_DESIRED=$((CURRENT_DESIRED + 1))
  log_info "增加 Desired Capacity: $CURRENT_DESIRED → $NEW_DESIRED"

  # 触发扩容
  aws autoscaling set-desired-capacity \
    --auto-scaling-group-name "$ASG_NAME" \
    --desired-capacity "$NEW_DESIRED" \
    --region "$REGION"

  echo "## 测试过程" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "| 阶段 | 时间点 | 耗时 |" >> "$RESULT_FILE"
  echo "|------|--------|------|" >> "$RESULT_FILE"
  echo "| 开始 | $(timestamp_readable) | - |" >> "$RESULT_FILE"

  # B1: 等待实例从 Warm Pool 进入 Pending
  log_info "等待实例唤醒..."
  TIMEOUT=120
  ELAPSED=0

  while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    # 检查是否有实例在 Pending:Wait 或 Pending:Proceed
    PENDING_COUNT=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --region "$REGION" \
      --query 'AutoScalingGroups[0].Instances[?starts_with(LifecycleState, `Pending`)] | length(@)' \
      --output text 2>/dev/null || echo "0")

    if [ "$PENDING_COUNT" -gt 0 ]; then
      PENDING_TIME=$(timestamp)
      PENDING_DURATION=$((PENDING_TIME - START_TIME))
      log_success "实例进入 Pending: ${PENDING_DURATION}ms"
      echo "| B1 实例唤醒 | +${PENDING_DURATION}ms | ${PENDING_DURATION}ms |" >> "$RESULT_FILE"
      break
    fi

    sleep 1
    ELAPSED=$((ELAPSED + 1))
    echo -ne "\r等待唤醒... ${ELAPSED}s"
  done
  echo ""

  # B2: 等待实例进入 InService
  log_info "等待实例 InService..."
  ELAPSED=0

  while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    INSERVICE_COUNT=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-names "$ASG_NAME" \
      --region "$REGION" \
      --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`] | length(@)' \
      --output text)

    if [ "$INSERVICE_COUNT" -ge "$NEW_DESIRED" ]; then
      INSERVICE_TIME=$(timestamp)
      INSERVICE_DURATION=$((INSERVICE_TIME - START_TIME))
      log_success "实例 InService: ${INSERVICE_DURATION}ms (~$((INSERVICE_DURATION/1000))s)"
      echo "| B2 InService | +${INSERVICE_DURATION}ms | $((INSERVICE_DURATION - PENDING_DURATION))ms |" >> "$RESULT_FILE"
      break
    fi

    sleep 1
    ELAPSED=$((ELAPSED + 1))
    echo -ne "\r等待 InService... ${ELAPSED}s (当前: $INSERVICE_COUNT/$NEW_DESIRED)"
  done
  echo ""

  # B3-B5: 等待 ECS Task 运行
  CURRENT_TASKS=$(aws ecs list-tasks \
    --cluster "$CLUSTER_NAME" \
    --service-name "$SERVICE_NAME" \
    --desired-status RUNNING \
    --region "$REGION" \
    --query 'taskArns | length(@)' \
    --output text 2>/dev/null || echo "0")

  log_info "等待 ECS Task 启动... (当前: $CURRENT_TASKS)"
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
      TASK_TIME=$(timestamp)
      TASK_DURATION=$((TASK_TIME - START_TIME))
      log_success "ECS Task 运行: ${TASK_DURATION}ms (~$((TASK_DURATION/1000))s)"
      echo "| B3-B5 Task 运行 | +${TASK_DURATION}ms | $((TASK_DURATION - INSERVICE_DURATION))ms |" >> "$RESULT_FILE"
      break
    fi

    sleep 1
    ELAPSED=$((ELAPSED + 1))
    echo -ne "\r等待 Task... ${ELAPSED}s (运行: $TASK_COUNT)"
  done
  echo ""

  # 汇总
  TOTAL_DURATION=$(($(timestamp) - START_TIME))

  echo "" >> "$RESULT_FILE"
  echo "## 汇总" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "| 指标 | 值 |" >> "$RESULT_FILE"
  echo "|------|---|" >> "$RESULT_FILE"
  echo "| Warm Pool 状态 | $WARM_STATE |" >> "$RESULT_FILE"
  if [ -n "$PENDING_DURATION" ]; then
    echo "| 实例唤醒 (B1) | ${PENDING_DURATION}ms |" >> "$RESULT_FILE"
  fi
  if [ -n "$INSERVICE_DURATION" ]; then
    echo "| InService (B2) | ${INSERVICE_DURATION}ms (~$((INSERVICE_DURATION/1000))s) |" >> "$RESULT_FILE"
  fi
  if [ -n "$TASK_DURATION" ]; then
    echo "| Task 运行 (B3-B5) | ${TASK_DURATION}ms (~$((TASK_DURATION/1000))s) |" >> "$RESULT_FILE"
  fi
  echo "| **总计** | **${TOTAL_DURATION}ms (~$((TOTAL_DURATION/1000))s)** |" >> "$RESULT_FILE"

  echo ""
  echo "=============================================="
  echo "  环节 B 测试结果"
  echo "=============================================="
  echo "Warm Pool 状态: $WARM_STATE"
  [ -n "$INSERVICE_DURATION" ] && echo "InService:      ${INSERVICE_DURATION}ms (~$((INSERVICE_DURATION/1000))s)"
  [ -n "$TASK_DURATION" ] && echo "Task 运行:      ${TASK_DURATION}ms (~$((TASK_DURATION/1000))s)"
  echo "总计:           ${TOTAL_DURATION}ms (~$((TOTAL_DURATION/1000))s)"
  echo ""

  # 恢复 desired capacity
  log_info "恢复 Desired Capacity: $NEW_DESIRED → $CURRENT_DESIRED"
  aws autoscaling set-desired-capacity \
    --auto-scaling-group-name "$ASG_NAME" \
    --desired-capacity "$CURRENT_DESIRED" \
    --region "$REGION"

  log_success "结果保存到: $RESULT_FILE"
}

# ============================================================================
# 环节 C: EC2 冷启动测试
# ============================================================================
test_phase_c() {
  echo ""
  echo "=============================================="
  echo "  环节 C: EC2 冷启动 → Warm Pool 测试"
  echo "=============================================="
  echo ""

  log_warn "此测试将启动一个新的 EC2 实例，测试完成后自动终止"
  log_warn "预计耗时 2-5 分钟"
  echo ""
  read -p "继续? (y/N) " -n 1 -r
  echo ""

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "已取消"
    return 0
  fi

  RESULT_FILE="$RESULTS_DIR/phase-c-$(date +%Y%m%d-%H%M%S).md"

  echo "# 环节 C 基线测试结果" > "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "**测试时间**: $(timestamp_readable)" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"

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

  SUBNET_ID=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --region "$REGION" \
    --query 'AutoScalingGroups[0].VPCZoneIdentifier' \
    --output text | cut -d',' -f1)

  echo "## 环境信息" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "| 项目 | 值 |" >> "$RESULT_FILE"
  echo "|------|---|" >> "$RESULT_FILE"
  echo "| Launch Template | $LAUNCH_TEMPLATE_ID |" >> "$RESULT_FILE"
  echo "| Version | $LAUNCH_TEMPLATE_VERSION |" >> "$RESULT_FILE"
  echo "| Subnet | $SUBNET_ID |" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"

  # 记录开始时间
  START_TIME=$(timestamp)
  log_info "开始时间: $(timestamp_readable)"

  # C1: 启动实例
  log_info "启动新 EC2 实例..."
  INSTANCE_ID=$(aws ec2 run-instances \
    --launch-template "LaunchTemplateId=$LAUNCH_TEMPLATE_ID,Version=$LAUNCH_TEMPLATE_VERSION" \
    --subnet-id "$SUBNET_ID" \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' \
    --output text)

  log_info "Instance ID: $INSTANCE_ID"

  echo "## 测试过程" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "| 阶段 | 时间点 | 累计耗时 |" >> "$RESULT_FILE"
  echo "|------|--------|---------|" >> "$RESULT_FILE"
  echo "| 开始 | $(timestamp_readable) | 0s |" >> "$RESULT_FILE"
  echo "| Instance ID | $INSTANCE_ID | - |" >> "$RESULT_FILE"

  # C1: 等待 pending → running
  log_info "等待实例 running..."
  TIMEOUT=300
  ELAPSED=0

  while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    STATE=$(aws ec2 describe-instances \
      --instance-ids "$INSTANCE_ID" \
      --region "$REGION" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text 2>/dev/null || echo "pending")

    if [ "$STATE" = "running" ]; then
      RUNNING_TIME=$(timestamp)
      RUNNING_DURATION=$((RUNNING_TIME - START_TIME))
      log_success "C1 实例 running: ${RUNNING_DURATION}ms (~$((RUNNING_DURATION/1000))s)"
      echo "| C1 running | +$((RUNNING_DURATION/1000))s | $((RUNNING_DURATION/1000))s |" >> "$RESULT_FILE"
      break
    fi

    sleep 1
    ELAPSED=$((ELAPSED + 1))
    echo -ne "\r等待 running... ${ELAPSED}s (状态: $STATE)"
  done
  echo ""

  # C2: 等待状态检查通过
  log_info "等待实例状态检查..."
  ELAPSED=0

  while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    STATUS=$(aws ec2 describe-instance-status \
      --instance-ids "$INSTANCE_ID" \
      --region "$REGION" \
      --query 'InstanceStatuses[0].InstanceStatus.Status' \
      --output text 2>/dev/null || echo "initializing")

    if [ "$STATUS" = "ok" ]; then
      STATUS_TIME=$(timestamp)
      STATUS_DURATION=$((STATUS_TIME - START_TIME))
      log_success "C2 状态检查通过: ${STATUS_DURATION}ms (~$((STATUS_DURATION/1000))s)"
      echo "| C2 状态检查 | +$((STATUS_DURATION/1000))s | $((STATUS_DURATION/1000))s |" >> "$RESULT_FILE"
      break
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
    echo -ne "\r等待状态检查... ${ELAPSED}s (状态: $STATUS)"
  done
  echo ""

  # C6: 等待 ECS Agent 注册
  log_info "等待 ECS Agent 注册..."
  ELAPSED=0

  while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    CONTAINER_INSTANCE=$(aws ecs list-container-instances \
      --cluster "$CLUSTER_NAME" \
      --filter "ec2InstanceId==$INSTANCE_ID" \
      --region "$REGION" \
      --query 'containerInstanceArns[0]' \
      --output text 2>/dev/null || echo "None")

    if [ "$CONTAINER_INSTANCE" != "None" ] && [ -n "$CONTAINER_INSTANCE" ]; then
      ECS_TIME=$(timestamp)
      ECS_DURATION=$((ECS_TIME - START_TIME))
      log_success "C6 ECS Agent 注册: ${ECS_DURATION}ms (~$((ECS_DURATION/1000))s)"
      echo "| C6 ECS Agent | +$((ECS_DURATION/1000))s | $((ECS_DURATION/1000))s |" >> "$RESULT_FILE"
      break
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
    echo -ne "\r等待 ECS Agent... ${ELAPSED}s"
  done
  echo ""

  # 汇总
  TOTAL_DURATION=$(($(timestamp) - START_TIME))

  echo "" >> "$RESULT_FILE"
  echo "## 汇总" >> "$RESULT_FILE"
  echo "" >> "$RESULT_FILE"
  echo "| 阶段 | 耗时 |" >> "$RESULT_FILE"
  echo "|------|------|" >> "$RESULT_FILE"
  [ -n "$RUNNING_DURATION" ] && echo "| C1 pending → running | $((RUNNING_DURATION/1000))s |" >> "$RESULT_FILE"
  [ -n "$STATUS_DURATION" ] && echo "| C2 状态检查通过 | $((STATUS_DURATION/1000))s |" >> "$RESULT_FILE"
  [ -n "$ECS_DURATION" ] && echo "| C6 ECS Agent 注册 | $((ECS_DURATION/1000))s |" >> "$RESULT_FILE"
  echo "| **总计** | **$((TOTAL_DURATION/1000))s** |" >> "$RESULT_FILE"

  echo ""
  echo "=============================================="
  echo "  环节 C 测试结果"
  echo "=============================================="
  [ -n "$RUNNING_DURATION" ] && echo "C1 running:      $((RUNNING_DURATION/1000))s"
  [ -n "$STATUS_DURATION" ] && echo "C2 状态检查:     $((STATUS_DURATION/1000))s"
  [ -n "$ECS_DURATION" ] && echo "C6 ECS Agent:    $((ECS_DURATION/1000))s"
  echo "总计:            $((TOTAL_DURATION/1000))s"
  echo ""

  # 清理
  log_info "清理: 终止测试实例 $INSTANCE_ID"
  aws ec2 terminate-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" > /dev/null

  log_success "结果保存到: $RESULT_FILE"
}

# ============================================================================
# 主程序
# ============================================================================
show_menu() {
  echo ""
  echo "=============================================="
  echo "  启动时间基线测试"
  echo "=============================================="
  echo ""
  echo "选择要测试的环节:"
  echo ""
  echo "  A) 环节 A: 热池 Task 分配 (~1 分钟)"
  echo "     - EFS 目录操作延迟"
  echo "     - optima 启动时间"
  echo ""
  echo "  B) 环节 B: EC2 Warm → InService (~30 秒)"
  echo "     - Hibernated/Stopped 实例唤醒"
  echo "     - ECS Agent 注册"
  echo "     - Task 调度和启动"
  echo ""
  echo "  C) 环节 C: EC2 冷启动 (~3 分钟)"
  echo "     - 全新实例启动"
  echo "     - 状态检查"
  echo "     - ECS Agent 注册"
  echo ""
  echo "  X) 全部测试"
  echo "  Q) 退出"
  echo ""
  read -p "选择 [A/B/C/X/Q]: " -n 1 -r
  echo ""
}

main() {
  case "${1:-}" in
    -a|--phase-a)
      test_phase_a
      ;;
    -b|--phase-b)
      test_phase_b
      ;;
    -c|--phase-c)
      test_phase_c
      ;;
    --all)
      test_phase_a
      test_phase_b
      test_phase_c
      ;;
    *)
      while true; do
        show_menu
        case $REPLY in
          [Aa]) test_phase_a ;;
          [Bb]) test_phase_b ;;
          [Cc]) test_phase_c ;;
          [Xx])
            test_phase_a
            test_phase_b
            test_phase_c
            ;;
          [Qq]) exit 0 ;;
          *) log_warn "无效选择" ;;
        esac
      done
      ;;
  esac
}

main "$@"
