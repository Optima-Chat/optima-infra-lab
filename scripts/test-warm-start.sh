#!/bin/bash
# 测试预热启动时间（从预热池分配）

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

GATEWAY_URL="${GATEWAY_URL:-http://localhost:5174}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Warm Start Test${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Gateway URL: $GATEWAY_URL"
echo ""

# 检查 Gateway 状态
echo -e "${YELLOW}Checking Gateway status...${NC}"
STATUS=$(curl -s "$GATEWAY_URL/api/status")
WARM_COUNT=$(echo "$STATUS" | jq -r '.warmCount')

echo "Current warm tasks: $WARM_COUNT"
echo ""

if [ "$WARM_COUNT" -eq 0 ]; then
    echo -e "${RED}ERROR: No warm tasks available${NC}"
    echo "Please ensure ECS service is running and tasks are connected"
    exit 1
fi

# 生成测试用户 ID
USER_ID="test-user-$(date +%s)"

echo -e "${YELLOW}Acquiring warm task for user: $USER_ID${NC}"
echo ""

# 记录开始时间
START_TIME=$(date +%s%N)

# 分配任务
RESULT=$(curl -s -X POST "$GATEWAY_URL/api/acquire" \
    -H "Content-Type: application/json" \
    -d "{\"userId\": \"$USER_ID\", \"sessionId\": \"session-$USER_ID\"}")

# 记录结束时间
END_TIME=$(date +%s%N)
TOTAL_LATENCY=$(( (END_TIME - START_TIME) / 1000000 ))

# 解析结果
SUCCESS=$(echo "$RESULT" | jq -r '.success')
TASK_ID=$(echo "$RESULT" | jq -r '.taskId')
SERVER_LATENCY=$(echo "$RESULT" | jq -r '.latency')

echo "Result: $RESULT"
echo ""

if [ "$SUCCESS" = "true" ]; then
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Warm Start Test Results${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "User ID:         $USER_ID"
    echo "Task ID:         $TASK_ID"
    echo "Server Latency:  ${SERVER_LATENCY}ms"
    echo "Total Latency:   ${TOTAL_LATENCY}ms (including network)"
    echo ""

    if [ "$SERVER_LATENCY" -lt 2000 ]; then
        echo -e "${GREEN}PASS: Warm start time < 2s${NC}"
    else
        echo -e "${RED}FAIL: Warm start time >= 2s${NC}"
    fi

    # 释放任务
    echo ""
    echo -e "${YELLOW}Releasing task...${NC}"
    curl -s -X POST "$GATEWAY_URL/api/release" \
        -H "Content-Type: application/json" \
        -d "{\"taskId\": \"$TASK_ID\"}" > /dev/null
    echo "Task released"
else
    echo -e "${RED}FAIL: Could not acquire warm task${NC}"
    echo "Error: $(echo "$RESULT" | jq -r '.error')"
    exit 1
fi
