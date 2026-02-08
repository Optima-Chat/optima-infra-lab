# 01 - 可观测性体系

> 从 console.log 到 Observability 三大支柱

---

## 我们现在在哪

```
session-gateway 的日志现状：

ecs-bridge.ts    → this.log() 自定义 JSON       ← 最好的，但只有这一个文件
ws-handler.ts    → console.log('[Auth]', ...)    ← 文本前缀，无法机器解析
container-bridge → console.log(...)              ← 裸 log
index.ts         → console.log('[✓]', ...)       ← emoji 前缀
logger.ts        → 定义了 Logger 类但几乎没人用   ← 浪费了
```

问题不只是"格式不统一"，而是我们只有 Logs 这一个维度，且 Logs 本身质量也不够。

---

## 核心概念：Observability 三大支柱

### Logs（日志）

**你已经知道的**: 程序运行时输出文本信息，用于排查问题。

**你可能缺少的认知**:

- **结构化日志 vs 文本日志**: `console.log('[Auth] user logged in', userId)` 对人友好，但机器无法高效查询。结构化日志 `{"event": "auth_login", "userId": "xxx"}` 可以被 CloudWatch Logs Insights、Elasticsearch 等工具直接索引和聚合。

- **日志等级的真正含义**:
  - `DEBUG`: 开发调试用，生产环境关闭
  - `INFO`: 业务正常流转的关键节点（用户登录、session 创建、task 启动）
  - `WARN`: 非预期但可自动恢复的情况（重试成功、降级触发）
  - `ERROR`: 需要人工关注的错误（API 调用失败、数据不一致）

  常见错误：把所有东西都打成 INFO，或者把可恢复的重试打成 ERROR。

- **Correlation ID**: 一个请求在系统中流转时，所有相关日志携带同一个 ID（traceId/requestId）。这样你可以用一个 ID 过滤出完整链路。我们的代码里 import 了 `generateTraceId` 但没真正用起来。

### Metrics（指标）

**你目前完全没有的维度**。

指标是**聚合数据**：不关心单个请求发生了什么，关心的是"过去 5 分钟 P99 延迟是多少"、"当前错误率是多少"。

**核心概念 — RED 方法**（适用于服务端）:
- **R**ate: 每秒请求数
- **E**rrors: 错误请求的比例
- **D**uration: 请求延迟的分布（P50/P90/P99）

**对应到 AI Shell**:

| 指标 | 说明 | 当前状态 |
|------|------|---------|
| `session.create.rate` | 每分钟新建会话数 | 无 |
| `session.create.duration_p99` | 会话创建 P99 延迟 | 无（Phase 1 埋点后可从日志提取，但不是真正的 Metrics） |
| `task.start.error_rate` | Task 启动失败率 | 无 |
| `ws.connections.active` | 当前活跃 WebSocket 连接数 | 无 |
| `warm_pool.available` | 预热池可用 Task 数 | 无（Phase 3 才有） |

**Metrics vs Logs 的关系**:
- Logs 告诉你"这个请求出了什么问题"
- Metrics 告诉你"系统整体健康吗"
- 先看 Metrics 发现异常，再用 Logs 定位具体原因

**工具选择**:
- AWS 生态: CloudWatch Metrics（你已经在用 CloudWatch Logs，加 Metrics 很自然）
- 开源: Prometheus + Grafana（更强大，但需要运维）
- 对我们的规模，CloudWatch Custom Metrics 足够

### Traces（追踪）

**最难理解但价值最高的维度**。

一个用户消息从浏览器到 AI 回复，经过了多少个服务、每个服务花了多少时间？

```
用户发送消息
  └─ Web UI (5ms)
      └─ Session Gateway WS handler (2ms)
          └─ EcsBridge.sendToTask (1ms)
              └─ ws-bridge.js (3ms)
                  └─ optima-agent (1200ms)
                      └─ Anthropic API (1150ms)
                  └─ 回传结果 (5ms)
              └─ 转发到客户端 (1ms)
```

Trace 就是这棵调用树的可视化。每个节点叫一个 **Span**，所有 Span 共享一个 **Trace ID**。

**为什么重要**: 当用户说"回复好慢"，你需要知道是 Anthropic API 慢、还是 Task 启动慢、还是网络慢。没有 Traces，只能猜。

**OpenTelemetry (OTel)**: 这是当前的行业标准，提供了 Logs + Metrics + Traces 的统一 SDK。我们的 `@optima-chat/observability` 包已经引入了 OTel 的 tracing 模块，但没真正接入。

---

## 进阶概念

### SLI / SLO / Error Budget

- **SLI** (Service Level Indicator): 衡量服务质量的具体指标。例如"session 创建延迟 P99"。
- **SLO** (Service Level Objective): SLI 的目标值。例如"session 创建延迟 P99 < 10s"。
- **Error Budget**: 允许的失败空间。例如 SLO 99.5% 意味着每月允许 3.6 小时不达标。

**为什么重要**: 没有 SLO，你不知道什么时候该紧急修复、什么时候可以继续开发新功能。我们的排查报告说"21 次错误，10 个用户受影响"，但这算严重吗？没有 SLO 就无法回答。

**对应到 AI Shell**:

| SLI | SLO（建议） | 当前表现 |
|-----|------------|---------|
| Session 创建成功率 | 99.5% | ~96%（估算）|
| Session 创建 P99 延迟 | < 10s | ~15s（估算）|
| 消息首字延迟 P99 | < 5s | 未知 |
| 重连成功率 | 99% | ~50%（估算）|

### 告警策略

有了 Metrics 和 SLO，告警变得有意义：

```
告警规则设计原则：

好的告警 → 看到就要行动
  ✅ "session 创建成功率连续 5 分钟低于 99%"
  ✅ "活跃连接数超过 EC2 容量的 80%"

坏的告警 → 看多了就忽略（告警疲劳）
  ❌ "出现了一个 ERROR 日志"
  ❌ "CPU 使用率超过 50%"（50% 完全正常）
```

---

## 学习路径

### 第一步：理解概念（1-2天）

1. **OpenTelemetry 官方文档 — Concepts 部分**
   - https://opentelemetry.io/docs/concepts/
   - 重点: Signals (Traces, Metrics, Logs)、Context Propagation、SDK vs Collector
   - 不需要动手，理解概念就好

2. **Google SRE Book — Chapter 6: Monitoring Distributed Systems**
   - https://sre.google/sre-book/monitoring-distributed-systems/
   - 重点: 白盒 vs 黑盒监控、四个黄金信号（延迟、流量、错误、饱和度）

### 第二步：在项目中实践（3-5天）

这就是我们 Phase 1 要做的事，但做的时候带着上面的概念框架：

1. 结构化日志（已在计划中）
2. 在日志中加入 lifecycle event 和耗时（已在计划中）
3. **额外**: 用 CloudWatch Custom Metrics 上报 2-3 个关键 RED 指标
4. **额外**: 定义 1-2 个 SLO，用日报脚本跟踪

### 第三步：深入追踪（后续）

等 Phase 1 稳定后：
1. 把 `@optima-chat/observability` 的 tracing 真正接入
2. 在 session-gateway → ws-bridge → optima-agent 链路上传播 trace context
3. 用 AWS X-Ray 或 Jaeger 可视化调用链

---

## 推荐资源

| 资源 | 类型 | 时间 | 说明 |
|------|------|------|------|
| [OpenTelemetry Concepts](https://opentelemetry.io/docs/concepts/) | 文档 | 2h | 必读，理解三大支柱的统一框架 |
| [Google SRE Book Ch6](https://sre.google/sre-book/monitoring-distributed-systems/) | 书 | 3h | 监控的第一性原理 |
| [Charity Majors - Observability 系列博客](https://charity.wtf/) | 博客 | 碎片时间 | Honeycomb 创始人，Observability 布道者 |
| [AWS CloudWatch Metrics 文档](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/) | 文档 | 按需 | 我们的实现路径 |
| [The Art of SLOs](https://sre.google/workbook/implementing-slos/) | 书 | 2h | SLO 实操指南 |
