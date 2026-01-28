# Optima Infra Lab

Optima 基础设施实验室 - 用于测试和验证各种基础设施优化方案。

## 当前实验

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
    ├── task-prewarming-plan.md
    ├── task-prewarming-results.md
    └── capacity-simulation.md
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

## 测试结果汇总

| 实验 | 指标 | 结果 | 文档 |
|------|------|------|------|
| EC2 Warm Pool | 启动时间 | ~22s (从 Stopped) | [详情](docs/ec2-warm-pool-results.md) |
| Task 预热池 | 端到端延迟 | ~260ms | [详情](docs/task-prewarming-results.md) |
| 容量策略模拟 | 等待时间分布 | 见报告 | [详情](docs/capacity-simulation.md) |

## 相关项目

- [optima-ai-shell](https://github.com/Optima-Chat/optima-ai-shell) - AI Shell 主项目
- [session-gateway](https://github.com/Optima-Chat/optima-ai-shell/tree/main/packages/session-gateway) - Session Gateway

## 未来实验计划

- [ ] Golden AMI 自动构建
- [ ] Fargate Spot 中断测试
- [ ] 多 AZ 容量策略
- [ ] EFS 性能模式对比
