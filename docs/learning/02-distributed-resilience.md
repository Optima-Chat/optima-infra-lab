# 02 - 分布式系统容错模式

> 理解为什么竞态条件反复出现，以及怎样从根源上减少它们

---

## 我们现在在哪

Phase 0 修复了两个竞态问题：
1. Task 连接时 bridge 尚未注册 → "No ECS bridge found"
2. 旧 session 停止中，新 session 创建冲突

这两个修复都是 **case-by-case** 的：发现一个修一个。问题在于分布式系统中，竞态和故障的排列组合是指数级的，逐个修补永远修不完。

你需要的是一套**通用的容错模式**，在设计阶段就把它们内建到系统中。

---

## 核心模式

### 1. Retry with Exponential Backoff + Jitter

**问题**: 我们 Phase 0.2 的修复是固定间隔重试（100ms × 50 次）。

```typescript
// 当前方案（固定间隔）
for (let i = 0; i < 50; i++) {
  await sleep(100);  // 固定 100ms
  bridge = containerManager.getBridgeBySessionId(sessionId);
  if (bridge) break;
}
```

**为什么这不够好**:
- 固定间隔在高并发下会产生**惊群效应**（thundering herd）：假设 10 个 task 同时连接，它们会在完全相同的时间点重试，造成瞬间负载尖峰
- 没有区分"暂时性故障"和"永久性故障"

**最佳实践 — 指数退避 + 随机抖动**:

```typescript
async function retryWithBackoff<T>(
  fn: () => T | null,
  options: {
    maxRetries: number;
    baseDelay: number;    // 初始延迟，如 100ms
    maxDelay: number;     // 最大延迟，如 5000ms
  }
): Promise<T | null> {
  for (let attempt = 0; attempt < options.maxRetries; attempt++) {
    const result = fn();
    if (result) return result;

    // 指数退避: 100ms → 200ms → 400ms → 800ms → ...
    const exponentialDelay = options.baseDelay * Math.pow(2, attempt);

    // 加随机抖动: 避免多个调用方同时重试
    const jitter = Math.random() * exponentialDelay * 0.5;

    const delay = Math.min(exponentialDelay + jitter, options.maxDelay);
    await sleep(delay);
  }
  return null;
}
```

**什么时候用**: 任何你写 `sleep()` + 循环重试的地方，都应该用这个模式。

**延伸阅读**: AWS 架构博客 [Exponential Backoff And Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)

---

### 2. Circuit Breaker（熔断器）

**问题**: 当 ECS API（RunTask、DescribeTasks）持续返回错误时，我们的代码仍然会不断重试调用它。

**类比**: 家里的电路跳闸了，你不会一直尝试开灯——你知道要先去检查保险丝。

**三种状态**:

```
Closed（正常） → 请求正常通过
    ↓ 连续 N 次失败
Open（熔断） → 快速拒绝所有请求，不调用下游（避免雪崩）
    ↓ 等待 cooldown 时间
Half-Open（试探） → 允许少量请求通过
    ↓ 成功 → 回到 Closed
    ↓ 失败 → 回到 Open
```

**为什么重要**: 没有 Circuit Breaker，一个下游服务（如 ECS API）的故障会级联传播到你的整个系统。用户会看到长时间等待而非快速失败。

**对应到我们的系统**:

```typescript
// 没有 Circuit Breaker:
// ECS API 挂了 → 每个用户请求都等 30s 超时 → 所有 WebSocket 连接阻塞

// 有 Circuit Breaker:
// ECS API 连续失败 3 次 → 熔断 → 后续请求立即返回错误
// → 用户看到"服务暂时不可用，请稍后重试"
// → 30s 后试探一个请求 → ECS 恢复了 → 解除熔断
```

**实现**: 不需要自己写，用成熟的库如 [cockatiel](https://github.com/connor4312/cockatiel)（TypeScript）或 [opossum](https://github.com/nodeshift/opossum)。

---

### 3. Idempotency（幂等性）

**问题**: session resume 可能被触发多次。如果用户快速断开重连 3 次，会不会创建 3 个 ECS task？

**幂等性意味着**: 同一个操作执行 1 次和执行 N 次，效果完全相同。

**检查清单** — 对 AI Shell 中的关键操作:

| 操作 | 当前是否幂等 | 风险 |
|------|------------|------|
| 创建 session | ❓ 需检查 | 快速重连可能创建重复 session |
| 启动 ECS task | ❌ 不是 | 重复调用会启动多个 task |
| 创建 Access Point | ✅ 有缓存 | `ensureAccessPoint` 会先检查 |
| 注册 TaskDef | ❌ 不是 | 每次注册新 revision |
| 写 token.json | ✅ 覆盖写 | 自然幂等 |

**通用实现模式 — Idempotency Key**:

```typescript
// 每个操作附带唯一 key
async function startTaskIdempotent(sessionId: string): Promise<string> {
  // 先检查: 这个 session 是否已有运行中的 task
  const existing = this.getRunningTask(sessionId);
  if (existing) return existing.taskArn;

  // 没有才创建
  return this.runNewTask(sessionId);
}
```

**更严格的版本**: 用数据库记录操作状态（pending → running → completed），利用数据库的唯一约束防止并发创建。

---

### 4. Graceful Degradation（优雅降级）

**问题**: 预热池空了怎么办？EFS 挂载失败怎么办？Anthropic API 限流了怎么办？

**当前做法**: 要么成功，要么报错。没有中间状态。

**优雅降级意味着**: 系统在部分组件故障时，仍能提供有限但有用的服务。

**对应到 AI Shell 的降级链**:

```
理想路径:
  预热池 → 260ms 就绪 → 完整功能

降级路径 1 (预热池空):
  冷启动 → 3-5s 就绪 → 完整功能
  用户感知: "启动稍慢，但一切正常"

降级路径 2 (ECS API 限流):
  排队等待 → 延迟更高 → 完整功能
  用户感知: "等待中...（第 3 位）"

降级路径 3 (EFS 不可用):
  无持久化模式 → 用户文件不保存 → 基本对话可用
  用户感知: "注意: 文件保存暂时不可用"

降级路径 4 (Anthropic API 不可用):
  → 明确告知用户
  用户感知: "AI 服务暂时不可用，请稍后重试"
```

**关键思想**: 在设计每个功能时，就考虑"如果这个依赖挂了，我还能提供什么"。而不是等故障发生再想办法。

---

### 5. Timeout 的正确使用

**问题**: 你的代码中有各种 timeout（restartTask 30s、waitForRestore 3s、WS 连接超时等），但设置这些数字时可能缺少系统性思考。

**Timeout 设计原则**:

```
整体 Timeout > 各环节 Timeout 之和 + 缓冲

例如 session 创建的 timeout 链:
  ensureAccessPoint     2s
  registerTaskDef       2s
  runTask               1s
  waitForRunning        10s
  waitForConnection     5s
  ─────────────────────
  各环节之和            20s
  + 缓冲 50%           10s
  ─────────────────────
  整体 timeout          30s  ← 这个数字应该是算出来的，不是拍脑袋的
```

**常见错误**:
- 整体 timeout 小于各环节之和 → 某个环节还在重试时整体已超时
- 没有 timeout → 某个 await 永远不返回，连接永远挂着
- Timeout 太短 → 正常请求被误杀，成功率下降

**进阶**: Deadline Propagation（截止时间传播）。把整体 deadline 传递给每个子调用，让它们自己判断还有没有足够时间完成。

```typescript
async function startSession(deadline: number) {
  const remaining = () => deadline - Date.now();

  if (remaining() < 0) throw new Error('Deadline exceeded');

  // 每个子操作使用剩余时间，而非固定 timeout
  await ensureAccessPoint({ timeout: Math.min(remaining(), 2000) });
  await runTask({ timeout: Math.min(remaining(), 5000) });
  await waitForConnection({ timeout: remaining() });
}
```

---

## 关键书籍：DDIA 第 8-9 章

### 第 8 章: 分布式系统中的麻烦 (The Trouble with Distributed Systems)

核心观点：**在分布式系统中，任何可能出错的事情都会出错。**

这章讲的问题你在 AI Shell 中都遇到过：
- **网络不可靠**: WebSocket 断开、ECS API 超时
- **时钟不可靠**: 不同容器的时间可能不一致
- **进程可能暂停**: GC、CPU 抢占导致的"假死"
- **部分失败**: 3 个 ECS task 中有 1 个启动失败

读完后你会意识到：Phase 0 修的那些 bug 不是"代码写错了"，而是分布式系统的本质属性。关键不是"避免所有故障"，而是"在故障发生时系统如何表现"。

### 第 9 章: 一致性与共识 (Consistency and Consensus)

核心问题：**当多个组件对系统状态的认知不一致时，怎么办？**

对应到 AI Shell：
- Session Gateway 认为 task 在运行，但实际上已经停了（状态不一致）
- containerManager 还没注册 bridge，但 task 已经连接过来了（时序不一致）
- 两个 Gateway 实例（如果有多副本）对同一个 session 的状态认知不同

这章的解决方案（线性一致性、全序广播、共识算法）可能超出当前需要，但理解**问题的本质**非常有价值。

---

## 实践路线

### 立即可做（结合 Phase 0）

1. 把 Phase 0.2 的固定间隔重试改为指数退避 + jitter
2. 在 `restartTask` 中增加幂等检查：如果已经在重启中，不重复触发
3. 审计所有 timeout 值，确保符合上面的"加法原则"

### 短期（1-2 周）

4. 引入 Circuit Breaker 库（cockatiel），包装 ECS API 调用
5. 定义降级策略文档：每个外部依赖挂掉时，用户看到什么

### 中期（Phase 3 时）

6. 预热池的并发分配需要幂等设计（两个请求同时获取预热 task）
7. WarmPoolManager 需要 Circuit Breaker（ECS RunTask 补充失败时不要无限重试）

---

## 推荐资源

| 资源 | 类型 | 时间 | 说明 |
|------|------|------|------|
| **DDIA 第 8-9 章** | 书 | 2-3 天 | **最高优先级**，改变你思考分布式系统的方式 |
| [AWS Exponential Backoff And Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/) | 博客 | 30min | 重试策略的权威指南 |
| [Release It! (2nd Edition)](https://pragprog.com/titles/mnee2/release-it-second-edition/) | 书 | 1 周 | Circuit Breaker 等模式的出处，大量真实故障案例 |
| [cockatiel README](https://github.com/connor4312/cockatiel) | 文档 | 1h | TypeScript 的 Resilience 库，看看它提供了哪些模式 |
| [Martin Fowler - Circuit Breaker](https://martinfowler.com/bliki/CircuitBreaker.html) | 博客 | 20min | 经典的模式解释 |
