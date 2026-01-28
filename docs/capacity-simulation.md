# EC2 Warm Pool 容量策略模拟结果

## 模拟参数

| 参数 | 值 | 说明 |
|------|-----|------|
| 请求率 | 5 个/分钟 | 泊松分布 |
| 会话时长 | 30 分钟 | 指数分布 |
| 实例容量 | 4 个会话/实例 | t3.small |
| Warm Pool 启动时间 | 20 秒 | 实测数据 |
| 冷启动时间 | 180 秒 | 预估 |
| 模拟时长 | 8 小时 | 工作日 |

## 策略对比结果

| 策略 | 平均等待 | 最大等待 | 等待比例 | 月成本 |
|------|---------|---------|---------|-------|
| A: 保守 (70%触发, 2 Stopped) | 26ms | 48s | 0.1% | $295 |
| B: 激进 (50%触发, 3 Stopped) | 13ms | 16s | 0.1% | $412 |
| **C: Running预热 (1 Running)** | **0ms** | **0.6s** | **0%** | **$294** |
| **D: 混合 (1 Running + 2 Stopped)** | **0ms** | **0.6s** | **0%** | **$294** |
| E: 高可用 (2 Running + 2 Stopped) | 0ms | 0.6s | 0% | $343 |

## 详细分析

### 纯 Stopped 策略 (A, B)

- **优点**：成本最低（Stopped 状态只收 EBS 费用）
- **缺点**：少量请求需要等待 20 秒启动时间
- **适用场景**：对延迟不敏感的内部工具

### Running 预热策略 (C)

- **优点**：几乎零等待，启动时间 < 1 秒
- **缺点**：Running 实例有持续成本
- **适用场景**：对用户体验要求高的产品

### 混合策略 (D) - 推荐

- **配置**：1 个 Running + 2 个 Stopped 预热
- **优点**：
  - 正常情况下由 Running 实例即时响应
  - 突发流量由 Stopped 预热补充
  - 成本与纯 Stopped 策略相当
- **等待时间**：0ms（正常）/ 20s（极端突发）

### 高可用策略 (E)

- **配置**：2 个 Running + 2 个 Stopped 预热
- **优点**：最高可用性
- **缺点**：成本较高
- **适用场景**：高并发、高可用要求

## 推荐方案

**策略 D: 混合 (1 Running + 2 Stopped)**

理由：
1. 成本与最低成本策略相当
2. 正常情况下用户无感等待
3. 有足够的 Stopped 预热应对突发

### Terraform 配置

```hcl
# terraform.tfvars

# Running 预热：1 个实例常驻运行
ec2_asg_desired_capacity = 1

# Stopped 预热池
ec2_warm_pool_state    = "Stopped"
ec2_warm_pool_min_size = 2

# 扩容阈值：70% 利用率触发
# (通过 Capacity Provider managed scaling)
```

### 容量预留逻辑

```
正常状态:
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  Running    │  │  Stopped    │  │  Stopped    │
│  (预热1)    │  │  (预热2)    │  │  (预热3)    │
└─────────────┘  └─────────────┘  └─────────────┘
     ↓               ↓               ↓
   即时响应        20s启动         20s启动

突发流量:
1. 优先使用 Running 预热 → 0 等待
2. Running 用完，启动 Stopped → 20s 等待
3. Stopped 用完，冷启动 → 180s 等待（极少发生）
```

## 前端提示策略

基于模拟结果，建议的前端提示逻辑：

```typescript
interface CapacityEstimation {
  waitTime: number;  // 预估等待时间（毫秒）
  reason: 'available' | 'warm_starting' | 'cold_starting';
}

async function connectToSession() {
  const estimation = await api.getCapacityEstimation();

  if (estimation.waitTime > 5000) {
    // 等待 > 5 秒，显示提示
    const seconds = Math.ceil(estimation.waitTime / 1000);
    showLoadingMessage(`环境正在启动中，预计等待 ${seconds} 秒...`);
  }

  // 开始连接
  const session = await api.connect();
}
```

### 后端实现

```typescript
function getCapacityEstimation(): CapacityEstimation {
  const availableSlots = getAvailableSlots();

  if (availableSlots > 0) {
    return { waitTime: 0, reason: 'available' };
  }

  if (warmPoolRunning > 0) {
    return { waitTime: 3000, reason: 'warm_starting' };
  }

  if (warmPoolStopped > 0) {
    return { waitTime: 20000, reason: 'warm_starting' };
  }

  return { waitTime: 180000, reason: 'cold_starting' };
}
```

## 结论

1. **推荐策略 D**：1 Running + 2 Stopped 预热
2. **预估用户等待**：99%+ 请求无需等待
3. **前端提示阈值**：等待时间 > 5 秒时显示提示
4. **月度成本**：约 $294（含预热实例）

---

*生成时间：2026-01-27*
*模拟脚本：scripts/simulate-capacity.py*
