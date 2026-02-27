# 用 OpenCode 替代 Claude Agent SDK 可行性分析

## 一、背景

Optima 当前的 Agent 层（optima-agent）深度依赖 Claude Agent SDK（~80%），面临 Provider 锁定、无法自定义 Agent 循环、扩展性受限等问题。本文评估用 OpenCode 替代 Claude Agent SDK 的可行性。

## 二、OpenCode 架构与 Claude Agent SDK 对比

| 维度 | Claude Agent SDK | OpenCode |
|------|-----------------|----------|
| **定位** | Anthropic 官方 Agent 框架 | 开源 AI 编码助手 |
| **Provider** | 仅 Claude | 75+ Provider (Vercel AI SDK) |
| **Agent 循环** | SDK 内部闭环 | 自研开放循环 |
| **工具系统** | SDK 管理 | 自研 7 工具 + Plugin API |
| **Session** | SDK 内部管理 | SQLite + 自动压缩 |
| **输出模式** | Stream / Headless / Server | HTTP + SSE |
| **LSP** | 无 | 原生集成 |
| **包管理** | npm | pnpm (Bun Workspaces) |
| **运行时** | Node.js | Bun |
| **许可** | 闭源/限制 | MIT |
| **社区** | Anthropic 维护 | 700+ 贡献者 |

## 三、三种替代方案评估

### 方案 A：直接使用 OpenCode

**做法**：将 OpenCode 作为 optima-agent 的替代品，直接在容器中运行。

**优点**：
- 开箱即用的 75+ Provider 支持
- 完善的 Agent 循环、Context 压缩、LSP 集成
- 活跃的社区和持续更新
- MIT 许可，无法律风险

**缺点**：
- ❌ **OpenCode 是编码工具，不是通用 Agent 框架** — 工具系统面向文件编辑/代码搜索
- ❌ **TUI 为主**，Headless 协议不兼容现有 ws-bridge 通信
- ❌ **无 Skill 系统**（Agent 定义 ≠ Skill）
- ❌ **运行时差异**：Bun vs Node.js（需要容器和构建流程改造）
- ❌ **API 不稳定**：OpenCode 仍在快速迭代，Breaking Changes 频繁
- ❌ **不支持 canUseTool 回调**：权限模型不同
- ❌ **不支持 AskUserQuestion**：交互模式不同

**结论**：**不推荐**。OpenCode 解决的问题空间（代码编辑）与 Optima 不同（业务操作），强行适配会导致大量胶水代码。

### 方案 B：OpenCode 作为库集成

**做法**：将 OpenCode 的 `packages/opencode` 作为 npm 依赖引入，利用其 Provider 层和 Agent 系统。

**优点**：
- 复用 Provider Transformation 层
- 复用 Agent Loop 和 Context Compaction
- 复用 Event Bus 和 SSE 实现
- 保持 Optima 自身的 Skill 系统和 Headless 协议

**缺点**：
- ❌ **Bun 运行时依赖**：OpenCode 使用 Bun 特有的 API（Bun.spawn、Bun.file 等），在 Node.js 上可能无法运行
- ❌ **紧耦合**：OpenCode 不是设计为库使用的，内部依赖关系复杂
- ❌ **版本跟随负担**：OpenCode 快速迭代，每次升级可能需要大量适配
- ❌ **SQLite 依赖**：OpenCode 使用 SQLite，Optima 使用 PostgreSQL
- ❌ **工具系统冲突**：OpenCode 的工具面向文件编辑，与 Optima 的业务工具不兼容
- ❌ **Vercel AI SDK 版本绑定**：引入 OpenCode 意味着绑定到 Vercel AI SDK 的特定版本

**结论**：**不推荐**。OpenCode 的架构假设（单用户本地工具）与 Optima（多租户云服务）差异太大，作为库使用的成本高于自建。

### 方案 C：借鉴 OpenCode 架构自建（推荐）

**做法**：借鉴 OpenCode 的设计模式，在 Optima 中自建关键组件，渐进式替换 Claude Agent SDK。

**借鉴内容**：

| 组件 | 借鉴来源 | 自建内容 |
|------|---------|---------|
| Provider 抽象 | Vercel AI SDK + OpenCode Transformation 层 | 自研 Provider 适配层 |
| Agent 循环 | OpenCode Agent Loop | 自研 Agent 循环（替换 SDK query()）|
| Context 管理 | OpenCode Compaction 策略 | 自研 Context Manager |
| 工具系统 | OpenCode Tool + Permission | 保留现有 + 添加 Plugin 接口 |
| 事件系统 | OpenCode SSE Event Bus | 自研事件总线 |
| Skill 加载 | OpenClaw 按需注入策略 | 改造现有 Skill 系统 |

**优点**：
- ✅ 完全掌控，按需实现
- ✅ 保持现有架构优势（Bridge、WarmPool、多租户）
- ✅ 不引入外部运行时依赖（仍用 Node.js）
- ✅ 渐进式迁移，风险可控
- ✅ 可以选择性借鉴最佳实践

**缺点**：
- 开发工作量较大
- 需要维护自建的 Provider 适配层
- 需要跟踪 Vercel AI SDK 的更新

**结论**：**推荐**。这是投入产出比最高的方案。

## 四、方案 C 详细设计

### 4.1 Provider 抽象层

借鉴 OpenCode 的 Provider Transformation 层，但使用 Node.js 生态：

```typescript
// provider/index.ts
interface LLMProvider {
  name: string
  chat(params: ChatParams): AsyncGenerator<ChatEvent>
  models: ModelInfo[]
}

interface ChatParams {
  model: string
  messages: Message[]
  tools?: ToolDefinition[]
  systemPrompt?: string
  maxTokens?: number
  temperature?: number
}

type ChatEvent =
  | { type: 'text_delta'; content: string }
  | { type: 'tool_call'; id: string; name: string; args: any }
  | { type: 'thinking'; content: string }
  | { type: 'finish'; usage: TokenUsage }
  | { type: 'error'; error: Error }
```

**实现方式**：直接使用 Vercel AI SDK（它是独立的 npm 包，不需要 Bun）：

```typescript
// provider/vercel-adapter.ts
import { generateText, streamText } from 'ai'
import { anthropic } from '@ai-sdk/anthropic'
import { openai } from '@ai-sdk/openai'
import { google } from '@ai-sdk/google'

class VercelProvider implements LLMProvider {
  private sdk: any

  constructor(providerName: string) {
    switch (providerName) {
      case 'anthropic': this.sdk = anthropic; break
      case 'openai': this.sdk = openai; break
      case 'google': this.sdk = google; break
      // ... 更多 Provider
    }
  }

  async *chat(params: ChatParams): AsyncGenerator<ChatEvent> {
    const result = streamText({
      model: this.sdk(params.model),
      messages: this.transformMessages(params.messages),
      tools: this.transformTools(params.tools),
      system: params.systemPrompt,
    })

    for await (const chunk of result.textStream) {
      yield { type: 'text_delta', content: chunk }
    }
  }
}
```

**关键**：Vercel AI SDK 是纯 npm 包，**不需要 Bun**，在 Node.js 上完全可用。这是方案 C 的核心优势——不用引入 OpenCode 的代码，直接使用其底层依赖。

### 4.2 自研 Agent 循环

替换 Claude Agent SDK 的 `query()` 函数：

```typescript
// agent/loop.ts
class AgentLoop {
  constructor(
    private provider: LLMProvider,
    private tools: Map<string, Tool>,
    private contextManager: ContextManager,
  ) {}

  async *run(prompt: string, session: Session): AsyncGenerator<AgentEvent> {
    // 1. 准备上下文
    const messages = await this.contextManager.prepare(session, prompt)

    // 2. 注入系统提示词 + Skill 目录
    const systemPrompt = this.buildSystemPrompt(session)

    // 3. Agent 循环
    let turns = 0
    while (turns < this.maxTurns) {
      turns++

      // 4. 调用 LLM
      const response = await this.provider.chat({
        model: session.model,
        messages,
        tools: this.getToolDefinitions(),
        systemPrompt,
      })

      // 5. 处理响应
      for await (const event of response) {
        if (event.type === 'text_delta') {
          yield { type: 'content', content: event.content }
        }

        if (event.type === 'tool_call') {
          // 6. 权限检查
          const permission = await this.canUseTool(event.name, event.args)
          if (permission.behavior === 'deny') {
            yield { type: 'tool_result', error: permission.message }
            continue
          }

          // 7. 执行工具
          yield { type: 'tool_call', ...event }
          const result = await this.executeTool(event.name, event.args)
          yield { type: 'tool_result', result }

          // 8. 将结果加入消息历史
          messages.push({ role: 'tool', content: result })
        }

        if (event.type === 'finish') {
          // 9. Context 压缩检查
          await this.contextManager.checkAndCompact(session, messages)

          // 10. 如果没有工具调用，循环结束
          if (!hasToolCalls) {
            yield { type: 'finish', usage: event.usage }
            return
          }
        }
      }
    }
  }
}
```

### 4.3 Context Manager

```typescript
// agent/context-manager.ts
class ContextManager {
  private readonly WARNING_THRESHOLD = 0.70
  private readonly URGENT_THRESHOLD = 0.90
  private readonly COMPACT_THRESHOLD = 0.95

  async prepare(session: Session, newPrompt: string): Promise<Message[]> {
    const messages = session.getHistory()

    // 如果有摘要，用摘要替代旧历史
    if (session.summary) {
      return [
        { role: 'system', content: `Previous conversation summary:\n${session.summary}` },
        ...messages.slice(-10), // 保留最近 10 条
        { role: 'user', content: newPrompt },
      ]
    }

    return [...messages, { role: 'user', content: newPrompt }]
  }

  async checkAndCompact(session: Session, messages: Message[]) {
    const tokenCount = this.countTokens(messages)
    const contextWindow = this.getContextWindow(session.model)
    const usage = tokenCount / contextWindow

    if (usage >= this.COMPACT_THRESHOLD) {
      // 用 Summarizer 压缩历史
      const summary = await this.summarize(messages)
      session.setSummary(summary)

      // 裁剪旧工具输出
      this.trimToolOutputs(messages)
    } else if (usage >= this.WARNING_THRESHOLD) {
      // 发出预警事件
      this.emit('context_warning', { usage, threshold: this.WARNING_THRESHOLD })
    }
  }
}
```

### 4.4 迁移路径

```
Phase 1: Provider 抽象层 (2-3 周)
├── 安装 Vercel AI SDK (@ai-sdk/anthropic, @ai-sdk/openai, @ai-sdk/google)
├── 实现 LLMProvider 接口和 VercelProvider 适配器
├── 在 optima-agent 中添加 Provider 选择逻辑
├── 通过配置切换 Provider（默认仍用 Claude SDK）
└── 验证：Claude 通过新 Provider 层工作，行为一致

Phase 2: 自研 Agent 循环 (3-4 周)
├── 实现 AgentLoop 类（参考 OpenCode 实现）
├── 实现 ContextManager（参考 OpenCode Compaction）
├── 适配现有 Headless 协议（输入/输出消息类型）
├── 保留 canUseTool 权限回调接口
├── 保留 Memory MCP Server 集成
├── A/B 测试：Claude SDK vs 自研循环
└── 验证：所有 18 个 Skill 正常工作

Phase 3: 移除 Claude Agent SDK (1-2 周)
├── 切换默认到自研 Agent 循环
├── 更新 ws-bridge.js 适配新协议
├── 移除 @anthropic-ai/claude-agent-sdk 依赖
├── 更新文档和配置
└── 验证：全量切换无回归

Phase 4: 多 Provider 验证 (2 周)
├── 验证 OpenAI (GPT-4o, o3-mini) 通过自研循环工作
├── 验证 Google (Gemini) 通过自研循环工作
├── 处理 Provider 特异性差异（Tool Call 格式、Thinking 内容等）
├── 前端模型选择真正生效
└── 文档：各 Provider 的能力矩阵和已知限制
```

## 五、关键技术细节

### 5.1 Vercel AI SDK 在 Node.js 上的兼容性

Vercel AI SDK 是**纯 JavaScript/TypeScript 包**，不依赖 Bun 运行时：

```bash
# 安装核心包
pnpm add ai @ai-sdk/anthropic @ai-sdk/openai @ai-sdk/google

# 可选 Provider
pnpm add @ai-sdk/amazon-bedrock  # AWS Bedrock
pnpm add @ai-sdk/azure           # Azure OpenAI
pnpm add @ai-sdk/groq            # Groq
```

OpenCode 之所以使用 Bun，是因为其他组件（TUI、构建系统）需要 Bun，**不是** Vercel AI SDK 需要。

### 5.2 Tool Call 格式差异处理

不同 Provider 的 Tool Call 格式有差异，需要 Transformation 层处理：

```typescript
// provider/transformers.ts

// Anthropic: tool_use content block
// { type: "tool_use", id: "toolu_xxx", name: "read", input: {...} }

// OpenAI: function_call in message
// { tool_calls: [{ id: "call_xxx", function: { name: "read", arguments: "..." } }] }

// Google: function_call part
// { functionCall: { name: "read", args: {...} } }

function normalizeToolCall(provider: string, raw: any): ToolCall {
  switch (provider) {
    case 'anthropic':
      return { id: raw.id, name: raw.name, args: raw.input }
    case 'openai':
      return {
        id: raw.tool_calls[0].id,
        name: raw.tool_calls[0].function.name,
        args: JSON.parse(raw.tool_calls[0].function.arguments)
      }
    case 'google':
      return { id: generateId(), name: raw.functionCall.name, args: raw.functionCall.args }
  }
}
```

**好消息**：Vercel AI SDK 已经内部处理了大部分格式差异，上层代码使用统一的接口即可。

### 5.3 Thinking/Reasoning 内容处理

Claude 的 extended thinking 和 OpenAI 的 reasoning 格式不同：

```typescript
// Claude: thinking content block
// { type: "thinking", thinking: "..." }

// OpenAI o1/o3: reasoning_content
// { reasoning_content: "..." }

// Vercel AI SDK 统一为 reasoningContent
const result = await streamText({
  model: anthropic('claude-sonnet-4-5-20250929'),
  providerOptions: {
    anthropic: { thinking: { type: 'enabled', budgetTokens: 10000 } }
  }
})

for await (const part of result.fullStream) {
  if (part.type === 'reasoning') {
    yield { type: 'thinking', content: part.textDelta }
  }
}
```

### 5.4 与 Headless 协议的兼容

现有 Headless 协议（8 输入 + 13 输出类型）需要保持兼容：

```typescript
// headless-adapter.ts
class HeadlessAdapter {
  // 将 AgentLoop 事件转换为 Headless 输出事件
  async *adaptOutput(agentEvents: AsyncGenerator<AgentEvent>): AsyncGenerator<OutputEvent> {
    for await (const event of agentEvents) {
      switch (event.type) {
        case 'content':
          yield { type: 'text_delta', delta: event.content }
          break
        case 'tool_call':
          yield {
            type: 'tool_call',
            tool_call_id: event.id,
            tool_name: event.name,
            tool_input: event.args,
          }
          break
        case 'tool_result':
          yield {
            type: 'tool_result',
            tool_call_id: event.id,
            content: event.result,
          }
          break
        case 'finish':
          yield {
            type: 'finish',
            token_usage: event.usage,
          }
          break
        // ... 其他事件
      }
    }
  }

  // 将 Headless 输入事件转换为 AgentLoop 输入
  parseInput(raw: string): InputMessage {
    const msg = JSON.parse(raw)
    // 保持现有协议兼容
    return msg
  }
}
```

## 六、风险评估

| 风险 | 等级 | 缓解措施 |
|------|------|---------|
| 自研 Agent 循环质量不如 Claude SDK | 中 | A/B 测试验证，保留回退到 SDK 的选项 |
| Vercel AI SDK 版本升级 Breaking Changes | 低 | 锁定主版本号，定期升级测试 |
| Tool Call 格式适配遗漏 | 中 | 全面的集成测试覆盖所有 Provider |
| 迁移期间功能回归 | 中 | Feature Flag 控制切换，灰度发布 |
| 多 Provider 行为差异导致 Skill 不兼容 | 高 | Provider 能力矩阵标注，Skill 标记所需能力 |
| Context Compaction 信息丢失 | 中 | 保留完整历史备份，Compaction 可回滚 |

### Provider 能力差异矩阵

| 能力 | Claude | GPT-4o | Gemini | o3-mini |
|------|--------|--------|--------|---------|
| Tool Use | ✅ | ✅ | ✅ | ✅ |
| Streaming | ✅ | ✅ | ✅ | ✅ |
| Thinking/Reasoning | ✅ | ❌ | ✅ | ✅ |
| Vision (图片) | ✅ | ✅ | ✅ | ❌ |
| 长 Context (200K+) | ✅ | ✅ | ✅ (1M) | ❌ (200K) |
| Cache Control | ✅ | ❌ | ✅ | ❌ |
| 中文能力 | ★★★★★ | ★★★★★ | ★★★★☆ | ★★★★☆ |

不同 Provider 的能力差异意味着**部分 Skill 可能只在特定 Provider 上正常工作**。需要在 Skill Pack 中标注最低 Provider 要求。

## 七、成本分析

### 开发成本

| 阶段 | 工作量 | 人力 |
|------|--------|------|
| Phase 1: Provider 抽象层 | 2-3 周 | 1 人 |
| Phase 2: 自研 Agent 循环 | 3-4 周 | 1-2 人 |
| Phase 3: 移除 SDK | 1-2 周 | 1 人 |
| Phase 4: 多 Provider 验证 | 2 周 | 1 人 |
| **总计** | **8-11 周** | **1-2 人** |

### 运行成本影响

- **Vercel AI SDK**：MIT 许可，无额外费用
- **多 Provider**：可选择更便宜的模型降低 API 成本
  - Claude Sonnet: $3/$15 per 1M tokens (input/output)
  - GPT-4o-mini: $0.15/$0.60 per 1M tokens
  - Gemini Flash: $0.075/$0.30 per 1M tokens
- **潜在节约**：简单查询用便宜模型，复杂操作用强模型

### ROI 分析

| 收益 | 价值 |
|------|------|
| 解锁多 Provider | 降低 API 成本 30-50%（混合使用模型）|
| 消除 SDK 锁定 | 降低供应商风险 |
| 自研 Agent 循环 | 完全掌控，支持高级特性 |
| 多业务扩展 | 新业务线收入 |
| Context 压缩 | 改善长对话体验 |

## 八、结论

**推荐方案 C**：借鉴 OpenCode 的架构设计，使用 Vercel AI SDK 自建 Provider 抽象层，渐进式替换 Claude Agent SDK。

**核心理由**：
1. Vercel AI SDK 在 Node.js 上完全可用，无需引入 Bun
2. 直接使用 OpenCode 的底层依赖，不引入 OpenCode 本身的复杂性
3. 保持 Optima 现有优势（Bridge、WarmPool、多租户）
4. 渐进式迁移，风险可控
5. 最终实现 Provider 无关 + 完全自主的 Agent 运行时
