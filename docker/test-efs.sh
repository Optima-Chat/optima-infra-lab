#!/bin/bash
# EFS 挂载和目录隔离测试脚本
# 在容器内自动运行

set -e

EFS_PATH="/mnt/efs"
USER_ID="${USER_ID:-test-$(hostname)}"
TASK_ID="${ECS_TASK_ID:-$(hostname)}"

echo "=========================================="
echo "  EFS 测试"
echo "=========================================="
echo ""
echo "Task ID: $TASK_ID"
echo "User ID: $USER_ID"
echo "EFS Path: $EFS_PATH"
echo ""

# ============================================================================
# 测试 1: EFS 挂载检查
# ============================================================================
echo "--- 测试 1: EFS 挂载检查 ---"
if [ -d "$EFS_PATH" ]; then
    echo "✓ EFS 目录存在"

    # 检查是否可写
    TEST_FILE="$EFS_PATH/.write-test-$TASK_ID"
    if touch "$TEST_FILE" 2>/dev/null; then
        echo "✓ EFS 可写"
        rm -f "$TEST_FILE"
    else
        echo "✗ EFS 不可写"
    fi

    # 显示挂载信息
    echo ""
    echo "挂载信息:"
    df -h "$EFS_PATH" 2>/dev/null || echo "  无法获取"
else
    echo "✗ EFS 目录不存在"
    exit 1
fi
echo ""

# ============================================================================
# 测试 2: 用户目录创建
# ============================================================================
echo "--- 测试 2: 用户目录创建 ---"
USER_DIR="$EFS_PATH/$USER_ID"

if mkdir -p "$USER_DIR" 2>/dev/null; then
    echo "✓ 创建用户目录: $USER_DIR"

    # 设置权限
    chmod 700 "$USER_DIR"
    echo "✓ 设置权限 700"

    # 显示权限
    ls -ld "$USER_DIR"
else
    echo "✗ 无法创建用户目录"
fi
echo ""

# ============================================================================
# 测试 3: 文件读写
# ============================================================================
echo "--- 测试 3: 文件读写 ---"
TEST_FILE="$USER_DIR/test-data.txt"
TEST_CONTENT="Hello from task $TASK_ID at $(date -Iseconds)"

# 写入
if echo "$TEST_CONTENT" > "$TEST_FILE" 2>/dev/null; then
    echo "✓ 写入文件: $TEST_FILE"
else
    echo "✗ 无法写入文件"
fi

# 读取
if [ -f "$TEST_FILE" ]; then
    READ_CONTENT=$(cat "$TEST_FILE")
    if [ "$READ_CONTENT" = "$TEST_CONTENT" ]; then
        echo "✓ 读取文件成功，内容匹配"
    else
        echo "✗ 读取文件成功，但内容不匹配"
    fi
else
    echo "✗ 文件不存在"
fi
echo ""

# ============================================================================
# 测试 4: 目录隔离（尝试访问其他用户目录）
# ============================================================================
echo "--- 测试 4: 目录隔离 ---"

# 列出所有用户目录
echo "现有用户目录:"
ls -la "$EFS_PATH" 2>/dev/null | grep -v "^total" | head -10

# 尝试访问其他目录（如果存在）
OTHER_DIRS=$(ls "$EFS_PATH" 2>/dev/null | grep -v "^$USER_ID$" | head -1)
if [ -n "$OTHER_DIRS" ]; then
    OTHER_DIR="$EFS_PATH/$OTHER_DIRS"
    echo ""
    echo "尝试访问其他用户目录: $OTHER_DIR"

    if ls "$OTHER_DIR" >/dev/null 2>&1; then
        echo "⚠ 警告: 可以列出其他用户目录"
    else
        echo "✓ 无法列出其他用户目录（预期行为）"
    fi

    if cat "$OTHER_DIR/test-data.txt" >/dev/null 2>&1; then
        echo "⚠ 警告: 可以读取其他用户文件"
    else
        echo "✓ 无法读取其他用户文件（预期行为）"
    fi
else
    echo "没有其他用户目录可测试"
    echo "提示: 启动多个任务来测试隔离"
fi
echo ""

# ============================================================================
# 测试 5: 性能测试（简单）
# ============================================================================
echo "--- 测试 5: 写入性能 ---"
PERF_FILE="$USER_DIR/perf-test.bin"
PERF_SIZE="10M"

echo "写入 $PERF_SIZE 数据..."
START_TIME=$(date +%s%N)
dd if=/dev/zero of="$PERF_FILE" bs=1M count=10 2>/dev/null
END_TIME=$(date +%s%N)

DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
echo "✓ 写入完成: ${DURATION_MS}ms"

# 清理
rm -f "$PERF_FILE"
echo ""

# ============================================================================
# 总结
# ============================================================================
echo "=========================================="
echo "  测试完成"
echo "=========================================="
echo ""
echo "用户目录: $USER_DIR"
echo "测试文件: $TEST_FILE"
echo ""
echo "可以 exec 进入容器进行更多测试:"
echo "  aws ecs execute-command --cluster <cluster> --task <task-arn> --interactive --command /bin/bash"
