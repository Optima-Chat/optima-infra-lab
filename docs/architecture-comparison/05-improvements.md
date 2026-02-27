# Optima 改进建议与多业务扩展方案

## 一、当前架构问题分析

通过与 OpenCode 和 OpenClaw 的深度对比，Optima 当前架构存在以下改进空间：

### 1.1 Claude SDK 深度绑定

**问题**：optima-agent 约 80% 的 Agent 逻辑由 Claude Agent SDK 实现，包括：
- Agent 循环（LLM 调用 → Tool 执行 → 结果反馈）
- 工具定义和执行
- 消息格式和流式输出
- Permission 管理

**影响**：
- 无法使用其他 LLM Provider（前端有 21 个模型选项但 Agent 只能用 Claude）
- SDK 版本升级可能引入 Breaking Changes
- 无法控制 Agent 循环的细节行为
- 无法添加 LSP 反馈循环等高级特性

**OpenCode 做法**：通过 Vercel AI SDK 实现 Provider 无关，自研 Agent 循环，完全掌控执行流程。

**OpenClaw 做法**：Pi Runtime 仅 4 个核心工具，系统提示词 < 1,000 tokens，极简自研。

### 1.2 Skill 全量注入

**问题**：18 个 Skill 每次全部注入 System Prompt，不管用户当前对话是否需要。

**影响**：
- 浪费 Context Window（估计占用 3,000-5,000 tokens）
- 随着 Skill 数量增长，问题加剧
- 可能干扰 LLM 的判断（无关信息噪音）

**OpenClaw 做法**：
1. 注入精简的 Skill 清单（仅名称和简述）
2. LLM 判断某 Skill 相关时，**按需读取** 完整 SKILL.md
3. 250ms debounce 热重载

**建议**：实现两阶段 Skill 加载：
```
Phase 1: 注入 Skill 目录（名称 + 一行描述）
Phase 2: LLM 判断需要时，通过 Tool Call 读取完整 Skill 内容
```

### 1.3 缺少 Context Window 管理

**问题**：依赖 Claude SDK 内部行为处理 Context Window，无显式压缩策略。

**影响**：
- 长对话可能超出 Context Window
- 无法控制何时/如何压缩
- 用户无感知的信息丢失

**OpenCode 做法**：
```
70% → 预警
90% → 紧急预警
95% → 自动触发 Summarization Agent
     → 用摘要替换原始历史
     → 裁剪旧工具输出
     → 用户无感知
```

**建议**：实现显式的 Context Compaction 策略。

### 1.4 无事件驱动架构

**问题**：缺少统一的事件总线，前后端通信依赖 WebSocket 消息转发。

**OpenCode 做法**：19 种 SSE 事件类型，多客户端可同时连接共享实时更新。

**建议**：在 session-gateway 中引入 Event Bus，支持事件订阅和广播。

### 1.5 无插件/扩展系统

**问题**：Skill 是唯一扩展点，无法添加自定义工具、Hook 或中间件。

**OpenCode 做法**：
```typescript
// 自定义工具
import { tool } from "@opencode-ai/plugin"
export default tool({
  name: "my-tool",
  execute: async ({ input }) => { ... }
})

// Hooks
plugin.on("beforeToolCall", async (ctx) => { ... })
plugin.on("afterToolCall", async (ctx) => { ... })
```

**建议**：设计简单的 Plugin 接口，至少支持自定义工具注册。

### 1.6 缺少 LSP 集成

**问题**：Agent 修改代码后没有语言服务器反馈。

**OpenCode 做法**：文件修改后自动查询 LSP 获取诊断信息（未定义变量、类型错误等），反馈给 LLM 自我修正。

**影响**：Optima 主要面向电商业务而非编码，此项优先级较低。但如果扩展到开发者工具场景，则需要考虑。

## 二、改进优先级矩阵

| 改进项 | 影响 | 难度 | 优先级 | 说明 |
|--------|------|------|--------|------|
| Provider 抽象层 | ★★★★★ | ★★★★☆ | **P0** | 解锁多模型、降低 SDK 依赖 |
| Skill 按需注入 | ★★★★☆ | ★★☆☆☆ | **P1** | 节省 Context Window，支持更多 Skill |
| Context 压缩 | ★★★★☆ | ★★★☆☆ | **P1** | 防止长对话溢出 |
| 多业务部署 | ★★★★★ | ★★★☆☆ | **P1** | 业务扩展核心需求 |
| 事件总线 | ★★★☆☆ | ★★★☆☆ | **P2** | 改善多客户端体验 |
| Plugin 系统 | ★★★☆☆ | ★★★★☆ | **P2** | 提高扩展性 |
| 自定义 Agent | ★★★☆☆ | ★★★☆☆ | **P2** | 支持 Build/Plan 模式 |
| LSP 集成 | ★★☆☆☆ | ★★★★☆ | **P3** | 编码场景才需要 |

## 三、多业务扩展方案

### 3.1 需求分析

**目标**：同一套代码通过更换 Skill 文件部署到不同垂直业务。

**当前耦合点**：
1. ❌ optima-agent 的 Skill 打包在源码中（`.claude/skills/`）
2. ❌ System Prompt 硬编码了电商相关内容
3. ❌ CLI 工具透传（commerce, comfy, bi-cli 等）绑定到 package.json
4. ❌ `canUseTool` 权限逻辑包含电商角色判断（merchant/admin）
5. ❌ 容器镜像包含电商 CLI 依赖
6. ✅ session-gateway 的 Bridge 抽象是业务无关的
7. ✅ agentic-chat 的 WebSocket 客户端是业务无关的

### 3.2 推荐方案：Skill Pack 架构

将业务特定的内容抽取为独立的 **Skill Pack**，通过构建时或运行时注入：

```
optima-agent (核心框架，业务无关)
├── src/
│   ├── agent.ts            # 通用 Agent 逻辑
│   ├── system-prompt.ts    # 通用系统提示词模板
│   └── ...
├── skill-packs/            # Skill Pack 注册目录
│   ├── commerce/           # 电商 Skill Pack
│   │   ├── pack.json       # Pack 元数据
│   │   ├── skills/         # Skill 文件
│   │   ├── prompt.md       # 业务提示词
│   │   ├── tools.json      # CLI 工具声明
│   │   └── permissions.ts  # 权限规则
│   ├── healthcare/         # 医疗 Skill Pack
│   ├── education/          # 教育 Skill Pack
│   └── finance/            # 金融 Skill Pack
```

### 3.3 pack.json 设计

```jsonc
{
  "name": "commerce",
  "displayName": "电商运营助手",
  "version": "1.0.0",
  "description": "跨境电商全流程管理",

  // Skill 文件目录
  "skillsDir": "./skills",

  // 业务提示词（追加到 System Prompt）
  "promptFile": "./prompt.md",

  // CLI 工具依赖
  "tools": {
    "commerce": "@optima-chat/commerce-cli",
    "comfy": "@optima-chat/comfy-cli",
    "bi-cli": "@optima-chat/bi-cli",
    "ads": "@optima-chat/ads-cli",
    "scout": "@optima-chat/scout-cli"
  },

  // 权限规则
  "permissions": {
    "roles": ["merchant", "admin", "operator"],
    "toolAccess": {
      "merchant": ["commerce", "comfy", "scout"],
      "admin": ["*"],
      "operator": ["commerce"]
    }
  },

  // 容器构建配置
  "docker": {
    "baseImage": "optima-agent-base:latest",
    "additionalDeps": ["@optima-chat/commerce-cli"]
  }
}
```

### 3.4 系统提示词模板化

**当前**：硬编码在 `system-prompt.ts` 中

**改进**：

```typescript
// system-prompt.ts (通用模板)
function buildSystemPrompt(pack: SkillPack): string {
  return [
    BASE_PROMPT,                      // 通用基础提示词
    `你是 ${pack.displayName}`,       // Pack 身份
    pack.getPromptContent(),          // Pack 专属提示词
    buildSkillDirectory(pack.skills), // Skill 目录
    COMMON_PRINCIPLES,                // 通用准则
    OUTPUT_STYLE,                     // 输出格式
    MEMORY_GUIDE,                     // Memory 使用说明
  ].join('\n\n')
}
```

### 3.5 部署流程

```
┌────────────────────────────────────────────────┐
│               构建时                            │
│                                                │
│  optima-agent (base) + skill-pack (commerce)   │
│        ↓ Docker Build                          │
│  commerce-agent:latest                         │
│                                                │
│  optima-agent (base) + skill-pack (healthcare) │
│        ↓ Docker Build                          │
│  healthcare-agent:latest                       │
│                                                │
└────────────────────────────────────────────────┘
                    ↓
┌────────────────────────────────────────────────┐
│               运行时                            │
│                                                │
│  session-gateway                               │
│    ├── EXECUTION_MODE=ecs                      │
│    ├── SKILL_PACK=commerce → 使用 commerce 镜像│
│    └── SKILL_PACK=healthcare → 使用 health 镜像│
│                                                │
│  或者：                                         │
│    ├── 不同 ECS Service 使用不同镜像             │
│    └── 不同域名路由到不同 Service               │
│                                                │
└────────────────────────────────────────────────┘
```

### 3.6 多业务部署拓扑

```
                    ┌─────────────────────┐
                    │      ALB            │
                    │  *.optima.shop      │
                    │  *.health.optima.ai │
                    └──────┬──────────────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
     ┌──────▼──────┐ ┌────▼────┐ ┌───────▼──────┐
     │ commerce    │ │ health  │ │ education    │
     │ gateway     │ │ gateway │ │ gateway      │
     └──────┬──────┘ └────┬────┘ └───────┬──────┘
            │              │              │
     ┌──────▼──────┐ ┌────▼────┐ ┌───────▼──────┐
     │ commerce    │ │ health  │ │ education    │
     │ agent       │ │ agent   │ │ agent        │
     │ (ECS Task)  │ │(ECS)    │ │ (ECS Task)   │
     └─────────────┘ └─────────┘ └──────────────┘

     Skill Pack:      Skill Pack:   Skill Pack:
     - merchant       - patient     - student
     - product        - diagnosis   - course
     - order          - schedule    - exam
     - shipping       - pharmacy    - grade
```

### 3.7 实施步骤

**Phase 1：解耦 Skill（1-2 周）**

1. 将 `.claude/skills/` 中的电商 Skill 移到 `skill-packs/commerce/skills/`
2. 将电商相关的 System Prompt 移到 `skill-packs/commerce/prompt.md`
3. `system-prompt.ts` 改为模板化，从 Pack 加载
4. 支持通过环境变量 `SKILL_PACK` 指定加载哪个 Pack

**Phase 2：解耦 CLI 工具（1 周）**

1. `pack.json` 声明 CLI 工具依赖
2. Dockerfile 根据 Pack 安装对应的 CLI 工具
3. `canUseTool` 权限逻辑从 Pack 配置读取角色规则

**Phase 3：Gateway 多业务路由（1 周）**

1. session-gateway 支持通过环境变量指定目标镜像
2. 或通过 URL 路径/域名路由到不同的 Skill Pack 容器
3. WarmPool 按 Pack 维护独立的预热池

**Phase 4：第二个业务上线（2-3 周）**

1. 创建新的 Skill Pack
2. 编写业务 Skill + System Prompt
3. 配套 CLI 工具开发
4. 构建镜像，部署新的 ECS Service
5. 配置域名和路由

## 四、其他架构改进建议

### 4.1 Skill 按需加载

**实现方案**：

```typescript
// 1. 将 Skill 目录注入 System Prompt（仅名称+简述）
const skillDirectory = skills.map(s =>
  `- ${s.name}: ${s.oneLiner}`
).join('\n')

// 2. 添加一个 "read_skill" 工具
const readSkillTool = {
  name: "read_skill",
  description: "读取指定 Skill 的完整使用说明",
  parameters: { skillName: { type: "string" } },
  execute: async ({ skillName }) => {
    return fs.readFileSync(`skills/${skillName}/SKILL.md`, 'utf-8')
  }
}

// 3. LLM 在需要时调用 read_skill，获取完整说明
```

**效果**：System Prompt 从 ~5,000 tokens 降到 ~500 tokens Skill 部分。

### 4.2 Context Compaction

**实现方案**：

```typescript
class ContextManager {
  private threshold = 0.95  // 95% 触发压缩
  private warningThreshold = 0.70

  async checkAndCompact(session: Session) {
    const usage = session.tokenCount / session.contextWindow

    if (usage > this.threshold) {
      // 用独立的 Summarizer 对历史做摘要
      const summary = await this.summarize(session.messages)

      // 替换历史消息为摘要
      session.messages = [
        { role: 'system', content: `对话摘要:\n${summary}` },
        ...session.recentMessages(10)  // 保留最近 10 条
      ]
    }
  }
}
```

### 4.3 事件总线

**实现方案**：

```typescript
// session-gateway 中
class EventBus {
  private subscribers = new Map<string, Set<WebSocket>>()

  subscribe(eventType: string, ws: WebSocket) {
    if (!this.subscribers.has(eventType)) {
      this.subscribers.set(eventType, new Set())
    }
    this.subscribers.get(eventType)!.add(ws)
  }

  publish(eventType: string, data: any) {
    const subs = this.subscribers.get(eventType)
    if (subs) {
      for (const ws of subs) {
        ws.send(JSON.stringify({ type: eventType, data }))
      }
    }
  }
}

// 支持的事件类型
type EventType =
  | 'session.created' | 'session.updated' | 'session.terminated'
  | 'message.new' | 'message.streaming' | 'message.complete'
  | 'tool.executing' | 'tool.complete'
  | 'file.modified'
  | 'permission.requested' | 'permission.granted'
```

### 4.4 Build/Plan 双 Agent 模式

参考 OpenCode 的双 Agent 设计：

```jsonc
{
  "agents": {
    "build": {
      "name": "执行助手",
      "description": "全权限业务代理",
      "tools": ["*"],
      "model": "claude-sonnet-4-5"
    },
    "plan": {
      "name": "分析助手",
      "description": "只读分析代理",
      "tools": ["read", "grep", "glob"],
      "model": "claude-sonnet-4-5"
    }
  }
}
```

用户可在前端切换 Agent 模式：
- **执行模式**：正常操作（下单、修改商品等）
- **分析模式**：只读分析（查看数据、分析趋势，不执行任何修改操作）

## 五、改进路线图

```
2026 Q1 (当前)
├── P0: Provider 抽象层设计与 PoC
├── P1: Skill Pack 架构设计
└── P1: Skill 按需注入 PoC

2026 Q2
├── P0: Provider 抽象层实现（支持 Claude + OpenAI + Gemini）
├── P1: Skill Pack 架构实现 + 第一个 Pack (commerce)
├── P1: Context Compaction 实现
└── P2: 事件总线 PoC

2026 Q3
├── P1: 第二个垂直业务 Pack 上线
├── P2: Plugin 系统设计
├── P2: Build/Plan 双 Agent 模式
└── P2: 事件总线实现

2026 Q4
├── P2: Plugin 系统实现
├── P2: 更多 Provider 接入
└── P3: LSP 集成（如需要）
```
