# Fargate 预热池测试镜像
# 极简镜像，用于测试 EFS 挂载、目录隔离、冷启动时间

FROM node:20-alpine

# 安装必要工具
RUN apk add --no-cache bash curl jq

WORKDIR /app

# 复制脚本
COPY entrypoint.sh /app/entrypoint.sh
COPY test-efs.sh /app/test-efs.sh

# 设置权限
RUN chmod +x /app/*.sh

# 使用 node 用户（node:20-alpine 自带，uid=1000, gid=1000）
USER node

# 环境变量
ENV TEST_MODE=standalone \
    HOME=/home/node

ENTRYPOINT ["/app/entrypoint.sh"]
