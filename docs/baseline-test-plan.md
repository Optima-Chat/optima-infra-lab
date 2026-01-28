# 启动时间基线测试计划

> **目标**: 建立每个环节的基线数据，然后逐环节优化
> **创建日期**: 2026-01-28

---

## 测试环节概览

| 环节 | 描述 | 当前估算 | 优化目标 |
|------|------|---------|---------|
| **A** | 热池 Task 分配 | ~260ms | < 500ms |
| **B** | EC2 Warm → InService | ~15-22s | < 15s |
| **C** | EC2 冷启动 → Warm Pool | ~2-3min | < 90s |

---

## 环节 A: 热池 Task 分配

### 定义

预热 Task 已在 EC2 上运行，收到用户请求后分配并初始化。

### 测试内容

| 子环节 | 描述 | 测试方法 |
|--------|------|---------|
| A1 | Gateway 内存分配 | Mock Gateway 测量 |
| A2 | WebSocket 消息传递 | 网络延迟测量 |
| A3 | EFS 目录创建 | `mkdir -p` 延迟 |
| A4 | 配置文件写入 | 写 token.json 延迟 |
| A5 | optima 进程启动 | `optima headless` 启动时间 |

### 当前基线（已测）

```
A1 Gateway 分配:     ~1ms   (内存操作)
A2 WebSocket 消息:   ~5ms   (局域网)
A3 EFS mkdir:        ~14ms  (5次平均)
A4 EFS write:        ~10ms  (5次平均)
A5 optima 启动:      ~250ms (3次平均)
─────────────────────────────
总计:                ~280ms
```

### 优化手段（待测）

| 优化项 | 预期效果 | 优先级 |
|--------|---------|--------|
| 预创建用户目录 | A3 降为 0 | 中 |
| optima 预加载 | A5 降为 ~50ms | 高 |
| EFS Provisioned Throughput | A3/A4 更稳定 | 低 |

---

## 环节 B: EC2 Warm → InService

### 定义

Warm Pool 中的 EC2 实例（Hibernated/Stopped）被唤醒并注册到 ECS 集群。

### 测试内容

| 子环节 | 描述 | 测试方法 |
|--------|------|---------|
| B1 | EC2 唤醒 | Hibernated → running |
| B2 | 健康检查通过 | running → InService |
| B3 | ECS Agent 注册 | Agent → 集群 |
| B4 | Task 调度 | Service 调度 Task |
| B5 | Task 启动 | PENDING → RUNNING |

### 当前基线（待测）

需要分别测试：
- Hibernated 状态启动时间
- Stopped 状态启动时间（对照）

### 测试脚本

```bash
# 测试 B 环节
./scripts/test-ec2-warm-start.sh
```

### 优化手段（待测）

| 优化项 | 预期效果 | 优先级 |
|--------|---------|--------|
| Hibernated vs Stopped | Hibernated 快 5-10s | 高 |
| gp3 高 IOPS | 减少 EBS 延迟 | 中 |
| 精简 User Data | 减少启动脚本时间 | 中 |
| 禁用不必要服务 | 减少 systemd 启动时间 | 低 |

---

## 环节 C: EC2 冷启动 → Warm Pool

### 定义

全新 EC2 实例从创建到进入 Warm Pool 的完整流程。

### 测试内容

| 子环节 | 描述 | 测试方法 |
|--------|------|---------|
| C1 | EC2 实例启动 | pending → running |
| C2 | 实例状态检查 | status checks passed |
| C3 | User Data 执行 | cloud-init 完成 |
| C4 | EBS 预热 | lazy loading 完成 |
| C5 | Docker 镜像就绪 | 镜像拉取/缓存 |
| C6 | ECS Agent 注册 | Agent 连接集群 |
| C7 | 进入 Warm Pool | InService → Warmed:* |

### 当前基线（待测）

预估 2-3 分钟，需要实测各子环节。

### 测试脚本

```bash
# 测试 C 环节（需要新建）
./scripts/test-ec2-cold-start.sh
```

### 优化手段（待测）

| 优化项 | 预期效果 | 优先级 |
|--------|---------|--------|
| Golden AMI | C3/C4/C5 大幅缩短 | 高 |
| 更大实例类型 | 加速所有环节 | 中 |
| 禁用 cloud-init 模块 | C3 缩短 | 中 |
| EBS 预热脚本 | C4 在 Warm Pool 中完成 | 低 |

---

## 测试执行计划

### Phase 1: 建立基线 (今天)

```
1. 环节 A 基线 ✅ 已完成 (~280ms)
2. 环节 B 基线
   - [ ] Hibernated 状态启动测试
   - [ ] Stopped 状态启动测试（对照）
3. 环节 C 基线
   - [ ] 完整冷启动测试
   - [ ] 各子环节分解测量
```

### Phase 2: 环节 A 优化

```
- [ ] 测试 optima 预加载方案
- [ ] 测试预创建用户目录
```

### Phase 3: 环节 B 优化

```
- [ ] 确认 Hibernated vs Stopped 差异
- [ ] 测试精简 User Data
- [ ] 测试 gp3 IOPS 调整
```

### Phase 4: 环节 C 优化

```
- [ ] 设计 Golden AMI 构建流程
- [ ] 测试 Golden AMI 效果
- [ ] 测试禁用 cloud-init 模块
```

### Phase 5: 策略优化

```
- [ ] 预热池大小策略
- [ ] 扩缩容阈值调优
- [ ] 成本 vs 延迟权衡分析
```

---

## 测试环境

| 项目 | 值 |
|------|---|
| 区域 | ap-southeast-1 |
| ECS 集群 | fargate-warm-pool-test |
| 实例类型 | t3.small |
| Warm Pool 状态 | Hibernated |
| EFS | General Purpose, Elastic |

---

## 数据记录模板

每次测试记录：

```markdown
### 测试: [环节X] - [测试名称]

**日期**: YYYY-MM-DD HH:MM
**条件**: [描述测试条件]

| 指标 | 值 | 备注 |
|------|---|------|
| ... | ... | ... |

**观察**:
- ...

**下一步**:
- ...
```
