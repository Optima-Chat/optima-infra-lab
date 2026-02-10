# 12 - FinOps 与云成本优化

> 花对每一分钱，比花更少的钱更重要

---

## 我们现在在哪

先盘一下 Optima 当前的云账单结构：

```
当前月度成本估算（AWS ap-southeast-1）:

Prod 环境:
  EC2 (Docker Compose 单机)      ~$30/月
  RDS db.t3.medium (共享)        ~$52/月    ← 5 个库共用一个实例
  ElastiCache Redis              ~$15/月    ← 通过 Database 隔离多环境
  ALB (共享)                      ~$20/月
  S3 + 数据传输                   ~$10/月
  Route53 + 其他                  ~$5/月
  ─────────────────────────────────────
  Prod 小计                      ~$132/月

Stage-ECS 环境:
  EC2 t3.medium (ASG 1台)        ~$30/月
  EBS 30GB GP3                    ~$2.4/月
  CloudWatch                      ~$5/月
  ECS 服务本身                     $0       ← EC2 Launch Type 不额外收费
  ─────────────────────────────────────
  Stage 小计                      ~$43/月   ← CLAUDE.md 里的数字

共享/固定:
  弹性 IP × 2                     ~$7/月
  Infisical (自托管)               $0       ← 跑在 shared-services EC2 上
  Terraform State (S3 + DynamoDB)  ~$1/月
  ECR 镜像存储                     ~$2/月
  ─────────────────────────────────────
  总计                           ~$185/月
```

做得好的决策：
- ✅ Stage 和 Prod **共享 RDS/Redis/ALB**，省掉了一整套独立实例（否则 Stage 至少 +$87/月）
- ✅ Stage-ECS 用 **1 AZ** 部署，省掉跨 AZ 的数据传输和冗余 EC2
- ✅ EBS 选 **GP3**（比 GP2 便宜 20%，性能还更好）
- ✅ ECS 用 **EC2 Launch Type**（比 Fargate 便宜约 30-50%）

可以更好的：
- ⚠️ 没有成本标签（Cost Allocation Tags），无法按服务拆分账单
- ⚠️ 没有 Budget Alert，超支不会收到通知
- ⚠️ EC2 全是按需实例，没有 Savings Plans 或 Reserved Instance
- ⚠️ 没有 S3 生命周期策略，旧部署包和日志永久保留
- ⚠️ RDS 没有自动备份保留策略的成本评估

---

## 云计算定价模型

### 按需实例 vs 预留 vs Spot vs Savings Plans

这是云成本优化的**第一课**：同样的计算资源，不同的购买方式价格差异巨大。

| 购买方式 | 折扣力度 | 承诺期 | 灵活性 | 适用场景 |
|---------|---------|--------|--------|---------|
| **On-Demand（按需）** | 0%（基准价） | 无 | 最高 | 测试环境、临时工作负载、不确定需求 |
| **Reserved Instance（RI）** | 30-72% | 1 年或 3 年 | 低（锁定实例类型和区域） | 7×24 运行的 Prod 数据库、基线服务器 |
| **Savings Plans** | 20-66% | 1 年或 3 年 | 中（承诺消费额度，不锁实例类型） | 有稳定计算需求但想保留灵活性 |
| **Spot Instance** | 60-90% | 无（随时可能被回收） | 高（但不稳定） | 批处理、CI/CD、可中断的工作负载 |

**用 Optima 的场景算一笔账**:

```
Prod EC2 t3.medium 按需价格（新加坡区域）:
  按需:          $0.0528/h × 730h = $38.54/月

如果用 1 年 Savings Plans (No Upfront):
  ~$0.033/h × 730h = $24.09/月
  节省: $14.45/月 = $173/年 (约 37% 折扣)

如果用 1 年 RI (No Upfront):
  ~$0.031/h × 730h = $22.63/月
  节省: $15.91/月 = $191/年 (约 41% 折扣)

RDS db.t3.medium 按需:
  按需:          $0.068/h × 730h = $49.64/月

如果用 1 年 RI (No Upfront):
  ~$0.044/h × 730h = $32.12/月
  节省: $17.52/月 = $210/年 (约 35% 折扣)
```

**Optima 的建议**:

- **Prod EC2 + RDS**: 至少上 1 年 Savings Plans，年省 $380+
- **Stage EC2**: 保持按需（非 7×24 运行，且可能随时调整规格）
- **暂不考虑 Spot**: 我们的服务需要持久连接（WebSocket），不适合随时中断

### 该选哪个？决策流程

```
这个资源会 7×24 运行超过 1 年吗？
├── 是 → 需要灵活更换实例类型吗？
│         ├── 是 → Savings Plans
│         └── 否 → Reserved Instance（折扣更大）
└── 否 → 工作负载可以中断吗？
          ├── 是 → Spot Instance
          └── 否 → On-Demand
```

---

## FinOps 框架

FinOps（Cloud Financial Operations）不只是"省钱"，而是一套让工程、财务、业务团队协作管理云成本的方法论。

### 三阶段循环

```
   ┌──────────────┐
   │   Inform     │  ← 看清楚钱花在哪了
   │  （可视化）    │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │   Optimize   │  ← 找到优化机会并执行
   │  （优化）      │
   └──────┬───────┘
          │
          ▼
   ┌──────────────┐
   │   Operate    │  ← 建立持续管理机制
   │  （运营）      │
   └──────┬───────┘
          │
          └───────→ 回到 Inform（持续循环）
```

### Inform（可视化）

**目标**: 让每个人都能看到成本数据，理解钱花在哪里。

| 实践 | 说明 | Optima 当前状态 |
|------|------|----------------|
| 成本标签（Tags） | 给资源打标签，按服务/环境/团队分类 | ❌ 没有 |
| Cost Explorer | AWS 内置的成本分析工具 | ⚠️ 有但没主动看 |
| 成本报告 | 定期的成本报告和趋势分析 | ❌ 没有 |
| Budget Alerts | 超过预算自动告警 | ❌ 没有 |

**最小可行的 Inform 方案**:

```bash
# 1. 给所有资源打成本标签
# 在 Terraform 中统一添加:
locals {
  common_tags = {
    Environment = "prod"        # prod / stage
    Service     = "user-auth"   # 服务名
    Project     = "optima"      # 项目名
    ManagedBy   = "terraform"   # 管理方式
  }
}

# 2. 在 AWS Cost Explorer 中启用标签
# AWS Console → Billing → Cost Allocation Tags → 激活上面的标签

# 3. 创建 Budget Alert
aws budgets create-budget \
  --account-id 585891120210 \
  --budget '{
    "BudgetName": "optima-monthly",
    "BudgetLimit": {"Amount": "200", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[{
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [{
      "SubscriptionType": "EMAIL",
      "Address": "your-email@example.com"
    }]
  }]'
```

### Optimize（优化）

**目标**: 识别并消除浪费，提高资源利用率。

优化的优先级排序：

```
影响大、改动小:
  1. 清理未使用的资源（闲置 EIP、空 EBS 卷、旧快照）
  2. 购买 Savings Plans / RI
  3. S3 生命周期策略

影响中、改动中:
  4. Right-sizing（调整实例规格）
  5. 优化数据传输路径
  6. 存储类型优化

影响大、改动大:
  7. 架构优化（Serverless 化、缓存策略）
  8. 多租户成本分摊
```

### Operate（运营）

**目标**: 把成本优化变成日常习惯，而非一次性项目。

- **月度成本 Review**: 每月看一次 Cost Explorer，识别异常
- **PR 中的成本评估**: 新增 AWS 资源时在 PR 中标注预估成本
- **自动化策略**: 非工作时间关闭 Stage 环境（如果不需要 7×24 运行）

---

## Right-sizing（右置化）

Right-sizing 是最常见的优化机会：你的实例可能比实际需要的更大。

### 如何判断实例是否过配

```
关键 CloudWatch 指标:

EC2:
  CPUUtilization        平均 < 20%   → 可能过配
  NetworkIn/Out         持续很低      → 可能过配
  mem_used_percent      < 50%        → 可能过配（需要 CloudWatch Agent）

RDS:
  CPUUtilization        平均 < 20%   → 可能过配
  FreeableMemory        > 总内存 60%  → 可能过配
  DatabaseConnections   远低于上限    → 可能过配

ECS Service:
  CPUUtilization        平均 < 30%   → Task 资源过配
  MemoryUtilization     平均 < 40%   → Task 内存过配
```

**查看 Optima 的实际使用率**:

```bash
# EC2 CPU 使用率（过去 7 天平均）
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=i-0bbc4ed4a228b9239 \
  --start-time $(date -d '7 days ago' -u +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 86400 \
  --statistics Average \
  --region ap-southeast-1

# RDS CPU 使用率
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name CPUUtilization \
  --dimensions Name=DBInstanceIdentifier,Value=optima-prod-postgres \
  --start-time $(date -d '7 days ago' -u +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 86400 \
  --statistics Average \
  --region ap-southeast-1
```

### AWS Compute Optimizer

AWS 提供的免费工具，基于历史使用数据推荐最佳实例类型。

```bash
# 启用 Compute Optimizer（首次需要）
aws compute-optimizer update-enrollment-status \
  --status Active \
  --region ap-southeast-1

# 获取 EC2 推荐
aws compute-optimizer get-ec2-instance-recommendations \
  --region ap-southeast-1

# 获取 ECS Service 推荐（如果有 Fargate）
aws compute-optimizer get-ecs-service-recommendations \
  --region ap-southeast-1
```

### Optima 的 Right-sizing 分析

| 资源 | 当前规格 | 疑问 | 建议 |
|------|---------|------|------|
| Prod EC2 | t3.medium (2C/4G) | Docker Compose 跑 4+ 服务，CPU 够吗？ | 先看 CloudWatch，如果 CPU < 40% 考虑 t3.small |
| Stage EC2 | t3.medium (2C/4G) | ECS 跑 5 个 Service + 系统开销 | 合理，ECS overhead + 多容器需要内存 |
| RDS | db.t3.medium (2C/4G) | 5 个库共用，连接数和 CPU 是否有压力？ | 用 Performance Insights 分析，可能 db.t3.small 就够 |
| ECS Tasks | 256-512MB / 0.25vCPU | 小服务是否真需要 256MB？ | 观察 MemoryUtilization，部分可降至 128MB |

**t3 实例的特殊性 — Burstable**:

t3 实例是突发型实例，基线 CPU 性能有限，但可以用积累的 Credit 突发到 100%：

```
t3.medium 基线: 20% CPU（2 vCPU 中的 20%）
  含义: 如果平均 CPU 使用率 < 20%，Credit 不会耗尽
  如果: 持续 > 20%，Credit 耗尽后性能会被限制到 20%

  Optima 场景:
    大部分时间 CPU < 10%（等待请求）
    偶尔突发到 50%+（并发请求、部署）
    → t3 非常适合这种模式，比固定性能的 m5 便宜 40%+
```

---

## 架构层面的成本优化

不同架构模式的成本模型差异巨大。选错架构，优化再多细节也省不了多少钱。

### Serverless vs 容器 vs 裸 EC2

| 维度 | Lambda / Fargate | ECS on EC2 | 裸 EC2 (Docker Compose) |
|------|------------------|------------|------------------------|
| **计费模型** | 按请求/按秒 | EC2 实例费 + ECS 免费 | EC2 实例费 |
| **闲置成本** | 接近 $0 | EC2 持续计费 | EC2 持续计费 |
| **扩缩速度** | 秒级 | 分钟级（EC2 启动） | 手动 |
| **运维复杂度** | 低 | 中 | 高 |
| **适合场景** | 不稳定/低频流量 | 持续中等流量 | 流量稳定、成本敏感 |
| **Optima 使用** | — | Stage-ECS ✅ | Prod ✅ |

**按月成本对比**（以单个轻量服务为例）:

```
场景: user-auth 服务，平均 10 req/s，P99 < 200ms

Lambda:
  10 req/s × 86400s × 30天 = 25,920,000 请求/月
  每请求 128MB × 200ms = 0.0000002083 × 25.92M = $5.40
  请求费: 25.92M × $0.0000002 = $5.18
  总计: ~$10.6/月
  → 便宜！但有冷启动问题

Fargate (0.25 vCPU / 512MB):
  $0.04048/vCPU/h × 0.25 × 730h = $7.39
  $0.004445/GB/h × 0.5 × 730h = $1.62
  总计: ~$9.0/月
  → 接近 Lambda 但无冷启动

ECS on EC2 (t3.medium 跑 4 个服务):
  $38.54/月 ÷ 4 服务 = ~$9.6/服务/月
  → 和 Fargate 差不多，但多服务共享时更划算

裸 EC2 (t3.medium Docker Compose 跑 4 个服务):
  同上 ~$9.6/服务/月
  → 成本相同，但没有 ECS 的弹性扩缩
```

**结论**: Optima 当前规模下，ECS on EC2 和 Docker Compose 成本差异不大。ECS 的价值在于弹性和运维自动化，不在于省钱。真正省钱的是 Serverless，但它有冷启动和架构约束。

### 什么时候该上 Serverless

```
适合 Serverless:
  ✅ 请求量不稳定（白天高、夜间几乎为零）
  ✅ 单个请求处理 < 15 分钟
  ✅ 无状态服务
  ✅ 不需要持久连接（WebSocket）

不适合 Serverless:
  ❌ 需要 WebSocket 长连接（agentic-chat、session-gateway）
  ❌ 请求量稳定且较高（持续 > 50 req/s 时 Lambda 比 EC2 贵）
  ❌ 需要大内存或长时间计算
  ❌ 启动时间敏感（Java/Spring 冷启动 5-10 秒）

Optima 的判断:
  user-auth      → 可以 Serverless（低频、无状态、快速响应）
  commerce-backend → 可以 Serverless（API 调用模式）
  mcp-host       → 不适合（需要编排多个下游调用，延迟敏感）
  agentic-chat   → 不适合（WebSocket 长连接、流式响应）
```

---

## 数据传输成本

AWS 数据传输定价是隐性成本大户，很多团队上线后才发现这笔费用。

### 定价规则

```
                    ┌─────────────┐
                    │   Internet   │
                    └──────┬──────┘
                           │ 出公网: $0.12/GB（前 10TB）
                           │ 入公网: 免费
                    ┌──────┴──────┐
                    │     ALB      │
                    └──────┬──────┘
                           │ ALB → EC2: 免费（同 AZ）
          ┌────────────────┼────────────────┐
          │                │                │
     ┌────┴────┐     ┌────┴────┐     ┌────┴────┐
     │  AZ-1a  │     │  AZ-1b  │     │  AZ-1c  │
     └─────────┘     └─────────┘     └─────────┘
                跨 AZ: $0.01/GB（双向收费，实际 $0.02/GB）

     ┌─────────────┐         ┌─────────────┐
     │  Region A   │ ──────→ │  Region B   │
     └─────────────┘         └─────────────┘
              跨 Region: $0.09/GB
```

**关键数字**:

| 传输类型 | 费用 | 月 100GB 成本 |
|---------|------|-------------|
| 入公网 | 免费 | $0 |
| 出公网（前 10TB） | $0.12/GB | $12 |
| 同 AZ 内 | 免费 | $0 |
| 跨 AZ（单向） | $0.01/GB | $1 |
| 跨 AZ（双向实际） | $0.02/GB | $2 |
| 跨 Region | $0.09/GB | $9 |
| 到 CloudFront | $0.00/GB | $0（Origin 到 CF 免费） |
| 到 S3（同 Region） | $0.00/GB | $0 |

### Optima 的单 AZ 策略

Stage-ECS 用 1 AZ 部署，这个决策的成本考量：

```
如果 Stage 用 2 AZ:
  额外 EC2: +$30/月（第二台 t3.medium）
  跨 AZ 流量: 服务间通信 × $0.02/GB
  ─────────────────
  额外成本: ~$35-40/月

用 1 AZ 省下的:
  $35-40/月 = 几乎翻倍了 Stage 的成本

牺牲的:
  该 AZ 故障时 Stage 完全不可用
  → 对 Stage 环境来说，这个 trade-off 完全合理
```

### 省钱技巧

**1. VPC Endpoint 避免出公网**

```
不用 VPC Endpoint:
  EC2 → Internet Gateway → S3 公网端点
  费用: $0.12/GB 出公网

用 Gateway VPC Endpoint (S3/DynamoDB):
  EC2 → VPC Endpoint → S3
  费用: $0（Gateway Endpoint 免费）

用 Interface VPC Endpoint (其他 AWS 服务):
  EC2 → VPC Endpoint → ECR/CloudWatch/等
  费用: $0.01/h × AZ数 + $0.01/GB
  → 小流量时可能比出公网还贵，大流量时划算
```

对 Optima 来说，S3 Gateway Endpoint 值得加（如果还没有的话）——ECR 镜像拉取、部署包下载、日志都走 S3。

**2. CloudFront 降低 Origin 流量**

```
不用 CloudFront:
  用户 → ALB → EC2（每个请求都打到 Origin）
  出公网: $0.12/GB

用 CloudFront:
  用户 → CloudFront 边缘节点 → 缓存命中直接返回
  Origin → CloudFront: 免费
  CloudFront → 用户: $0.085/GB（亚太，比 ALB 出公网便宜）
  缓存命中的请求: $0（不回源）

适合: 静态资源、商品图片、API 响应缓存
不适合: WebSocket、实时 API
```

---

## 存储优化

### S3 存储类别

| 存储类别 | 费用/GB/月 | 取回费 | 适用场景 |
|---------|-----------|--------|---------|
| **Standard** | $0.025 | 无 | 频繁访问的活跃数据 |
| **Intelligent-Tiering** | $0.025 + 监控费 | 无 | 访问模式不可预测 |
| **Standard-IA** | $0.0138 | $0.01/GB | 不频繁访问但需要快速取回 |
| **One Zone-IA** | $0.011 | $0.01/GB | 不频繁访问、可接受单 AZ |
| **Glacier Instant** | $0.005 | $0.03/GB | 归档但偶尔需要立即取回 |
| **Glacier Flexible** | $0.0045 | 分钟~小时 | 归档数据，取回可以等 |
| **Glacier Deep Archive** | $0.002 | 12-48 小时 | 合规存储、极少访问 |

**价格差异**: Standard → Deep Archive 便宜 **12.5 倍**。

**Optima 的 S3 存储优化建议**:

```hcl
# 给 codedeploy-artifacts Bucket 添加生命周期策略
resource "aws_s3_bucket_lifecycle_configuration" "codedeploy" {
  bucket = "optima-codedeploy-artifacts"

  rule {
    id     = "cleanup-old-artifacts"
    status = "Enabled"

    # 部署包 30 天后移到 IA
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    # 90 天后删除（不需要保留太久的部署包）
    expiration {
      days = 90
    }
  }
}

# 给商品资源 Bucket 添加智能分层
resource "aws_s3_bucket_lifecycle_configuration" "commerce_assets" {
  bucket = "optima-prod-commerce-assets"

  rule {
    id     = "intelligent-tiering"
    status = "Enabled"

    transition {
      days          = 0
      storage_class = "INTELLIGENT_TIERING"
    }
  }
}

# ALB 访问日志已经有 7 天自动删除 ✅（CLAUDE.md 中提到）
```

### EBS 类型选择

| 类型 | IOPS | 吞吐量 | 费用/GB/月 | 适用场景 |
|------|------|--------|-----------|---------|
| **gp3** | 3000 基线（可加购到 16000） | 125 MB/s 基线 | $0.096 | 通用工作负载（推荐默认） |
| **gp2** | 3 IOPS/GB（最低 100） | 与 IOPS 绑定 | $0.12 | 旧项目（建议迁移到 gp3） |
| **io2** | 自定义（最高 64000） | 自定义 | $0.142 + IOPS 费 | 高性能数据库 |
| **st1** | — | 高吞吐 | $0.054 | 大数据、日志处理 |

**gp3 vs gp2**: gp3 便宜 20%，基线性能还更好（3000 IOPS vs gp2 的 100 IOPS for 小卷）。

Optima 已经在 Stage-ECS 用了 gp3 ✅。如果 Prod EC2 还在用 gp2，应该迁移到 gp3。

```bash
# 检查 Prod EC2 的 EBS 类型
aws ec2 describe-volumes \
  --filters Name=attachment.instance-id,Values=i-0bbc4ed4a228b9239 \
  --query 'Volumes[*].{ID:VolumeId,Type:VolumeType,Size:Size,IOPS:Iops}' \
  --region ap-southeast-1
```

---

## 数据库成本优化

数据库通常是云账单的最大头之一。

### RDS 实例选型

| 实例 | vCPU | 内存 | 价格/月（新加坡） | 适用 |
|------|------|------|----------------|------|
| db.t3.micro | 2 | 1 GB | ~$18 | 开发测试 |
| db.t3.small | 2 | 2 GB | ~$35 | 轻量 Prod |
| **db.t3.medium** | 2 | 4 GB | **~$52** | **← Optima 当前** |
| db.t3.large | 2 | 8 GB | ~$104 | 中等 Prod |
| db.r6g.large | 2 | 16 GB | ~$160 | 内存密集型 |

**Optima 的 RDS 分析**:

```
当前: db.t3.medium, 5 个数据库共享

需要回答的问题:
  1. CPU 使用率多少？→ CloudWatch CPUUtilization
  2. 可用内存多少？  → CloudWatch FreeableMemory
  3. 连接数多少？    → CloudWatch DatabaseConnections

如果 CPU < 15% 且 FreeableMemory > 2.5GB:
  → 可以降到 db.t3.small（省 $17/月）

如果连接数经常接近上限:
  → 考虑 RDS Proxy（$0.015/vCPU/h，合并连接池）
```

### Reserved Instance 策略

RDS RI 的折扣比 EC2 更大，因为数据库实例单价更高：

```
db.t3.medium 1 年 RI (No Upfront):
  按需: $49.64/月
  RI:   $32.12/月
  节省: $17.52/月 = $210/年

db.t3.medium 1 年 RI (All Upfront):
  一次性: $348
  月均:   $29/月
  节省: $20.6/月 = $248/年
```

### Aurora Serverless v2（未来选项）

当业务增长到需要更大数据库时，Aurora Serverless v2 是值得考虑的选项：

```
Aurora Serverless v2:
  计费: $0.12/ACU-hour（1 ACU ≈ 2GB 内存）
  最小: 0.5 ACU
  最大: 可配置（如 16 ACU）

  低峰期: 0.5 ACU × $0.12 × 730h = $43.80/月
  高峰期: 按实际 ACU 收费

  vs 固定 RDS:
    流量波动大 → Aurora Serverless 更划算
    流量稳定   → 固定 RDS + RI 更划算

  当前 Optima 规模:
    db.t3.medium RI ≈ $32/月
    Aurora Serverless v2 最低 ≈ $44/月
    → 当前阶段不划算，等流量增长再考虑
```

### 读写分离

当单个 RDS 实例成为瓶颈时：

```
方案 1: RDS Read Replica
  主实例: 处理写入
  只读副本: 处理读取
  费用: 额外一个实例的费用
  适用: 读多写少的场景（商品查询、用户信息查询）

方案 2: 应用层缓存 (Redis)
  热数据缓存在 Redis，减少数据库读取
  Optima 已有 Redis ✅
  → 优先用 Redis 缓存降低 RDS 负载，比加副本便宜

优先级:
  1. 先优化慢查询（免费）
  2. 加 Redis 缓存（已有，边际成本低）
  3. RDS Read Replica（流量增长后再考虑）
```

---

## 成本可观测性

看不到的成本无法优化。

### AWS Cost Explorer

Cost Explorer 是 AWS 内置的免费工具，可以按服务、标签、时间维度分析成本。

```
核心功能:
  - 按月/日查看成本趋势
  - 按服务/资源类型分类
  - 按标签（需要先打标签）分组
  - 预测未来 3 个月成本
  - 识别成本异常

使用建议:
  - 每月初看上月账单，关注环比变化
  - 按服务分组，识别成本最高的服务
  - 关注"其他"类别，可能藏着意外费用
```

### Cost and Usage Report (CUR)

比 Cost Explorer 更详细的原始数据：

```
CUR 特点:
  - 每条计费记录都有（小时级别）
  - 导出到 S3，可以用 Athena 查询
  - 适合需要自定义分析的团队

是否需要:
  Optima 当前规模（~$185/月）→ Cost Explorer 足够
  当月账单 > $1000 时再考虑 CUR
```

### Cost Allocation Tags（成本分配标签）

这是成本可观测性的基石，**没有标签就无法按服务拆分账单**。

```
推荐的标签体系:

| 标签 Key | 值示例 | 用途 |
|---------|--------|------|
| Environment | prod, stage | 按环境分账 |
| Service | user-auth, commerce-backend | 按服务分账 |
| Project | optima | 按项目分账（多项目时有用） |
| Owner | infra, backend, frontend | 按团队分账 |
| CostCenter | engineering | 财务分摊 |

在 Terraform 中统一管理:

# modules/common/tags.tf
variable "environment" {}
variable "service" {}

locals {
  tags = {
    Environment = var.environment
    Service     = var.service
    Project     = "optima"
    ManagedBy   = "terraform"
  }
}
```

**重要**: 打完标签后需要在 AWS Billing Console 中**激活**这些标签，才能在 Cost Explorer 中作为分组维度使用。激活后需要 24 小时生效。

### Budget Alerts

自动告警，不用每天登录 AWS 看账单。

```
建议设置:

| Alert | 阈值 | 作用 |
|-------|------|------|
| 月度预算 80% | $160 | 提前预警 |
| 月度预算 100% | $200 | 到达预算 |
| 月度预算 120% | $240 | 超支告警 |
| 每日异常 | 日均 +50% | 发现异常飙升 |
```

```bash
# 创建异常检测告警（AWS Cost Anomaly Detection，免费）
aws ce create-anomaly-monitor \
  --anomaly-monitor '{
    "MonitorName": "optima-cost-monitor",
    "MonitorType": "DIMENSIONAL",
    "MonitorDimension": "SERVICE"
  }' \
  --region us-east-1  # Cost Explorer API 只在 us-east-1

aws ce create-anomaly-subscription \
  --anomaly-subscription '{
    "SubscriptionName": "optima-cost-alert",
    "MonitorArnList": ["<monitor-arn>"],
    "Subscribers": [{
      "Address": "your-email@example.com",
      "Type": "EMAIL"
    }],
    "Frequency": "DAILY",
    "ThresholdExpression": {
      "Dimensions": {
        "Key": "ANOMALY_TOTAL_IMPACT_ABSOLUTE",
        "Values": ["10"],
        "MatchOptions": ["GREATER_THAN_OR_EQUAL"]
      }
    }
  }' \
  --region us-east-1
```

---

## 多租户成本分摊

当平台服务多个客户或多个业务线时，需要知道"这个客户花了我们多少钱"。

### Showback vs Chargeback

| 方式 | 含义 | 适用场景 |
|------|------|---------|
| **Showback** | 告诉团队"你花了多少钱"，但不实际收费 | 内部团队、意识培养阶段 |
| **Chargeback** | 实际按使用量收费或分摊 | 多业务线、SaaS 平台 |

### 成本追踪方法

**按服务追踪**（适合 Optima 当前阶段）:

```
方法: Cost Allocation Tags + Cost Explorer

给每个 ECS Service、RDS 数据库、S3 Bucket 打 Service 标签
→ Cost Explorer 中按 Service 分组
→ 看到每个服务的成本占比

示例输出:
  user-auth:          $15/月（EC2 分摊 + RDS 分摊）
  commerce-backend:   $25/月（EC2 分摊 + RDS 分摊 + S3）
  mcp-host:           $18/月（EC2 分摊 + RDS 分摊）
  agentic-chat:       $22/月（EC2 分摊 + RDS 分摊 + 更多内存）
  共享基础设施:        $62/月（ALB + Redis + 网络 + 监控）
  Stage 环境:         $43/月
```

**按租户追踪**（SaaS 场景，未来可能需要）:

```
更复杂，需要:
  1. 应用层计量（每个 API 请求标记租户 ID）
  2. 按租户聚合资源使用量
  3. 分摊共享资源（按请求比例 or 按用户数比例）

工具:
  - 自建: CloudWatch Metrics + 自定义维度
  - 第三方: Kubecost（K8s）、CloudZero、Vantage
```

### 共享资源的分摊策略

Optima 的 RDS 和 Redis 是共享的，如何分摊？

```
方案 1: 平均分摊
  RDS $52/月 ÷ 5 个服务 = $10.4/服务
  简单但不准确

方案 2: 按连接数比例
  user-auth: 20 连接 (25%) → $13
  commerce-backend: 30 连接 (37.5%) → $19.5
  ...
  更准确但需要监控数据

方案 3: 按存储用量
  哪个库占的空间大就分摊多
  适合存储密集型场景

建议: 先用方案 1（简单），有数据后切到方案 2
```

---

## Optima 成本优化行动清单

按 ROI 排序，从最容易做的开始：

### 立刻可做（0 成本，1 小时内）

```
□ 在 Terraform 中给所有资源添加 Cost Allocation Tags
□ 在 AWS Billing Console 激活标签
□ 创建 $200/月的 Budget Alert
□ 启用 AWS Cost Anomaly Detection
□ 检查是否有未使用的弹性 IP（每个闲置 IP $3.6/月）
```

### 短期优化（1-2 天）

```
□ 给 S3 codedeploy-artifacts 添加生命周期策略
□ 给 S3 commerce-assets 启用 Intelligent-Tiering
□ 检查 Prod EC2 EBS 类型，如果是 gp2 升级到 gp3
□ 查看 CloudWatch 指标，评估 RDS 是否可以降级
□ 评估 S3 Gateway VPC Endpoint（减少出公网流量费）
```

### 中期优化（需要评估）

```
□ Prod EC2 + RDS 购买 1 年 Savings Plans（年省 $380+）
□ 非工作时间自动缩容 Stage 环境（如果不需要 7×24）
□ 评估 CloudFront 用于商品图片和静态资源
```

### 长期架构优化

```
□ 低频服务（user-auth）考虑 Serverless 化
□ 业务增长后评估 Aurora Serverless v2
□ 多租户成本追踪体系建设
```

---

## 推荐资源

### 必读

| 资源 | 类型 | 时间 | 说明 |
|------|------|------|------|
| [FinOps Foundation](https://www.finops.org/framework/) | 网站 | 2h | FinOps 框架官方定义，理解 Inform/Optimize/Operate |
| [AWS Well-Architected — Cost Optimization Pillar](https://docs.aws.amazon.com/wellarchitected/latest/cost-optimization-pillar/welcome.html) | 白皮书 | 3h | AWS 官方的成本优化最佳实践，系统全面 |
| [AWS Pricing Calculator](https://calculator.aws/) | 工具 | 按需 | 新资源上线前必算，养成习惯 |

### 工具推荐

| 工具 | 用途 | 费用 | 推荐度 |
|------|------|------|--------|
| [Infracost](https://www.infracost.io/) | Terraform PR 中显示成本变化 | 开源免费 | ⭐⭐⭐⭐⭐ 强烈推荐 |
| [AWS Compute Optimizer](https://aws.amazon.com/compute-optimizer/) | 自动推荐合适的实例类型 | 免费 | ⭐⭐⭐⭐ |
| [AWS Cost Anomaly Detection](https://aws.amazon.com/aws-cost-management/aws-cost-anomaly-detection/) | 自动检测异常费用 | 免费 | ⭐⭐⭐⭐ |
| [Kubecost](https://www.kubecost.com/) | Kubernetes 成本分析 | 开源/商业 | ⭐⭐⭐（用 K8s 时） |
| [Vantage](https://www.vantage.sh/) | 多云成本管理 | 免费起步 | ⭐⭐⭐ |

### Infracost 实战

Infracost 可以在 `terraform plan` 时自动计算成本变化，集成到 PR review 流程：

```bash
# 安装
curl -fsSL https://raw.githubusercontent.com/infracost/infracost/master/scripts/install.sh | sh

# 注册（免费）
infracost auth login

# 在 Terraform 目录运行
cd infrastructure/optima-terraform/stacks/environments/stage-ecs
infracost breakdown --path .

# 输出示例:
# NAME                              MONTHLY COST
# aws_instance.ecs_instances[0]     $38.54
# aws_db_instance.postgres          $49.64
# aws_elasticache_cluster.redis     $14.98
# ...
# TOTAL                             $185.32

# 对比两个 plan 的成本变化
infracost diff --path . --compare-to infracost-base.json
```

**集成到 GitHub Actions**（和 05-infrastructure-evolution.md 的 Terraform CI 配合）:

```yaml
# .github/workflows/infracost.yml
name: Infracost
on: [pull_request]

jobs:
  infracost:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: infracost/actions/setup@v3
        with:
          api-key: ${{ secrets.INFRACOST_API_KEY }}

      - name: Generate cost estimate
        run: |
          infracost breakdown --path infrastructure/optima-terraform/stacks \
            --format json --out-file /tmp/infracost.json

      - name: Post PR comment
        run: |
          infracost comment github --path /tmp/infracost.json \
            --repo $GITHUB_REPOSITORY \
            --pull-request ${{ github.event.pull_request.number }} \
            --github-token ${{ github.token }}
```

### 进阶阅读

| 资源 | 类型 | 说明 |
|------|------|------|
| [Cloud FinOps (O'Reilly)](https://www.oreilly.com/library/view/cloud-finops/9781492054610/) | 书 | FinOps 领域的权威书籍 |
| [The Duckbill Group Blog](https://www.duckbillgroup.com/blog/) | 博客 | AWS 成本优化的实战经验 |
| [Last Week in AWS Newsletter](https://www.lastweekinaws.com/) | 周报 | AWS 生态的吐槽和洞察，顺便学成本优化 |
| [AWS re:Invent Cost Optimization 相关 Session](https://www.youtube.com/results?search_query=aws+reinvent+cost+optimization) | 视频 | 每年都有新的成本优化实践分享 |

---

## 关键心智模型

```
1. "免费"不是真的免费
   → 数据传输、CloudWatch 日志存储、DNS 查询、IP 地址……处处有隐性费用

2. 优化的顺序：先看架构，再看资源，最后看折扣
   → 选错架构，省的那点 RI 折扣完全无意义

3. 成本是架构决策的输入，不是事后审计
   → 新服务上线前就应该算好成本，而不是月底看账单才后悔

4. 不要为了省钱牺牲可观测性
   → CloudWatch 日志和监控是你排查问题的基础，这不是该省的地方

5. 最大的浪费不是资源过配，而是解决问题的时间
   → 花 $10/月多一台 Redis 能让开发效率提升，远比省那 $10 有价值
```
