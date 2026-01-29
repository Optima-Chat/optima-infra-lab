# Optima Infra Lab

Optima 基础设施实验室 - 专注于 AI Shell 的成本、扩展性和性能优化。

## 项目定位

当前主要任务：**AI Shell 基础设施优化**

- 降低成本（EC2 Warm Pool、Spot 实例）
- 提升扩展性（ASG 自动伸缩、容量规划）
- 优化性能（启动时间、冷启动、镜像预拉取）

## 优化成果

### 🚀 ECS Task 预热池

**目标**: 将 AI Shell 启动时间从 12s 降到 <1s

**结论**: ✅ 实测 **260ms**，提升 **98%**

```
当前方案 (无预热):  12,000 ms  ████████████████████████████████████
EC2 Warm Pool:     22,000 ms  ██████████████████████████████████████████████████████████████████
目标:               2,000 ms  ██████
实测:                 260 ms  █  🚀
```

详见 [测试结果](docs/task-prewarming-results.md)

### 🐳 EC2 镜像预拉取

**问题**: 新 EC2 首次启动 Task 需要 44 秒拉取镜像

**方案**: 在 Launch Template user_data 中预拉取镜像

**效果**: 镜像拉取时间 44s → **0s**（已缓存）

详见 [实施文档](docs/ec2-image-prepull.md)

## 测试结果汇总

| 实验 | 指标 | 结果 | 文档 |
|------|------|------|------|
| EC2 Warm Pool | 启动时间 | ~22s (从 Stopped) | [详情](docs/ec2-warm-pool-results.md) |
| Task 预热池 | 端到端延迟 | ~260ms | [详情](docs/task-prewarming-results.md) |
| 容量策略模拟 | 等待时间分布 | 见报告 | [详情](docs/capacity-simulation.md) |
| EC2 镜像预拉取 | 首次 Task 启动 | 44s → <1s | [详情](docs/ec2-image-prepull.md) |

## 项目结构

```
optima-infra-lab/
├── terraform/          # AWS 基础设施配置
│   ├── main.tf        # ECS Cluster + Service
│   ├── efs.tf         # EFS + 共享 Access Point
│   ├── ec2-warm-pool.tf  # EC2 ASG + Warm Pool
│   └── variables.tf
├── docker/            # 测试用 Docker 镜像
├── gateway/           # Mock Session Gateway
├── scripts/           # 测试脚本
│   ├── run-all-tests.sh      # 一键运行所有测试
│   ├── test-api-latency.py   # AWS API 延迟测试
│   ├── test-efs-latency.py   # EFS 目录操作延迟测试
│   └── ...
└── docs/              # 测试报告和文档
    ├── ec2-warm-pool-results.md
    ├── ec2-image-prepull.md     # 🆕 镜像预拉取优化
    ├── task-prewarming-plan.md
    ├── task-prewarming-results.md
    ├── capacity-simulation.md
    └── startup-optimization.md  # 启动时间优化方案汇总
```

## 快速开始

### 1. 部署基础设施

```bash
cd terraform
terraform init
terraform apply
```

### 2. 运行测试

```bash
# 一键运行所有测试
./scripts/run-all-tests.sh

# 只测试 API 延迟
python3 scripts/test-api-latency.py

# 只测试 EFS 延迟
python3 scripts/test-efs-latency.py
```

### 3. 使用 AI Shell 镜像测试

```bash
cd terraform
terraform apply -var="use_ai_shell_image=true"
```

## 相关项目

- [optima-ai-shell](https://github.com/Optima-Chat/optima-ai-shell) - AI Shell 主项目
- [optima-terraform](https://github.com/Optima-Chat/optima-terraform) - 生产基础设施配置
- [session-gateway](https://github.com/Optima-Chat/optima-ai-shell/tree/main/packages/session-gateway) - Session Gateway

### 🏗️ Golden AMI 自动构建

**目标**: 进一步减少 EC2 冷启动时间

**状态**: 🚧 配置已创建，待测试

```bash
# 手动构建
cd packer && ./build.sh

# 或使用 GitHub Actions
```

详见 [Golden AMI 文档](docs/golden-ami.md)

## 未来实验计划

- [x] Golden AMI 自动构建（Packer）- 配置已创建
- [ ] Fargate Spot 中断测试
- [ ] 多 AZ 容量策略
- [ ] EFS 性能模式对比
- [ ] 共享 AP + Task 预热池实施
