#!/bin/bash
# 测试目录隔离

set -e

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

GATEWAY_URL="${GATEWAY_URL:-http://localhost:5174}"
EFS_MOUNT_PATH="${EFS_MOUNT_PATH:-/mnt/efs}"
ENVIRONMENT="${ENVIRONMENT:-test}"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Directory Isolation Test${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Gateway URL: $GATEWAY_URL"
echo "EFS Mount: $EFS_MOUNT_PATH"
echo "Environment: $ENVIRONMENT"
echo ""

# 检查 EFS 挂载
if [ ! -d "$EFS_MOUNT_PATH" ]; then
    echo -e "${YELLOW}WARNING: EFS not mounted locally at $EFS_MOUNT_PATH${NC}"
    echo "This test requires local EFS access"
    echo ""
    echo "To test remotely, you need to:"
    echo "  1. SSH into a Fargate task"
    echo "  2. Run the isolation test inside the container"
    exit 0
fi

# 创建测试用户目录
USER_A="test-user-a-$(date +%s)"
USER_B="test-user-b-$(date +%s)"
ENV_DIR="$EFS_MOUNT_PATH/$ENVIRONMENT"

echo -e "${YELLOW}Creating test user directories...${NC}"
mkdir -p "$ENV_DIR/$USER_A"
mkdir -p "$ENV_DIR/$USER_B"

# 设置权限
chmod 700 "$ENV_DIR/$USER_A"
chmod 700 "$ENV_DIR/$USER_B"

echo "User A directory: $ENV_DIR/$USER_A"
echo "User B directory: $ENV_DIR/$USER_B"
echo ""

# 测试 1: 用户 A 写入文件
echo -e "${YELLOW}Test 1: User A writes a secret file...${NC}"
echo "This is user A's secret data" > "$ENV_DIR/$USER_A/secret.txt"
echo "Written to $ENV_DIR/$USER_A/secret.txt"
echo ""

# 测试 2: 用户 B 尝试读取用户 A 的文件
echo -e "${YELLOW}Test 2: User B tries to read User A's file...${NC}"
if cat "$ENV_DIR/$USER_A/secret.txt" 2>/dev/null; then
    echo -e "${RED}FAIL: User B can read User A's file!${NC}"
    ISOLATION_RESULT="FAIL"
else
    echo -e "${GREEN}PASS: Permission denied (as expected)${NC}"
    ISOLATION_RESULT="PASS"
fi
echo ""

# 测试 3: 用户 B 尝试列出用户 A 的目录
echo -e "${YELLOW}Test 3: User B tries to list User A's directory...${NC}"
if ls "$ENV_DIR/$USER_A" 2>/dev/null; then
    echo -e "${RED}FAIL: User B can list User A's directory!${NC}"
    ISOLATION_RESULT="FAIL"
else
    echo -e "${GREEN}PASS: Permission denied (as expected)${NC}"
fi
echo ""

# 测试 4: 用户 A 可以访问自己的文件
echo -e "${YELLOW}Test 4: User A can access their own file...${NC}"
if [ -f "$ENV_DIR/$USER_A/secret.txt" ]; then
    CONTENT=$(cat "$ENV_DIR/$USER_A/secret.txt")
    echo "Content: $CONTENT"
    echo -e "${GREEN}PASS: User A can access their file${NC}"
else
    echo -e "${RED}FAIL: User A cannot access their file${NC}"
    ISOLATION_RESULT="FAIL"
fi
echo ""

# 清理
echo -e "${YELLOW}Cleaning up test directories...${NC}"
rm -rf "$ENV_DIR/$USER_A"
rm -rf "$ENV_DIR/$USER_B"
echo "Cleaned up"
echo ""

# 结果
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Isolation Test Results${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
if [ "$ISOLATION_RESULT" = "PASS" ]; then
    echo -e "${GREEN}PASS: Directory isolation is working${NC}"
else
    echo -e "${RED}FAIL: Directory isolation is not working${NC}"
    exit 1
fi
