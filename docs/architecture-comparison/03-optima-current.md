# Optima 当前架构详解

> 项目: Optima AI Agent 平台
> 定位: 电商垂直领域 AI Agent
> 技术栈: TypeScript / Node.js 20 / Next.js 15 / Claude Agent SDK

## 一、三层架构概览

Optima 的 AI Agent 系统由三个独立服务组成，形成清晰的分层架构：

```
┌─────────────────────────────────────────────────────────┐
│                    agentic-chat                          │
│              (Next.js 15 前端 + BFF)                     │
│  ┌──────────┐ ┌──────────────┐ ┌─────────────────┐     │
│  │ Chat UI  │ │ WebSocket    │ │ Zustand Store   │     │
│  │ (React)  │ │ Client       │ │ (State Mgmt)    │     │
│  └────┬─────┘ └──────┬───────┘ └────────┬────────┘     │
│       └──────────────┼──────────────────┘               │
│                      │ WebSocket + HTTP                  │
└──────────────────────┼──────────────────────────────────┘
                       │
┌──────────────────────┼──────────────────────────────────┐
│              session-gateway                             │
│           (Node.js WebSocket 网关)                        │
│  ┌──────────┐ ┌──────────────┐ ┌─────────────────┐     │
│  │ WS Mgmt  │ │ Execution    │ │ PostgreSQL      │     │
│  │ & Auth   │ │ Bridge       │ │ (Prisma)        │     │
│  └────┬─────┘ └──────┬───────┘ └────────┬────────┘     │
│       │              │                   │               │
│  ┌────┴─────┐ ┌──────┴───────┐ ┌────────┴────────┐     │
│  │WarmPool  │ │TokenPool     │ │SessionCleanup   │     │
│  └──────────┘ └──────────────┘ └─────────────────┘     │
│                      │ Docker / ECS / Lambda / AgentCore │
└──────────────────────┼──────────────────────────────────┘
                       │
┌──────────────────────┼──────────────────────────────────┐
│              optima-agent (容器内)                        │
│           (Claude Agent SDK 封装)                         │
│  ┌──────────┐ ┌──────────────┐ ┌─────────────────┐     │
│  │ Claude   │ │ Skill Files  │ │ Memory MCP      │     │
│  │ SDK      │ │ (.md)        │ │ Server          │     │
│  └────┬─────┘ └──────┬───────┘ └────────┬────────┘     │
│       │              │                   │               │
│  ┌────┴─────┐ ┌──────┴───────┐ ┌────────┴────────┐     │
│  │Headless  │ │ws-bridge.js  │ │ConversationMgr  │     │
│  │Protocol  │ │(stdin↔WS)    │ │                 │     │
│  └──────────┘ └──────────────┘ └─────────────────┘     │
└─────────────────────────────────────────────────────────┘
```

## 二、agentic-chat（前端 + BFF）

### 技术栈

| 类别 | 技术 |
|------|------|
| 框架 | Next.js 15 App Router |
| 状态管理 | Zustand + localStorage |
| 认证 | NextAuth.js (GitHub, Google, Email) |
| UI 组件 | Radix UI, Headless UI, Lucide React |
| 动画 | Framer Motion |
| 数据可视化 | Recharts |
| 虚拟列表 | react-window |
| HTTP 客户端 | 自研 oauth-client（自动 token 刷新）|

### WebSocket 客户端 (AIShellClient)

agentic-chat 通过 WebSocket 连接 session-gateway，实现完整的连接生命周期管理：

```
disconnected → connecting → connected → reconnecting → failed
                                ↑              │
                                └──────────────┘
```

**关键参数**：
- 重连策略：指数退避（2s, 4s, 8s, 16s, 30s），最多 5 次
- 连接超时：10 秒
- 心跳：30 秒间隔 ping/pong
- 最大丢失 pong：2 次（触发重连）
- 重连抖动：±10%（防止雷群效应）

**特色功能**：
- **Token 热更新**：`updateToken()` 方法可在不断开连接的情况下刷新凭证
- **Token 过期检测**：识别 "Signature has expired" 错误并停止重连
- **延迟追踪**：通过 ping/pong 计算 RTT

### 消息类型

| 类型 | 方向 | 说明 |
|------|------|------|
| `message` | Client→Server | 发送用户消息（含 conversation_id）|
| `abort` | Client→Server | 取消进行中的请求 |
| `update_token` | Client→Server | 热更新 token |
| `ping/pong` | 双向 | 心跳 |
| `answer_question` | Client→Server | 回答 AskUserQuestion |
| `list_conversations` | Client→Server | 列出对话 |
| `content` / `text_delta` | Server→Client | AI 响应内容（流式）|
| `tool_call` / `tool_result` | Server→Client | 工具调用与结果 |
| `thinking` | Server→Client | LLM 思考状态 |
| `finish` | Server→Client | 完成（含 token 统计）|
| `ask_question` | Server→Client | 需要用户交互 |
| `progress` | Server→Client | 实时 token 进度 |

### Hook 架构

前端采用分层 Hook 设计，职责清晰：

| Hook | 职责 |
|------|------|
| `useAIShell` | 底层 WebSocket 生命周期（连接、状态、事件）|
| `useAIShellChat` | 高层业务逻辑（消息处理、工具执行）|
| `useConversationAPI` | HTTP 对话元数据 |
| `useAIShellQuestion` | AskUserQuestion 工具处理 |

**竞态条件处理**：使用 `currentMessageIdRef` + `accumulatedContentRef` 双 Ref 模式，在异步消息创建期间缓冲内容，防止重复消息。

### 模型配置

支持 21 个模型，分为两大类：

**OpenAI (11 个)**：gpt-4.5-preview, o1, o1-pro, o3-mini, gpt-4o, gpt-4o-mini 等

**Anthropic (8 个)**：claude-opus-4, claude-sonnet-4-5, claude-sonnet-4, claude-3-5-sonnet 等

默认模型：`gpt-4.1-mini`

### 数据持久化

| 数据 | 存储位置 | 说明 |
|------|---------|------|
| 消息历史 | PostgreSQL (后端) | 通过 Conversation API 同步 |
| 模型偏好 | localStorage | `selectedModel` |
| 显示设置 | localStorage | `showRawData` |
| 对话列表 | 后端 API | 分页获取 |

## 三、session-gateway（WebSocket 网关）

### 核心职责

session-gateway 是整个系统的**控制平面和路由层**，负责：
1. WebSocket 连接管理和认证
2. 容器生命周期编排（启动、停止、健康检查）
3. 消息路由（客户端 ↔ 容器）
4. Session 状态持久化
5. 资源池管理（WarmPool、TokenPool）

### ExecutionBridge 抽象

这是 session-gateway 最核心的设计——通过统一接口抽象不同的容器运行环境：

```typescript
interface ExecutionBridge {
  start(): Promise<void>
  stop(): Promise<void>
  isRunning(): boolean
  attachWebSocket(ws): void
  detachWebSocket(): void
  sendToContainer(message): void
  sendToClient(message): void
  updateContainerToken(newToken, user): void
  getContainerId(): string
  checkTaskAlive?(): Promise<boolean>
}
```

**四种实现**：

| 模式 | Bridge | 启动时间 | 隔离级别 | 适用场景 |
|------|--------|---------|---------|---------|
| `docker` | ContainerBridge | ~100ms | 进程级 | 本地开发 |
| `ecs` | EcsBridge | 260ms(warm)/3-5s(cold) | 文件系统(EFS) | 生产环境（当前）|
| `lambda` | LambdaBridge | 1-10s(冷启动) | 进程级 | 成本优化场景 |
| `agentcore` | AgentCoreBridge | 300-800ms | 完全隔离(microVM) | AWS Bedrock 集成 |

### 双 WebSocket 架构 (ECS 模式)

```
Browser ←WS→ Session Gateway ←WS→ Container (ai-shell)
              (Client WS)         (Task WS)
                                     ↓
                                ws-bridge.js ←stdin/stdout→ optima-agent
```

**Client WS**：浏览器到网关的连接
**Task WS**：容器主动连接回网关的内部 WebSocket (`/internal/task/{sessionId}`)

这种设计使容器无需暴露端口，网关作为唯一入口点。

### Session 状态机

```
CREATING → PENDING → ACTIVATING → RUNNING ↔ IDLE → STOPPING → TERMINATED
                                     ↑                   ↑
                                     └─── RESTART ────────┘
```

| 状态 | 说明 |
|------|------|
| CREATING | 正在启动 Task，消息队列缓冲 |
| PENDING | Task 已 RUNNING，等待容器连接 |
| ACTIVATING | 容器已连接到 `/internal/task/{sessionId}` |
| RUNNING | 双向 WebSocket 建立，正常工作 |
| IDLE | 客户端断开但 Task 仍在运行（可恢复）|
| STOPPING | 正在优雅停止 |
| TERMINATED | Task 已停止并清理 |

### 消息队列与懒启动

**消息队列**：当 Task WebSocket 尚未就绪时，消息缓冲在队列中
- 自动 flush：Task 连接后立即发送
- 批处理间隔：100ms
- 防止启动期间消息丢失

**懒启动 (Lazy Start)**：不在用户连接时立即启动容器，而是等到第一条消息才启动。节省资源，特别是用户只是打开页面但不发消息的场景。

### WarmPool 预热池

**目的**：将 ECS 冷启动时间从 3-5s 降低到 ~260ms

```
Gateway 启动
    ↓
Replenish 循环 (每 30s)
    ↓
StartWarmTask() (无用户上下文)
    ↓
容器启动 → 连接 /internal/warm/{taskId}
    ↓
注册到就绪池 (ready)
    ↓
acquire() → 从池中获取 → 发送 init_user
    ↓
容器初始化用户目录 → 返回 "ready"
```

**配置**：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `WARM_POOL_TARGET_SIZE` | 3 | 目标就绪数量 |
| `WARM_POOL_MAX_SIZE` | 10 | 最大数量（含 pending）|
| `WARM_POOL_READY_TTL` | 3600s | 空闲 Task 存活时间 |

**状态机**：`connecting → ready → assigned`

**关键设计**：
- 原子锁防止并发 acquire 竞态
- 逐个启动，等待连接后再启动下一个
- Keepalive ping 防止 ALB 60s 超时
- 纯内存管理，不持久化

### TokenPool 令牌池

**目的**：管理多个 Claude Code OAuth Token，分散速率限制压力

```typescript
class TokenPool {
  tokens: string[]                      // 所有可用 token
  disabledTokens: Set<string>          // 被限速的 token
  sessionTokenMap: Map<sessionId, token> // Session-Token 映射

  getNextToken(sessionId): string       // 随机选择可用 token
  markUnavailable(token): void          // 标记被 429 限速
  checkAndRecover(): void               // 每小时恢复所有 token
}
```

**策略**：
- 随机选择 + 降级回退（所有 token 都被限速时使用全量池）
- Session 绑定追踪（定位哪个 session 触发了限速）
- 整点自动恢复

### 数据模型 (Prisma)

```
Session (核心 Session 追踪)
├── id, userId, containerId, taskArn
├── status: CREATING | RUNNING | IDLE | TERMINATED
├── createdAt, lastActivity, terminatedAt
└── workspacePath, envVars (JSON)

SessionEvent (对话事件流)
├── sessionId, timestamp
├── eventType: message | tool_use | tool_result | error | info
└── eventData (JSON)

Conversation (对话管理，跨 Session 存活)
├── conversationId, userId, claudeSdkSessionId
├── createdAt, lastMessageAt, title
└── metadata (JSON)

ConversationMessage (消息持久化)
├── conversationId, role, content
├── toolCalls (JSON)
└── sequenceNumber (防竞态唯一约束)

UserQuota (配额管理)
├── userId, maxHoursPerWeek
├── maxConcurrentSessions
└── idleTimeoutMinutes

UsageRecord (用量记录)
├── userId, sessionId
├── weekStart, durationSeconds
```

### 处理状态（空闲超时）

```
idle → processing → waiting_for_answer → idle
```

- `idle`：无活跃请求，空闲计时器运行
- `processing`：用户发送消息，AI 工作中，暂停空闲计时
- `waiting_for_answer`：AI 发送 `ask_question`，等待用户回答

### Session 恢复流程

当客户端重连到已有 IDLE session 时：

1. 客户端发送消息 → `sendToContainer()`
2. 检测 Task 未运行 → 触发 `restartTask()`
3. Task 启动 → 连接回网关
4. 发送 `restore_conversations`（恢复之前的对话）
5. 等待 "Restored X conversations" 确认
6. `flushMessageQueue()` 发送排队的用户消息
7. 发送 `session_recovered` 给客户端

## 四、optima-agent（Agent 运行时）

### Claude Agent SDK 集成

`OptimaAgent` 类是 Claude Agent SDK `query()` 函数的轻量封装（agent.ts ~200 行）：

```typescript
class OptimaAgent {
  async query(prompt: string, options?: QueryOptions) {
    return claudeAgentSdk.query({
      model: this.config.model,           // claude-sonnet-4-5-20250929
      maxTurns: this.config.maxTurns,     // 100
      permissionMode: "bypassPermissions",
      systemPrompt: this.buildSystemPrompt(),
      settingsSources: ["project", "local"],
      includePartialMessages: true,
      canUseTool: this.canUseTool.bind(this),
      mcpServers: { "optima-memory": createMemoryMcpServer() },
      resumeSessionId: this.sessionId,
      ...options
    })
  }
}
```

**SDK 依赖度**：~80%。核心 Agent 循环（LLM 调用 → Tool 执行 → 结果反馈）完全由 SDK 处理。

### Skill 系统

**格式**：`.claude/skills/{skillname}/SKILL.md`（Markdown 文档）

**当前 18 个 Skill**：

| Skill | 说明 | 类型 |
|-------|------|------|
| merchant | 店铺信息管理 | 电商核心 |
| product | 商品管理 | 电商核心 |
| order | 订单处理 | 电商核心 |
| inventory | 库存管理 | 电商核心 |
| collection | 商品集合 | 电商核心 |
| homepage | 首页配置 | 电商核心 |
| product-page | 商品详情页 | 电商核心 |
| shipping | 运费管理 | 电商核心 |
| i18n | 多语言 | 电商核心 |
| review | 评价管理 | 电商核心 |
| comfy | 图片/视频生成 | AI 工具 |
| ads | Google Ads | 营销 |
| scout | Amazon 选品调研 | 营销 |
| bi | 商业智能分析 | 数据 |
| ffmpeg | 音视频处理 | 工具 |
| markdown-pdf | Markdown 转 PDF | 工具 |
| instagram | Instagram 集成 | 社交 |
| tiktok | TikTok 集成 | 社交 |

**加载机制**：SDK 自动从 `cwd/.claude/skills/` 目录加载所有 SKILL.md 文件。

### Headless 协议

容器内 optima-agent 通过 stdin/stdout JSON 协议与 ws-bridge.js 通信：

**输入消息类型（8 种）**：

| 类型 | 说明 |
|------|------|
| `init` | 初始化 |
| `message` | 用户消息 |
| `abort` | 取消请求 |
| `answer_question` | 回答问题 |
| `reset_conversation` | 重置对话 |
| `delete_conversation` | 删除对话 |
| `restore_conversations` | 恢复对话 |
| `ping` | 健康检查 |

**输出事件类型（13 种）**：

| 类型 | 说明 |
|------|------|
| `init` | 初始化完成 |
| `thinking` | LLM 思考中 |
| `content` | 内容块（完整）|
| `text_delta` | 增量文本（Delta 流式）|
| `tool_call` | 工具调用 |
| `tool_result` | 工具结果 |
| `ask_question` | 请求用户交互 |
| `progress` | Token 用量进度 |
| `finish` | 完成 |
| `error` | 错误 |
| `info` | 信息 |
| `conversation_update` | 对话状态更新 |
| `pong` | 健康检查响应 |

### Memory MCP Server

进程内 MCP 服务器，提供跨 Session 持久记忆：

**存储位置**：`~/.optima/memories/`

**操作**：
- `view` — 列目录或查看文件
- `create` — 创建/覆写文件
- `str_replace` — 文件内文本替换
- `insert` — 指定行插入
- `delete` — 删除文件/目录
- `rename` — 重命名/移动

**安全**：路径校验防止目录穿越攻击（阻止 `..` 和 `~`）

### 权限系统 (canUseTool)

```typescript
type CanUseTool = (toolName: string, input: Record<string, unknown>)
  => Promise<{ behavior: "allow" | "deny"; ... }>
```

**权限策略**：
- Headless 模式：按用户角色（merchant/admin vs 普通用户）控制
  - 非 merchant 禁止执行 commerce/bi-cli 的 Bash 命令
  - `AskUserQuestion` 转换为带 request_id 的请求
- One-shot 模式：禁止 `AskUserQuestion`（不支持交互）
- 交互模式：终端菜单确认

全局 `bypassPermissions` + 自定义 `canUseTool` 回调实现细粒度控制。

### 执行模式

| 模式 | 入口 | 用途 |
|------|------|------|
| Interactive | `optima` | 终端 UI（readline）|
| Headless | `optima headless` | 容器/Lambda（stdin/stdout JSON）|
| Server | `optima serve --port 3000` | HTTP/WebSocket 服务 |
| One-shot | `optima -p "prompt"` | 单次查询 |

### 系统提示词构成

```
Base System Prompt（角色定义 + 时间 + 核心能力）
    ↓
Skills List（18+ Skill 简述）
    ↓
Working Principles（伦理准则）
    ↓
Output Style（格式指南）
    ↓
Action Links（action:// 链接支持）
    ↓
Memory Tool Guide（跨 Session 记忆使用说明）
    ↓
User Working Directory（文件操作上下文）
    ↓
Project OPTIMA.md（项目自定义规则）
    ↓
User Append（用户自定义追加）
```

## 五、关键设计特点

### 优势

| 特点 | 说明 |
|------|------|
| **Bridge 抽象** | 4 种执行模式无缝切换，生产环境灵活选择 |
| **WarmPool** | 260ms 启动延迟，用户体验接近即时 |
| **Token 热更新** | 不断开连接刷新凭证，会话不中断 |
| **懒启动** | 只在需要时启动容器，节省资源 |
| **Headless 协议** | 清晰的 JSON 协议，便于集成和测试 |
| **Skill-as-Markdown** | Skill 即文档，版本可控，部署即改文件 |
| **多租户隔离** | EFS Access Point + 容器隔离 |
| **对话恢复** | 跨 Session 恢复，断线不丢上下文 |

### 已知限制

| 限制 | 说明 |
|------|------|
| **Claude 绑定** | ~80% SDK 依赖，无法使用其他 LLM Provider |
| **无 LSP 集成** | 不像 OpenCode 有语言服务器反馈循环 |
| **无自动 Context 压缩** | 依赖 SDK 内部行为，无显式压缩策略 |
| **Skill 全量注入** | 每次都加载所有 Skill 到 System Prompt，不按需 |
| **无插件系统** | Skill 是唯一扩展点，无法添加自定义工具 |
| **单一数据库** | 对话和 Session 共享同一 PostgreSQL 实例 |
| **无事件总线** | 不像 OpenCode 有 SSE 事件驱动架构 |

## 六、代码仓库结构

### agentic-chat

```
core-services/agentic-chat/
├── src/
│   ├── app/                     # Next.js App Router
│   ├── components/              # React 组件
│   ├── lib/
│   │   ├── ai-shell/           # AI Shell 集成
│   │   │   ├── client.ts       # WebSocket 客户端
│   │   │   ├── hooks/          # React Hooks
│   │   │   ├── api/            # HTTP API 封装
│   │   │   └── types.ts        # 类型定义
│   │   ├── store.ts            # Zustand Store (766 行)
│   │   ├── stores/             # 其他 Store
│   │   ├── types/              # 全局类型
│   │   └── constants/          # 常量定义
│   └── styles/                  # CSS
├── prisma/                      # 数据库 Schema
└── package.json
```

### session-gateway

```
ai-tools/optima-ai-shell/packages/session-gateway/
├── src/
│   ├── bridges/                 # 执行环境抽象
│   │   ├── execution-bridge.interface.ts
│   │   ├── container-bridge.ts  # Docker
│   │   ├── ecs-bridge.ts       # ECS (1466 行)
│   │   ├── lambda-bridge.ts    # Lambda
│   │   └── agentcore-bridge.ts # AWS Bedrock AgentCore
│   ├── services/
│   │   ├── warm-pool-manager.ts # 预热池
│   │   ├── token-pool.ts       # Token 池
│   │   └── session-cleanup.service.ts
│   ├── routes/                  # HTTP/WS 路由
│   └── utils/
├── prisma/
│   └── schema.prisma           # 数据模型
└── package.json
```

### optima-agent

```
ai-tools/optima-agent/
├── src/
│   ├── agent.ts                 # OptimaAgent 主类 (~200 行)
│   ├── system-prompt.ts        # 系统提示词组装
│   ├── ui/
│   │   ├── headless.ts         # Headless 模式入口
│   │   ├── headless-types.ts   # Headless 协议类型
│   │   ├── stream.ts           # 交互模式
│   │   └── conversation-manager.ts
│   ├── tools/
│   │   └── memory.ts           # Memory MCP Server
│   ├── auth/                    # 认证
│   ├── server/                  # HTTP Server 模式
│   └── bin/
│       ├── optima.ts           # 主入口
│       ├── commerce             # CLI 工具透传
│       └── ...
├── .claude/skills/              # 18 个 Skill
│   ├── merchant/SKILL.md
│   ├── product/SKILL.md
│   └── ...
├── OPTIMA.json                  # 项目配置
├── OPTIMA.md                    # 项目提示词
└── package.json
```

## 七、环境配置

### session-gateway 关键环境变量

```bash
# 服务器
PORT=5174
EXECUTION_MODE=ecs|docker|lambda|agentcore

# AWS (ECS 模式)
AWS_REGION=ap-southeast-1
ECS_CLUSTER_ARN=arn:aws:ecs:...
ECS_TASK_DEFINITION=ai-shell:1
EFS_FILE_SYSTEM_ID=fs-xxxxx

# 预热池
ENABLE_WARM_POOL=true
WARM_POOL_TARGET_SIZE=3
WARM_POOL_MAX_SIZE=10

# Token 池
CLAUDE_CODE_OAUTH_TOKENS=token1,token2,token3

# Session
SESSION_IDLE_TIMEOUT=900
DISCONNECT_PROCESSING_TIMEOUT=900

# 数据库
DATABASE_URL=postgresql://...

# AI 密钥
ANTHROPIC_API_KEY=sk-ant-...
```

### 容器注入变量

```bash
USER_ID={userId}
SESSION_ID={sessionId}
GATEWAY_WS_URL=wss://gateway/internal/task/{sessionId}
WARM_POOL_MODE=true|false
ANTHROPIC_API_KEY=...
OPTIMA_TOKEN=...  # 用户 Access Token
```
