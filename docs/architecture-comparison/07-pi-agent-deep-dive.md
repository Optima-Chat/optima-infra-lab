# Pi Agent 深度分析：替代 Claude Agent SDK 的可行性

> Pi 是 OpenClaw 的核心 Agent 引擎，由 Mario Zechner（libGDX 创始人）创建。
> 仓库：[github.com/badlogic/pi-mono](https://github.com/badlogic/pi-mono)
> 许可：MIT

## 一、Pi 的起源与哲学

### 背景

Mario Zechner 是 libGDX（Java 游戏框架，GitHub 23K+ stars）的创始人。他在使用 Claude Code 时感到挫败——"Claude Code 已经变成了一艘飞船，80% 的功能我根本用不到"。于是他创建了 Pi，一个极简的编码 Agent。

Pi 后来被 OpenClaw（145K+ GitHub stars）采用为核心 Agent 引擎。网站域名 `shittycodingagent.ai` 重定向到 `pi.dev`，体现了它的自嘲式极简哲学。

### 核心哲学："你不放进去的东西比你放进去的更重要"

1. **System Prompt < 1,000 tokens** — "所有前沿模型都被 RL 训练过了，它们天然理解什么是编码 Agent。不需要 10,000 tokens 的系统提示词。"
2. **只有 4 个工具** — read, write, edit, bash。如果需要 ripgrep？用 bash 运行 `rg`。需要搜 GitHub？用 bash 运行 `gh`。
3. **Full YOLO 模式** — 没有权限检查、没有安全护栏、没有确认对话框。"大家反正都在用 YOLO 模式才能高效工作。"安全应该由环境隔离（容器）来保证，而不是在 Agent 层面做安全剧场。
4. **可扩展优于内置功能** — 功能通过 TypeScript 扩展、Skill、Prompt 模板或 Pi Package 来添加。

### 知名支持者

Armin Ronacher（Flask 创始人，Sentry 工程师）是 Pi 的显著支持者，写了 [详细博文](https://lucumr.pocoo.org/2026/1/31/pi/) 并在 Syntax Podcast 上与 Mario 一起出镜。

## 二、仓库架构：pi-mono

TypeScript monorepo，使用 npm workspaces + 锁步版本发布。

### 分层架构

```
Foundation Layer (零内部依赖):
  @mariozechner/pi-ai           — 统一 LLM API (20+ Provider, 300+ 模型)
  @mariozechner/pi-tui          — 终端渲染/UI

Core Framework Layer (依赖 Foundation):
  @mariozechner/pi-agent-core   — Agent 编排、状态机、工具执行

Application Layer (依赖 Core):
  @mariozechner/pi-coding-agent — CLI 编码 Agent（Session、工具、主题）
  @mariozechner/pi-slackbot     — Slack Bot (mom)
  pi-vllm-pods                  — vLLM 部署支持
```

### 与 Optima 对比

```
Pi:
  pi-ai (Provider) → pi-agent-core (循环) → pi-coding-agent (CLI)
  ↓ 每层独立，可单独使用

Optima:
  Claude Agent SDK (Provider + 循环 + 工具，全捆绑)
  ↓ 无法分层使用，80% 依赖
```

**关键区别**：Pi 的 Provider 层 (`pi-ai`) 和 Agent 循环层 (`pi-agent-core`) 是**完全独立的 npm 包**，可以单独引入。这意味着 Optima 可以只用 `pi-ai` 做 Provider 抽象，或者只用 `pi-agent-core` 做 Agent 循环，而不需要引入整个 Pi 编码工具。

## 三、统一 LLM API：pi-ai

### 核心洞察：只有 4 种协议

Mario 发现所有 LLM Provider 本质上只说 4 种协议：

| 协议 | 实现文件 | 使用此协议的 Provider |
|------|---------|---------------------|
| OpenAI Completions API | `streamOpenAICompletions` | OpenAI, Azure, Groq, Cerebras, xAI, Mistral, Ollama, vLLM, 所有 OpenAI 兼容端点 |
| OpenAI Responses API | `streamOpenAIResponses` | OpenAI (新 API) |
| Anthropic Messages API | `streamAnthropic` | Anthropic, AWS Bedrock (Anthropic) |
| Google Generative AI API | `streamGoogle` | Google, Vertex AI |

### 流式事件标准化

Pi 将不同 Provider 的流式格式统一为：

```typescript
type StreamEvent =
  | { type: 'start' }
  | { type: 'text_start' }
  | { type: 'text_delta'; delta: string }
  | { type: 'text_end' }
  | { type: 'thinking_start' }
  | { type: 'thinking_delta'; delta: string }
  | { type: 'thinking_end' }
  | { type: 'toolcall_start'; id: string; name: string }
  | { type: 'toolcall_delta'; delta: string }
  | { type: 'toolcall_end' }
  | { type: 'done'; usage: TokenUsage }
  | { type: 'error'; error: Error }
```

**写一次流式处理器，适用于所有 Provider。**

### Provider 怪癖处理

pi-ai 内部处理了大量 Provider 特异性：
- Cerebras 不支持 `store` 字段
- Mistral 用 `max_tokens` 而不是 `max_completion_tokens`
- Google 不支持 Tool Call 流式
- 有些 Provider 在 SSE 流开头报告 token 计数，有些在结尾
- 等数十个适配细节

### 模型目录

构建时从 `models.dev` 和 OpenRouter 元数据**自动生成** 300+ 模型定义，包含：
- 模型 ID 和别名
- Context Window 大小
- 定价信息
- 能力标记（vision、thinking、tool use 等）

### 与 Vercel AI SDK 对比

| 维度 | pi-ai | Vercel AI SDK |
|------|-------|---------------|
| 设计思路 | 4 种协议映射 | Provider 适配器模式 |
| Provider 数量 | 20+ (通过 4 协议覆盖几乎所有) | 75+ (每个 Provider 独立适配器) |
| 模型目录 | 300+ (自动生成) | 无内置目录 |
| 包大小 | 单包 | 多个 @ai-sdk/* 包 |
| TypeBox Schema | 原生 | 不支持 |
| 运行时 | Node.js | Node.js |
| 许可 | MIT | Apache-2.0 |

**Pi 的优势**：更精简（一个包覆盖所有）、自带模型目录、自动生成。
**Vercel 的优势**：更成熟、社区更大、Next.js 生态集成更好。

## 四、Agent Core：状态机与事件系统

### AgentState

`Agent` 类维护一个 `AgentState` 对象：

```typescript
interface AgentState {
  messages: Message[]           // 对话历史
  model: ModelConfig            // 当前模型配置
  tools: Map<string, Tool>      // 工具注册表
  isStreaming: boolean          // 是否在流式状态
  pendingToolCalls: Set<string> // 活跃的工具执行
}
```

### Agent 循环

```
用户输入
  ↓
发送消息到 LLM
  ↓
LLM 响应（流式）
  ├─ 纯文本 → 渲染输出
  └─ Tool Call → 执行工具 → 结果反馈 → 重新调 LLM
  ↓
循环直到 LLM 停止调用工具
```

### 事件系统

UI 组件通过订阅事件而非轮询状态来工作：

| 事件 | 说明 |
|------|------|
| `agent_start` | Agent 开始运行 |
| `turn_start` | 新一轮开始 |
| `message_start` / `message_end` | 消息生命周期 |
| `message_update` | 流式更新 |
| `tool_execution_start` | 工具开始执行 |
| `tool_execution_update` | 工具执行进度 |
| `tool_execution_end` | 工具执行完成 |

**关键设计**：工具可以返回两种内容 —— 给 LLM 看的 `output` 和给 UI 渲染的 `details`（类型为 'file'、'diff'、'terminal'、'error'）。

### 与 Optima 的 Headless 协议对比

| 维度 | Pi Agent Core | Optima Headless |
|------|--------------|-----------------|
| 通信方式 | 事件订阅（SDK 模式）/ JSON RPC（进程间）| stdin/stdout JSON |
| 事件类型 | ~10 种生命周期事件 | 8 输入 + 13 输出 |
| 工具结果 | output (LLM用) + details (UI用) | 单一 result |
| 状态管理 | AgentState 对象 | ConversationManager |

## 五、4 个核心工具

### 系统提示词（实际内容）

```
You are Pi, a coding assistant. You help users write, debug, and
understand code. You have access to these tools: read (Read files
and images), write (Create/overwrite files), edit (Make surgical
edits to files), bash (Run shell commands). Work directly in the
user's project. Read files to understand context before making changes.
```

加上工具 schema 定义，总计 < 1,000 tokens。

### 工具详情

| 工具 | 说明 | 使用准则 |
|------|------|---------|
| `read` | 读文件和图片 | 在编辑前先读取，了解上下文 |
| `write` | 创建/覆写文件 | 仅用于新文件或完整重写 |
| `edit` | 精确文本替换 | old_text 必须精确匹配 |
| `bash` | 运行 Shell 命令 | 用于 ls/grep/find/git/npm 等一切 |

### 为什么只有 4 个工具？

Mario 的论点：
> "所有前沿模型都被广泛训练过这些工具 schema。添加专用工具只是增加了系统提示词的 token 消耗，但不增加能力。需要 ripgrep？运行 `rg`。需要 GitHub API？运行 `gh`。需要 Docker？运行 `docker`。"

### 额外内置工具

除了 4 个核心工具，Pi 还内置了 `grep`、`find`、`ls` 作为优化（避免频繁启动 bash 进程），但这些可以被扩展覆盖。

### 扩展覆盖

扩展可以通过注册同名工具来**覆盖内置工具**：

```typescript
pi.registerTool({
  name: "bash",  // 覆盖内置 bash
  description: "Run sandboxed shell commands",
  schema: { command: Type.String() },
  execute: async ({ command }) => {
    // 自定义实现，如添加沙盒
    return runInSandbox(command)
  }
})
```

`bash` 工具还支持 `spawn` hook，允许在执行前修改命令、cwd 或环境变量。

## 六、运行模式

| 模式 | 说明 | 使用场景 |
|------|------|---------|
| **Interactive** | 完整 TUI + Session 管理 | 默认 CLI 体验 |
| **Print / JSON** | 输出模式 | 脚本化调用 |
| **RPC** | stdin/stdout JSON 协议 | 进程间集成 |
| **SDK** | TypeScript API 嵌入 | 构建自定义 Agent |

### RPC 模式（关键）

RPC 模式通过 stdin/stdout 的 JSON 协议实现无头运行。**这就是 OpenClaw 集成 Pi 的方式**。

RPC 协议支持：
- 工具流式输出
- 内容块流式输出
- Session 管理命令
- 语言无关集成（任何语言都可以通过 JSON pipe 调用）

### SDK 模式（对 Optima 最重要）

```typescript
import { Agent, createAgentSession } from '@mariozechner/pi-agent-core'

const session = createAgentSession({
  model: { provider: 'anthropic', model: 'claude-sonnet-4-5-20250929' },
  tools: [readTool, writeTool, editTool, bashTool, ...customTools],
  systemPrompt: "你是一个电商运营助手...",
})

// 事件驱动
session.on('text_delta', (delta) => sendToClient(delta))
session.on('tool_execution_start', (event) => notifyUI(event))

// 发送消息
await session.send("帮我查看一下今天的订单状况")
```

**这意味着 Optima 可以直接使用 `pi-agent-core` 的 SDK 模式来替代 Claude Agent SDK 的 `query()` 函数。**

## 七、Context Window 管理与 Compaction

### 压缩机制

Pi 实现了完善的 Context 压缩：

```
正常对话 → token 增长 → 接近阈值
    ↓
自动触发 Compaction
    ↓
用 LLM 摘要旧消息 → 保留近期消息
    ↓
完整历史保存在 .jsonl（可通过 /tree 回看）
```

**触发方式**：
- 手动：`/compact` 或 `/compact <自定义指令>`
- 自动（默认开启）：
  - Context 溢出时恢复并重试
  - 接近限制时主动触发

### Session 树结构

Pi 的 Session 存储为 JSONL 文件，每行一个 JSON 对象，通过 `id` / `parentId` 形成**树结构**：

```jsonl
{"id": "1", "parentId": null, "role": "user", "content": "..."}
{"id": "2", "parentId": "1", "role": "assistant", "content": "..."}
{"id": "3", "parentId": "2", "role": "user", "content": "..."}
// 分支点：从 id=2 分出新分支
{"id": "4", "parentId": "2", "role": "user", "content": "(不同的问题)"}
```

**好处**：
- 追加写入（append-only），原子操作，不会损坏文件
- 人类可读，可用标准工具（grep, jq）检查
- 支持原地分支，无需创建新文件
- `/tree` 命令可导航完整历史，跳转到任意时间点
- `/fork` 从任意分支点创建新 Session

### 与 Optima 对比

| 维度 | Pi | Optima |
|------|-----|--------|
| 压缩策略 | 自动 + 手动，可配置阈值 | 依赖 Claude SDK 内部行为 |
| 存储格式 | JSONL (append-only) | PostgreSQL |
| 分支 | 原生支持（树结构）| 不支持 |
| 历史回看 | /tree 命令 | 不支持 |
| 扩展 hook | `session_before_compact` | 无 |

### 扩展 Hook：压缩前自定义

```typescript
pi.on('session_before_compact', async (event, ctx) => {
  // 在压缩前，让 Agent 把关键状态写到磁盘
  // OpenClaw 的 compaction-safeguard.ts 就是这么做的
  await agent.send("请把当前上下文中的关键信息写到 memory/ 目录")
})
```

## 八、扩展系统

### 扩展类型

| 类型 | 说明 | 加载位置 |
|------|------|---------|
| TypeScript 扩展 | 自定义工具、命令、快捷键、事件处理器 | `.pi/extensions/` |
| Skill | Markdown 文件（类似 CLAUDE.md）| `~/.pi/agent/skills/`, `.pi/skills/`, `.agents/skills/` |
| Prompt 模板 | 可复用提示词 | `/templatename` 展开 |
| Theme | 视觉定制 | 配置文件 |
| Pi Package | 上述打包分发 | npm 或 git |

### 生命周期 Hook

| Hook | 说明 |
|------|------|
| `context` | 在消息发送到 LLM 前重写 |
| `session_before_compact` | 压缩前自定义 |
| `tool_call` | 拦截或门控工具调用 |
| `before_agent_start` | 注入上下文或修改提示词 |
| `session_start` / `session_switch` | Session 变化时 |
| `tool_execution_start/update/end` | 工具执行全生命周期 |

### 工具注册 API

```typescript
// 注册自定义工具
pi.registerTool({
  name: "query_orders",
  description: "查询电商订单",
  schema: {
    status: Type.Optional(Type.String()),
    dateRange: Type.Optional(Type.String()),
  },
  execute: async ({ status, dateRange }) => {
    const orders = await commerceAPI.queryOrders({ status, dateRange })
    return {
      output: JSON.stringify(orders),           // LLM 看到的
      details: { type: 'terminal', data: orders } // UI 渲染的
    }
  }
})

// 注册命令
pi.registerCommand({
  name: "switch-store",
  description: "切换当前店铺",
  execute: async (args) => { ... }
})
```

### 项目上下文文件

| 文件 | 说明 |
|------|------|
| `AGENTS.md` (或 `CLAUDE.md`) | 启动时加载，多个同名文件会拼接 |
| `.pi/SYSTEM.md` | 替换默认系统提示词 |
| `APPEND_SYSTEM.md` | 追加到系统提示词（不替换）|
| `.pi/skills/` | 项目级 Skill |

## 九、OpenClaw 如何集成 Pi

### 嵌入方式

OpenClaw **不是**通过 RPC/子进程调用 Pi，而是**直接嵌入** Pi 的 `AgentSession`：

```typescript
import { createAgentSession } from '@mariozechner/pi-agent-core'

// OpenClaw 直接创建 Agent Session
const session = createAgentSession({
  model: resolveModel(userConfig),
  tools: createOpenClawCodingTools(),  // Pi 工具 + OpenClaw 扩展工具
  systemPrompt: buildPrompt(channel, user),
})
```

### 工具扩展

OpenClaw 通过 `createOpenClawCodingTools()` 合并了两组工具：

```
Pi 基础工具:        OpenClaw 扩展工具:
├── read            ├── browser (网页浏览)
├── write           ├── canvas (画布)
├── edit            ├── nodes (工作流节点)
├── exec            ├── cron (定时任务)
└── process         ├── sessions (Session 管理)
                    └── message (消息发送)
```

### 自定义扩展

OpenClaw 加载了两个关键 Pi 扩展：

1. **compaction-safeguard.ts** — 压缩时添加自适应 token 预算的保护栏
2. **context-pruning.ts** — 基于 Cache TTL 的 Context 修剪

### 架构流程

```
WhatsApp/Slack/Web/CLI
        ↓
   OpenClaw Gateway (WebSocket)
        ↓
   确定 Agent Session
        ↓
   加载 Session 状态
        ↓
   pi-agent-core (嵌入式)
   ├── pi-ai (Provider 抽象)
   ├── 工具注册（Pi + OpenClaw）
   ├── Skill 加载
   └── Context 压缩
        ↓
   响应路由回原始平台
```

## 十、Pi 替代 Claude Agent SDK 的可行性

### 映射关系

| Optima 当前 (Claude SDK) | Pi 替代方案 |
|--------------------------|-----------|
| `claude-agent-sdk.query()` | `pi-agent-core.createAgentSession()` |
| SDK 内部 Agent 循环 | Pi 的 AgentState 状态机 |
| SDK Provider (仅 Claude) | `pi-ai` (20+ Provider, 300+ 模型) |
| SDK 工具管理 | Pi 工具注册 API |
| `canUseTool` 回调 | `tool_call` 事件 hook |
| `bypassPermissions` | Pi 默认 YOLO 模式 |
| `includePartialMessages` | Pi 原生流式事件 |
| Memory MCP Server | Pi 扩展（自定义工具）|
| `.claude/skills/` | `.pi/skills/` + `AGENTS.md` |
| Headless 协议 (stdin/stdout) | Pi RPC 模式 或 SDK 嵌入 |

### 方案对比

#### 方案 A：用 pi-ai 替代 Provider 层（低风险）

只使用 `@mariozechner/pi-ai` 做 LLM Provider 抽象，自研 Agent 循环。

```typescript
import { streamSimple } from '@mariozechner/pi-ai'

// 统一 API 调用任何 Provider
const events = streamSimple({
  provider: 'anthropic',
  model: 'claude-sonnet-4-5-20250929',
  messages: [...],
  tools: [...],
})

for await (const event of events) {
  // 统一的事件格式
  switch (event.type) {
    case 'text_delta': yield { type: 'content', content: event.delta }
    case 'toolcall_start': yield { type: 'tool_call', ... }
    // ...
  }
}
```

**优点**：最小改动，只替换 Provider 层
**缺点**：仍需自研 Agent 循环

#### 方案 B：用 pi-agent-core 替代整个 Agent 层（推荐）

使用 `@mariozechner/pi-agent-core` 的 SDK 模式完全替代 Claude Agent SDK。

```typescript
import { createAgentSession } from '@mariozechner/pi-agent-core'

// 创建 Session（类似 OpenClaw 的做法）
const session = createAgentSession({
  model: { provider: userSelectedProvider, model: userSelectedModel },
  tools: [
    ...piCodingTools,           // Pi 基础工具
    memoryTool,                 // 自研 Memory 工具
    ...skillTools,              // Skill 相关工具
  ],
  systemPrompt: buildOptimaSystemPrompt(skillPack),
})

// 事件驱动（替代 Headless 协议的输出部分）
session.on('text_delta', (delta) => {
  wsBridge.sendToClient({ type: 'text_delta', delta })
})

session.on('tool_execution_start', (event) => {
  wsBridge.sendToClient({ type: 'tool_call', tool_name: event.toolName })
})

session.on('tool_execution_end', (event) => {
  wsBridge.sendToClient({ type: 'tool_result', content: event.result })
})

// 发送消息
await session.send(userMessage)
```

**优点**：
- ✅ 直接获得 20+ Provider 支持和 300+ 模型目录
- ✅ 自带 Context Compaction
- ✅ 完善的事件系统（替代自研 Headless 协议的输出部分）
- ✅ 扩展系统支持自定义工具注册
- ✅ Session 树结构和分支支持
- ✅ 生产级代码（被 OpenClaw 145K+ stars 项目验证）
- ✅ MIT 许可
- ✅ Node.js 兼容（不需要 Bun）

**缺点**：
- ⚠️ 需要适配现有 Headless 协议（输入部分）
- ⚠️ 需要验证 canUseTool 回调能否通过 `tool_call` hook 实现
- ⚠️ Pi 仍在快速迭代，API 可能变化
- ⚠️ Memory MCP Server 需要改为 Pi 扩展方式

#### 方案 C：只借鉴 Pi 架构，用 Vercel AI SDK 自建（保守）

如 [06-opencode-migration.md](./06-opencode-migration.md) 中所述。

### 方案 B vs 方案 C 对比

| 维度 | 方案 B (用 Pi) | 方案 C (用 Vercel AI SDK 自建) |
|------|---------------|-------------------------------|
| Provider 抽象 | pi-ai 一个包搞定 | 多个 @ai-sdk/* 包 |
| Agent 循环 | pi-agent-core 开箱即用 | 需要自建 (~3-4 周) |
| Context 压缩 | 内置 | 需要自建 (~1-2 周) |
| 事件系统 | 内置 | 需要自建 |
| 扩展系统 | 工具注册 + 生命周期 hook | 需要自建 |
| 开发工作量 | **2-3 周** | **8-11 周** |
| 生产验证 | OpenClaw 145K+ stars | 需要自行验证 |
| API 稳定性 | 较低（快速迭代中）| 由自己控制 |
| 维护成本 | 跟随上游更新 | 自行维护 |
| 自由度 | 受 Pi 架构约束 | 完全自主 |

### 推荐

**短期推荐方案 B**：直接使用 `pi-agent-core` + `pi-ai` 替代 Claude Agent SDK。

理由：
1. **OpenClaw 已经验证了这条路径** — 它的架构（Gateway → 嵌入式 Pi Agent）与 Optima（session-gateway → 容器化 Agent）非常相似
2. **开发量大幅减少** — 从 8-11 周降到 2-3 周
3. **即刻获得 Multi-Provider** — 不用等自建 Provider 层
4. **自带 Context Compaction** — 解决当前最大的痛点之一

**长期考虑**：如果 Pi 的 API 变化太频繁导致维护负担过重，可以在此基础上逐步替换为自研组件（Pi 的分层架构使这很容易——先替换 pi-ai 为 Vercel AI SDK，再替换 pi-agent-core 为自研循环）。

## 十一、迁移路径

### Phase 1：验证 PoC (1 周)

```bash
# 安装 Pi 核心包
pnpm add @mariozechner/pi-ai @mariozechner/pi-agent-core
```

1. 在本地创建一个 PoC：用 `pi-agent-core` 的 SDK 模式替代 `claude-agent-sdk.query()`
2. 验证 Claude (Anthropic) 通过 pi-ai 正常工作
3. 验证工具注册 API 能实现 canUseTool 等效逻辑
4. 验证 Memory 功能可以通过自定义工具实现

### Phase 2：适配 Headless 协议 (1 周)

1. 编写 Pi 事件 → Headless 输出事件的适配层
2. 编写 Headless 输入事件 → Pi Session API 的适配层
3. 验证 ws-bridge.js 无需修改或最小修改
4. session-gateway 零修改验证

### Phase 3：Skill 系统迁移 (1 周)

1. 将 `.claude/skills/` 迁移到 `.pi/skills/` 或 `.agents/skills/`
2. 验证 Skill 加载行为一致
3. 实现 AGENTS.md / APPEND_SYSTEM.md 机制
4. 可选：实现 Skill 按需加载（使用 Pi 的扩展 hook）

### Phase 4：Multi-Provider 验证 (1 周)

1. 验证 OpenAI (GPT-4o) 通过 pi-ai 工作
2. 验证 Google (Gemini) 通过 pi-ai 工作
3. 前端模型选择真正路由到不同 Provider
4. 处理各 Provider 的 Tool Call 差异

### Phase 5：移除 Claude Agent SDK (1 周)

1. 移除 `@anthropic-ai/claude-agent-sdk` 依赖
2. 全量切换到 Pi
3. 更新 Dockerfile 和部署配置
4. 监控和回归测试

**总计：~5 周**（比方案 C 的 8-11 周减少约一半）

## 十二、风险与缓解

| 风险 | 等级 | 缓解措施 |
|------|------|---------|
| Pi API 不稳定 | 高 | 锁定版本号；封装薄适配层便于替换 |
| YOLO 模式不适合生产 | 中 | 通过 `tool_call` hook 实现权限控制 |
| Session 格式差异 (JSONL vs PostgreSQL) | 低 | 只用 pi-agent-core 的内存态，持久化仍用 PostgreSQL |
| 社区方向偏移 | 中 | Pi 分层架构允许逐层替换 |
| 性能差异 | 低 | Pi 已被 OpenClaw 生产验证 |

## 十三、总结

Pi Agent 是 Claude Agent SDK 的一个**可行且优秀的替代品**，特别是因为：

1. **OpenClaw 已经证明了嵌入式集成的可行性** — 它的 Gateway + 嵌入 Pi 模式与 Optima 的 session-gateway + Agent 容器模式高度相似
2. **分层架构允许渐进式采用** — 可以只用 pi-ai，也可以用 pi-ai + pi-agent-core
3. **自带我们最需要的功能** — Multi-Provider、Context Compaction、扩展系统
4. **MIT 许可** — 无法律风险
5. **生产级验证** — 145K+ stars 的 OpenClaw 背书

**与之前的结论对比**：在 [06-opencode-migration.md](./06-opencode-migration.md) 中我们推荐了方案 C（借鉴 OpenCode 架构，用 Vercel AI SDK 自建）。在深入研究 Pi 后，**方案 B（使用 Pi）在短期内是更优选择**——开发量减半，且 Pi 的分层设计使得未来替换为自建方案的迁移成本也很低。
