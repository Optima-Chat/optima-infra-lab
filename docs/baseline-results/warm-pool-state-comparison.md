# Warm Pool 状态对比分析

> **日期**: 2026-01-28
> **结论**: Hibernated 是最佳选择，17s 作为 fallback 路径可接受

---

## 三种状态对比

| 状态 | 唤醒时间 | 月成本 (2台) | 适用场景 |
|------|---------|-------------|---------|
| **Running** | ~1-5s | ~$36 | 追求极致速度 |
| **Hibernated** | ~17s | ~$4.8 | **推荐** - 平衡速度和成本 |
| **Stopped** | ~30-40s | ~$4.8 | 极致省钱 |

## 为什么不用 Running 状态

Running 状态意味着 EC2 一直运行，但：

1. **EC2 运行 ≠ Task 预热** - 实例运行着，但上面的 Task 还是冷的
2. **我们已经有热池 Task** - Phase A 的 280ms 直接分配
3. **成本高** - 相当于多付一台 EC2 的费用

## 正确的架构

```
用户请求
    ↓
热池有 Task? ─── 是 ──→ 直接分配 (280ms) ✅ 主路径
    │
    否
    ↓
唤醒 Hibernated EC2 (17s) ← fallback
    │
    ↓
启动新 Task
```

**核心思路**:
- 主路径: 热池 Task 直接分配 (~280ms)
- Fallback: Hibernated EC2 唤醒 (~17s)
- 最差情况: 冷启动 (~80s)

## Hibernated 的 17s 构成

| 阶段 | 耗时 | 说明 |
|------|------|------|
| 内存恢复 | ~5s | 从 EBS 加载休眠内存 |
| 系统恢复 | ~3s | 网络、时钟同步 |
| ECS Agent 注册 | ~5s | 重新连接 ECS 集群 |
| ASG 健康检查 | ~4s | 确认实例健康 |
| **总计** | **~17s** | 无法优化 |

## 结论

1. **Hibernated 是最佳选择** - 17s 唤醒 + 低成本
2. **17s 作为 fallback 可接受** - 主路径是 280ms
3. **不需要 Running 状态** - 多花钱但没明显收益
4. **优化重点应在热池** - 确保热池 Task 充足，减少 fallback 频率

## 配置

```hcl
# terraform/variables.tf
variable "ec2_warm_pool_state" {
  default = "Hibernated"  # 推荐
}
```
