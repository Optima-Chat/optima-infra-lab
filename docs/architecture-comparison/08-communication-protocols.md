# Agent 通信协议对比分析

> 分析 OpenClaw 及业界 AI Agent 平台的 Gateway ↔ Agent 通信方式，对比 Optima 的 WebSocket 方案。

## 一、核心发现

**业界没有单一最优协议，2025-2026 的共识是分层混合架构。**

不同层级适合不同协议：

```
Layer 1: 客户端 → Gateway     → WebSocket 或 HTTP+SSE
Layer 2: Gateway → Agent 容器  → WebSocket / stdin-stdout / 消息队列 / 进程内嵌入
Layer 3: Agent → Agent (编排)  → gRPC 或 A2A 协议
Layer 4: Agent → 工具          → MCP (stdio 本地 / HTTP 远程)
```

## 二、各平台通信架构一览

| 平台 | 客户端→Gateway | Gateway→Agent | Agent 内部 | 序列化 |
|------|---------------|---------------|-----------|--------|
| **Optima** | WebSocket | WebSocket (跨容器) | Headless stdin/stdout | JSON |
| **OpenClaw** | WebSocket JSON-RPC | **进程内函数调用** (EventEmitter) | Pi SDK 直接调用 | JSON (TypeBox) |
| **OpenCode** | HTTP + SSE | 同进程 | Vercel AI SDK | JSON |
| **Claude Code** | N/A (本地 CLI) | stdin/stdout JSONL | JSON-RPC 2.0 | JSON-lines |
| **Cursor** | HTTP/2 ConnectRPC | N/A (云端单体) | Protobuf 二进制 | Protobuf |
| **Devin** | Web UI (WS/SSE) | VM 内直接执行 | Shell/文件系统 | JSON |
| **OpenHands** | WebSocket + REST | EventStream (进程内或远程 WS) | JSON Events | JSON |
| **AWS AgentCore** | HTTP (8080端口) | stdin/stdout (MicroVM 内) | JSON-lines | JSON |

## 三、OpenClaw 的通信架构

### 关键事实：Gateway 和 Pi Agent 在同一进程

OpenClaw **不使用任何 IPC** 与 Pi Agent 通信。Pi 通过 `createAgentSession()` 直接嵌入 Gateway 进程：

```
外部客户端 ←WebSocket→ Gateway 进程
                          │
                          │ (进程内函数调用，零开销)
                          │
                       Pi Agent Session
                          │
                          │ (EventEmitter 事件)
                          │
                       subscribeEmbeddedPiSession()
                          │
                          │ (映射为 WebSocket event frames)
                          ↓
                       推送给客户端
```

### WebSocket JSON-RPC 协议

外部客户端通过 WebSocket 连接 Gateway（默认 `ws://127.0.0.1:18789`），使用类型化 JSON 帧：

```typescript
// 请求帧
{ "type": "req", "id": "1", "method": "chat.send", "params": { "text": "hi" } }

// 响应帧
{ "type": "res", "id": "1", "ok": true, "result": { "runId": "r_123" } }

// 事件帧（服务端推送）
{ "type": "event", "event": "agent.delta", "payload": { "runId": "r_123", "delta": "..." } }
```

**协议规则**：
- 首帧必须是 `connect` 握手
- 所有帧用 TypeBox schema 校验
- 副作用方法需要幂等键
- Agent 响应分两阶段：立即 `accepted` ACK → 流式事件 → 最终 `ok`/`error`

### 流式响应

```
Pi Agent 生成 token
    ↓
subscribeEmbeddedPiSession() 捕获 assistant delta
    ↓
缓冲 + 分块为 agent.delta 事件
    ↓
WebSocket 推送给已连接客户端
```

**非 WebSocket 渠道**（WhatsApp、Telegram 等）：Gateway 缓冲完整响应后一次性发送（这些平台不支持流式）。

### 多渠道适配

```
WhatsApp (Baileys)  ──┐
Telegram (grammY)   ──┤
Slack (SDK)         ──┤──→ InboundContext (统一格式) ──→ Session Router ──→ Pi Agent
Discord             ──┤
Signal              ──┤
WebChat (WebSocket) ──┘
```

所有渠道适配器作为**插件运行在 Gateway 进程内**，不是独立微服务。

## 四、Optima 的通信架构

### 双 WebSocket 设计

```
浏览器 ←Client WS→ session-gateway ←Task WS→ 容器 (ai-shell)
                                                  ↓
                                            ws-bridge.js ←stdin/stdout→ optima-agent
```

实际上 Optima 的通信经过**三层**：

| 层级 | 协议 | 说明 |
|------|------|------|
| 浏览器 → session-gateway | WebSocket | Client WS，客户端主动连接 |
| session-gateway → 容器 | WebSocket | Task WS，容器主动**反连**网关 |
| ws-bridge.js → optima-agent | stdin/stdout JSON | 进程间管道 |

### 为什么是容器反连？

容器不暴露端口，而是主动连接回 Gateway 的内部端点 `/internal/task/{sessionId}`。这样：
- 网关是唯一入口（安全）
- 容器无需固定 IP 或端口映射
- 支持 WarmPool（预热容器提前连接 `/internal/warm/{taskId}`）

## 五、六种通信模式深度对比

### 1. WebSocket（双向持久连接）

**使用者**：Optima、OpenClaw（客户端层）、Liveblocks、E2B

| 优势 | 劣势 |
|------|------|
| 真正双向通信：Gateway 和 Agent 都可以主动发消息 | 有状态连接，扩展困难（每连接占用内存/文件描述符）|
| 低帧开销（握手后每帧仅 ~2 字节头）| 负载均衡器需要粘性会话 |
| 天然适合长时间 Agent 任务 | 重连逻辑复杂（状态恢复、消息重放）|
| 支持人在环路（AskUserQuestion）| 防火墙/代理可能阻止 Upgrade |
| 实时状态同步 | 不享受 HTTP/2 多路复用、CDN 缓存 |

**最适合**：多轮对话、人在环路、协作编辑、需要双向控制信号的长任务

### 2. stdin/stdout JSON（管道/子进程）

**使用者**：Claude Code、Claude Agent SDK、MCP 服务器、AWS AgentCore（内部）

| 优势 | 劣势 |
|------|------|
| 零网络开销（最快的 IPC，仅次于共享内存）| 仅限同一机器（不能跨网络）|
| 进程隔离（Agent 崩溃不影响宿主）| 不适合多租户（每用户一进程）|
| 无需端口管理、网络配置、服务发现 | 无内置重连（进程死亡 = 状态丢失）|
| 天然适合 CLI 工具和 CI/CD | 调试困难（没有浏览器 DevTools）|
| 易于组合子 Agent | 管道缓冲区有 OS 限制 |

**最适合**：CLI 工具、CI/CD 集成、子进程 Agent 编排、单租户部署

**关键洞察**：AWS AgentCore 的做法很有意思——**外部暴露 HTTP（8080端口），内部用 stdin/stdout**。Firecracker MicroVM 内部是 stdin/stdout 管道，外部调用通过 HTTP 翻译。这跟 Optima 的"ws-bridge.js 桥接 WebSocket ↔ stdin/stdout"异曲同工。

### 3. HTTP + SSE（服务端推送事件）

**使用者**：OpenCode、OpenAI API、Google A2A 协议、大多数 LLM API

| 优势 | 劣势 |
|------|------|
| HTTP 原生（负载均衡器/CDN/防火墙/监控全兼容）| 单向（服务端推送，客户端需单独 POST）|
| 浏览器 EventSource API 自带重连 | 频繁双向交互需两个通道（POST + SSE）|
| 可扩展（单服务器 10K 连接 < 5% CPU）| 浏览器限制每域名 ~6 个 SSE 连接 |
| 标准 HTTP 监控和日志 | 仅支持文本（二进制需 Base64）|
| 天然适合 token-by-token 流式 | 无背压机制 |

**最适合**：LLM 响应流式推送、进度更新、单向通知

**SSE 对 Agent 场景的局限**：Agent 对话是频繁双向的（用户发消息 → AI 回复 → 工具调用 → 工具结果 → 继续 → 用户取消/回答问题）。用 SSE 就需要 POST 发消息 + SSE 收流，两个通道增加复杂度。

### 4. gRPC（HTTP/2 + Protocol Buffers）

**使用者**：Google A2A 协议 v0.3+、Cursor（ConnectRPC 变体）、Vertex AI 内部

| 优势 | 劣势 |
|------|------|
| 最低网络延迟（二进制编码 + HTTP/2 多路复用）| 浏览器不能直接用（需 gRPC-Web 代理）|
| 强类型（编译时检查，自动生成客户端/服务端）| Proto 文件管理和代码生成流水线 |
| 原生双向流 | 二进制格式不可读，调试需专用工具 |
| 天然适合微服务网格（Istio/Envoy）| 对简单场景过度工程化 |
| 支持 deadline 传播和健康检查 | 团队学习成本 |

**最适合**：内部服务间通信、Agent 编排器 → 模型/工具后端、对类型安全和性能有极高要求的企业平台

### 5. 消息队列（Redis / NATS / RabbitMQ）

**使用者**：企业多 Agent 编排平台、Redis 官方推荐的 AI Agent 架构

| 优势 | 劣势 |
|------|------|
| 解耦扩展（Gateway 和 Agent 独立扩缩）| 需要部署和运维消息中间件 |
| 持久化（Streams/JetStream 可重放）| 多一跳网络延迟 (1-5ms) |
| 扇出模式（一条消息多 Agent 消费）| 简单场景过度工程化 |
| 亚毫秒延迟（Redis）| 需要监控队列深度和消费滞后 |
| 天然适合异步长任务 | 消息顺序保证因实现而异 |

**最适合**：多 Agent 编排、高吞吐多租户、需要持久化和重放的场景

### 6. 进程内嵌入（函数调用）

**使用者**：OpenClaw（嵌入 Pi）、LangChain、CrewAI、OpenHands（LocalConversation）

| 优势 | 劣势 |
|------|------|
| 零延迟（直接函数调用，无序列化）| **无故障隔离**（Agent 崩溃 = Gateway 崩溃）|
| 最简集成（无协议、无网络配置）| 语言锁定（必须同一运行时）|
| 共享类型系统（编译时检查）| **无法独立扩展**（Agent 和 Gateway 共享计算资源）|
| 资源高效（无重复运行时开销）| **多租户极难隔离** |
| 标准调试器/分析器直接可用 | Agent 阻塞操作可能卡死 Gateway 事件循环 |

**最适合**：原型开发、单租户应用、延迟极致要求的场景

## 六、Optima vs OpenClaw：通信层对比

| 维度 | Optima (WebSocket 跨容器) | OpenClaw (进程内嵌入) |
|------|--------------------------|---------------------|
| **Gateway→Agent 延迟** | ~3-10ms (WebSocket 网络) | ~0ms (函数调用) |
| **故障隔离** | ✅ Agent 崩溃不影响 Gateway | ❌ Agent 崩溃 = Gateway 崩溃 |
| **独立扩展** | ✅ Agent 容器独立扩缩 | ❌ 共享同一进程资源 |
| **多租户隔离** | ✅ EFS Access Point + 容器隔离 | ⚠️ 单 workspace 目录 |
| **资源效率** | 中等（每用户一个容器 + WS 连接）| 高（共享进程，无序列化开销）|
| **重连恢复** | ✅ 状态机 + 消息队列 + restore | 无需（同进程不会"断连"）|
| **实现复杂度** | 高（双 WS、消息队列、状态机）| 低（直接调函数）|
| **调试** | 较难（跨进程/容器）| 容易（同进程调试器）|
| **并发用户上限** | 高（ECS Auto Scaling）| 低（单进程内存/CPU 瓶颈）|

### 关键洞察

**OpenClaw 的选择是正确的——对于它的场景**。OpenClaw 是个人助手（单用户），Gateway 运行在本地机器上，Agent 不需要独立扩展。进程内嵌入是最简单最快的方案。

**Optima 的选择也是正确的——对于它的场景**。Optima 是多租户 SaaS 平台，需要用户隔离、弹性伸缩、故障隔离。WebSocket 跨容器通信虽然复杂，但这是生产多租户系统的必要代价。

## 七、Optima 通信层改进建议

### 当前痛点

1. **双 WebSocket 链路长**：浏览器 → Gateway（WS）→ 容器（WS）→ ws-bridge（stdin/stdout），共 3 层翻译
2. **WebSocket 扩展限制**：每个连接有状态，ALB 需要粘性会话
3. **重连复杂**：断线后需要状态恢复、消息重放、Session 恢复

### 改进方案 A：客户端层改用 HTTP+SSE（推荐评估）

```
当前: 浏览器 ←WebSocket→ Gateway ←WebSocket→ 容器
改进: 浏览器 ←HTTP POST(发) + SSE(收)→ Gateway ←WebSocket→ 容器
```

**好处**：
- 客户端层变成无状态 HTTP，负载均衡器和 CDN 友好
- SSE 自带重连（EventSource API）
- 标准 HTTP 监控/日志
- 不影响 Gateway→Agent 容器的 WebSocket（保持双向）

**代价**：
- 需要两个通道（POST 发消息 + SSE 收流）
- AskUserQuestion 等双向交互需要轮询或额外 POST

**适用条件**：如果前端交互以"发消息→等响应"为主，SSE 足够。如果人在环路（AskUserQuestion）很频繁，WebSocket 更合适。

### 改进方案 B：Gateway→Agent 改用消息队列

```
当前: Gateway ←WebSocket→ 容器
改进: Gateway → Redis Streams → 容器
                容器 → Redis Streams → Gateway
```

**好处**：
- 解耦 Gateway 和 Agent 容器的生命周期
- 消息持久化（容器重启不丢消息）
- 天然支持多 Gateway 实例
- 简化 WarmPool 设计（预热容器订阅通用 channel）

**代价**：
- 多一跳延迟 (1-5ms)
- 需要 Redis/NATS 基础设施
- 增加运维复杂度

**适用条件**：当并发用户达到数百级别，或需要多 Gateway 实例时值得考虑。

### 改进方案 C：保持现有架构（推荐短期）

当前的双 WebSocket 设计虽然复杂，但经过生产验证且能力完整。**短期内不需要改动通信层**，应该优先解决 Agent 层问题（替换 Claude Agent SDK）。

通信层改进可以在以下时机推进：
- 并发用户增长到需要多 Gateway 实例时 → 考虑方案 B
- 前端需要支持更多客户端类型时（移动端、CLI）→ 考虑方案 A

### 如果用 Pi 替换 Agent 层

用 Pi 替换 Claude Agent SDK 后，通信层有两种选择：

**选择 1：保持容器化 + WebSocket（推荐）**

```
Gateway ←WS→ 容器 (ws-bridge.js ←stdin/stdout→ pi-agent RPC 模式)
```
- ws-bridge.js 改为与 Pi RPC 协议对接（而不是 Claude Headless 协议）
- Gateway 无需修改
- 保持多租户隔离优势

**选择 2：进程内嵌入 Pi（不推荐）**

```
Gateway (直接嵌入 pi-agent-core)
```
- 学 OpenClaw 直接在 Gateway 进程内运行 Pi
- 失去容器隔离、独立扩缩、WarmPool 等所有云原生优势
- 仅适合开发/测试环境

## 八、总结

| 问题 | 答案 |
|------|------|
| OpenClaw 怎么做通信的？ | Gateway 和 Pi Agent **同进程**，函数调用 + EventEmitter，零网络开销 |
| 我们的 WebSocket 方案对不对？ | **对**。多租户 SaaS 需要容器隔离和独立扩缩，WebSocket 是合理选择 |
| OpenClaw 为什么不用 WebSocket？ | 因为它是单用户本地工具，不需要隔离和扩缩 |
| 我们需要改通信层吗？ | **短期不需要**。优先替换 Agent 层（Claude SDK → Pi）。通信层改进等规模增长后再评估 |
| 业界最佳实践是什么？ | 分层混合：客户端用 HTTP+SSE 或 WS，Gateway→Agent 用 WS 或消息队列，Agent 间用 gRPC |
