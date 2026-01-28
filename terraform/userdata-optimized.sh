#!/bin/bash
# 优化版 User Data - 精简 EBS 预热
# 目标: 减少预热时间从 22s 到 5s
set -ex

# 记录启动时间
echo "EC2_BOOT_START=$(date +%s%3N)" >> /var/log/boot-timing.log

# 配置 ECS Agent（支持 Hibernation）
cat >> /etc/ecs/ecs.config <<'ECSCONFIG'
ECS_CLUSTER=${CLUSTER_NAME}
ECS_WARM_POOLS_CHECK=true
ECS_ENABLE_TASK_IAM_ROLE=true
ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true
ECS_LOGLEVEL=info
ECS_IMAGE_PULL_BEHAVIOR=prefer-cached
ECSCONFIG

# 精简版 EBS 预热（只预热关键目录）
# 原版预热 1.1GB 数据，耗时 22s
# 优化版只预热 ~450MB，预计 8-10s
if [ ! -f /var/lib/cloud/instance/sem/ebs_warmed ]; then
  echo "WARM_START=$(date +%s%3N)" >> /var/log/boot-timing.log

  # 1. 只预热 Docker 和 ECS 关键文件
  echo "Warming Docker and ECS..."
  find /var/lib/docker -type f -exec cat {} \; > /dev/null 2>&1 || true
  find /var/lib/ecs -type f -exec cat {} \; > /dev/null 2>&1 || true

  # 2. 跳过 /lib/modules, /usr/bin, /usr/sbin, /usr/lib64
  # 这些在 ECS 场景下不是启动关键路径

  echo "WARM_END=$(date +%s%3N)" >> /var/log/boot-timing.log
  touch /var/lib/cloud/instance/sem/ebs_warmed
else
  echo "EBS already warmed, skipping"
fi

echo "EC2_WARM_DONE=$(date +%s%3N)" >> /var/log/boot-timing.log

# 确保 ECS 服务启动
systemctl enable ecs
systemctl start ecs

# 等待 ECS Agent 注册
until curl -s http://localhost:51678/v1/metadata; do
  sleep 1
done
echo "ECS_AGENT_READY=$(date +%s%3N)" >> /var/log/boot-timing.log
