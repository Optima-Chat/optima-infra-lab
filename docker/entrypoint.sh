#!/bin/bash
# Fargate 预热池测试 - 容器入口脚本
# 支持多种测试模式

set -e

echo "=========================================="
echo "  Fargate Warm Pool Test Container"
echo "=========================================="
echo ""
echo "启动时间: $(date -Iseconds)"
echo "用户: $(whoami) (uid=$(id -u), gid=$(id -g))"
echo "测试模式: ${TEST_MODE:-standalone}"
echo ""

# 检查 EFS 挂载
echo "=== EFS 检查 ==="
if [ -d "/mnt/efs" ]; then
    echo "EFS 已挂载: /mnt/efs"
    echo "目录内容:"
    ls -la /mnt/efs 2>/dev/null | head -10 || echo "  (空或无权限)"
else
    echo "EFS 未挂载"
fi
echo ""

# 根据模式执行
case "${TEST_MODE}" in
    standalone)
        # 独立模式：运行 EFS 测试后保持运行
        echo "=== 独立测试模式 ==="
        /app/test-efs.sh
        echo ""
        echo "测试完成，容器保持运行..."
        echo "可以 exec 进入容器进行更多测试"
        exec sleep infinity
        ;;

    efs-test)
        # EFS 测试模式：运行测试后退出
        echo "=== EFS 测试模式 ==="
        /app/test-efs.sh
        echo ""
        echo "测试完成，退出"
        exit 0
        ;;

    warm-pool)
        # 预热池模式：等待 Gateway 分配
        echo "=== 预热池模式 ==="
        if [ -z "$GATEWAY_WS_URL" ]; then
            echo "错误: GATEWAY_WS_URL 未设置"
            exit 1
        fi
        echo "连接到 Gateway: $GATEWAY_WS_URL"
        # TODO: 启动 warm-bridge.js
        exec sleep infinity
        ;;

    sleep)
        # 睡眠模式：仅保持运行
        echo "=== 睡眠模式 ==="
        exec sleep infinity
        ;;

    *)
        echo "未知模式: $TEST_MODE"
        echo "支持的模式: standalone, efs-test, warm-pool, sleep"
        exit 1
        ;;
esac
