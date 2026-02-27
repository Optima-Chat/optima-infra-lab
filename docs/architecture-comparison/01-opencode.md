# OpenCode 技术架构详解

> GitHub: [opencode-ai/opencode](https://github.com/opencode-ai/opencode) (当前主仓库 anomalyco/opencode)
> 官网: [opencode.ai](https://opencode.ai/)
> Stars: 110,000+ | Contributors: 700+ | 月活开发者: 250万+

## 一、项目历史

OpenCode 最初是 Go 语言编写的终端 AI 编码助手，使用 Bubble Tea 构建 TUI。2025 年发生重大分裂——原项目与 Charm 合作改名为 Crush，而由 Dax Raad 和 Adam Doty（SST/Anomaly Co 核心人物）主导的 fork 用 TypeScript + Bun 完全重写，形成了现在的 OpenCode。

## 二、技术栈

| 层级 | 技术 |
|------|------|
| **运行时** | Bun (TypeScript/JavaScript runtime) |
| **语言** | TypeScript 5.8.2 |
| **HTTP 框架** | Hono |
| **TUI** | 正迁移至 opentui（自研终端 UI 框架） |
| **AI SDK** | Vercel AI SDK |
| **模型目录** | Models.dev (75+ providers, 1000+ models) |
| **数据库** | SQLite (本地持久化) |
| **Monorepo** | Bun Workspaces + Turbo v2.5.6 |
| **搜索** | ripgrep (内置) |
| **LSP** | Language Server Protocol 集成 |

## 三、系统架构

### 3.1 Client/Server 分离

OpenCode 的核心设计是将所有业务逻辑放在服务端（`packages/opencode`），多种前端共享同一后端：

```
┌─ TUI ─┐ ┌─ Desktop ─┐ ┌─ VS Code ─┐ ┌─ Web ─┐
└───┬────┘ └─────┬─────┘ └─────┬─────┘ └───┬───┘
    └────────────┴──────┬──────┴────────────┘
                   HTTP + SSE
    ┌────────────────────────────────────────────┐
    │         Hono HTTP Server (Bun)             │
    │  ┌─────────────────────────────────────┐   │
    │  │       REST API + SSE Stream         │   │
    │  └─────────────────────────────────────┘   │
    │                                            │
    │  ┌────────┐ ┌────────┐ ┌──────────┐       │
    │  │Session │ │ Agent  │ │ Provider │       │
    │  │Manager │ │ System │ │ Layer    │       │
    │  └───┬────┘ └───┬────┘ └────┬─────┘       │
    │      │          │           │              │
    │  ┌───┴──────────┴───────────┴──────────┐   │
    │  │       Tool Execution Engine         │   │
    │  └─────────────────────────────────────┘   │
    │                                            │
    │  ┌──────────┐ ┌──────────┐ ┌──────────┐   │
    │  │ SQLite   │ │ Event    │ │ Plugin   │   │
    │  │ Storage  │ │ Bus      │ │ System   │   │
    │  └──────────┘ └──────────┘ └──────────┘   │
    └────────────────────────────────────────────┘
```

### 3.2 Monorepo 包结构

```
packages/
├── opencode/          # 核心包 - HTTP 服务器 + CLI + Agent 逻辑
│   ├── src/
│   │   ├── session/   # Session 管理
│   │   ├── agent/     # Agent 系统
│   │   ├── provider/  # LLM Provider 抽象
│   │   ├── tool/      # 工具系统
│   │   └── config/    # 配置系统
├── tui/               # 终端 UI (opentui)
├── desktop/           # 桌面应用
├── web/               # Web 应用
├── console/           # Console 应用
├── vscode/            # VS Code 扩展
├── sdk/               # JS/TS SDK (供外部集成)
├── plugin/            # 插件系统 (@opencode-ai/plugin)
└── scripts/           # 构建/发布脚本
```

依赖层级清晰：
1. **基础层**: SDK、工具库（无内部依赖）
2. **扩展层**: 插件系统、UI 组件
3. **应用层**: CLI、桌面、Web、Console
4. **集成层**: VS Code 等平台特定集成

## 四、Agent 系统

### 4.1 内置 Agent

| Agent | 说明 | 权限 |
|-------|------|------|
| **Build** (默认) | 全权限开发代理 | 所有工具可用 |
| **Plan** | 只读分析代理 | 编辑工具禁用 |

用户通过 `Tab` 键在 Build 和 Plan 之间切换。

### 4.2 自定义 Agent

支持两种定义方式：

**JSON 配置 (opencode.json)**:
```jsonc
{
  "agent": {
    "my-reviewer": {
      "name": "Code Reviewer",
      "model": "anthropic/claude-sonnet-4-20250514",
      "prompt": ".opencode/prompts/reviewer.md",
      "tools": {
        "read": "allow",
        "edit": "deny",
        "bash": "deny"
      }
    }
  }
}
```

**Markdown 文件 (`.opencode/agent/`)**:
将 Agent 定义写成 Markdown 文件，便于版本控制和审计。

### 4.3 Agent Loop

```
用户输入 → HTTP POST → Session.prompt()
  → 准备 [system prompt + 历史消息 + 摘要 + 工具定义]
  → 调用 LLM API (Vercel AI SDK)
  → LLM 响应 (文本 + tool_use)
  → 如果有 tool_use:
    → 执行 tool.execute()
    → 结果写回消息历史
    → 如果是文件修改，查询 LSP 获取诊断
    → 诊断结果反馈给 LLM
    → 回到 "调用 LLM API" 继续循环
  → 如果纯文本:
    → 持久化到 SQLite
    → 通过 Event Bus (SSE) 广播
    → 所有客户端实时渲染
```

**LSP 反馈循环是最大亮点**: 当 LLM 修改文件后，OpenCode 查询 LSP 服务器获取诊断信息（未定义变量、类型错误等），反馈给 LLM 让它自我修正。这有效防止了代码修改"跑偏"。

## 五、Provider 系统

### 5.1 Vercel AI SDK + Models.dev

OpenCode 通过 Vercel AI SDK 实现了最广泛的 Provider 支持：

```
┌──────────────────────────────────────────┐
│           Session / Agent Layer          │
└─────────────────┬────────────────────────┘
                  ↓
┌──────────────────────────────────────────┐
│      Provider Transformation Layer       │
│  (消息格式转换、tool call ID 适配、       │
│   reasoning 内容处理、缓存机制、          │
│   schema 格式适配)                       │
└─────────────────┬────────────────────────┘
                  ↓
┌──────────────────────────────────────────┐
│          Vercel AI SDK + Models.dev      │
│  (75+ providers, 1000+ models)           │
└──────────────────────────────────────────┘
```

支持的 Provider 包括：Anthropic, OpenAI, Google Gemini, AWS Bedrock, Groq, Azure OpenAI, OpenRouter, GitHub Copilot, xAI, Together AI, Fireworks AI, llama.cpp (本地) 等。

### 5.2 Provider Transformation 层

关键的适配层，处理不同 LLM API 的格式差异：
- 消息格式转换
- Tool call ID 格式差异
- Reasoning/thinking 内容适配
- 缓存机制差异
- Schema 格式转换

## 六、Tool 系统

### 6.1 内置工具

| 工具 | 功能 | 底层实现 |
|------|------|----------|
| **read** | 读取文件内容 | 文件系统 |
| **write** | 创建/覆写文件 | 文件系统 |
| **edit** | 精确字符串替换 | 文件系统 |
| **grep** | 正则搜索内容 | ripgrep |
| **glob** | 模式匹配文件 | ripgrep |
| **bash** | 执行 shell 命令 | Bun 子进程 |
| **LSP** | 语言服务器诊断 | LSP Protocol |

### 6.2 权限系统

支持三级权限 + 模式匹配：

| 模式 | 说明 |
|------|------|
| **allow** | 自动执行 |
| **ask** | 请求确认 |
| **deny** | 禁止执行 |

```jsonc
{
  "permission": {
    "bash": {
      "git *": "allow",      // git 命令自动放行
      "rm -rf *": "deny",    // 危险命令禁止
      "*": "ask"              // 其他询问
    }
  }
}
```

**重要**: OpenCode 明确声明不提供沙箱隔离，权限系统仅作为 UX 辅助。

### 6.3 Plugin 自定义工具

```typescript
import { tool } from "@opencode-ai/plugin"
import { z } from "zod"

export default tool({
  name: "my-tool",
  description: "Does something useful",
  parameters: z.object({ input: z.string() }),
  execute: async ({ input }, ctx) => {
    return { result: "done" }
  }
})
```

## 七、Session 管理

### 7.1 SQLite 持久化

Session、Messages、Tool Executions 分表存储，支持：
- 父子 Session 关系
- JSON 导出
- Token 用量和成本统计

### 7.2 Context Window 自动压缩

| 阈值 | 行为 |
|------|------|
| **70%** | Token 用量预警 |
| **90%** | 紧急预警 |
| **95%** | 自动触发 Compaction |

Compaction 流程：
1. 检测到 tokens 达到 context window 的 95%
2. 用专门的 Summarization Agent 对历史对话摘要
3. 用摘要替换原始历史
4. 裁剪旧工具输出回收空间
5. Session 继续，用户无感知

## 八、事件驱动通信

使用 Server-Sent Events (SSE) 实现实时推送，支持 19 种事件类型：
- Session 事件（创建、更新、删除）
- Message 事件（新消息、流式更新）
- File 事件（文件修改通知）
- Permission 事件（权限请求/批准）
- System 事件（系统状态变更）

多客户端可同时连接同一后端，共享 Session 实时更新。

## 九、MCP 和扩展

### MCP 支持

原生支持 stdio 和 remote 两种 MCP 连接：

```jsonc
{
  "mcp": {
    "my-mcp-server": {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "my-mcp-server"]
    },
    "remote-mcp": {
      "type": "remote",
      "url": "https://example.com/mcp",
      "headers": { "Authorization": "Bearer xxx" }
    }
  }
}
```

### Plugin 系统

- 本地文件 (`.opencode/plugins/`) 或 npm 包
- 可添加自定义工具、MCP 服务器、Agent、Commands
- 支持 before/after tool call hooks
- 外部 npm 依赖自动安装

## 十、配置系统

三层优先级（低→高）：
1. Remote Config（远程基础配置）
2. Global Config（`~/.config/opencode/opencode.json`）
3. Project Config（`项目根/opencode.json`）

## 十一、对比定位

| 维度 | OpenCode | Claude Code | Cursor |
|------|----------|-------------|--------|
| 开源 | MIT | 闭源 | 闭源 |
| 架构 | Provider 无关 | Anthropic 绑定 | OpenAI 为主 |
| 交互 | 终端+桌面+IDE+Web | 纯终端 | IDE |
| 模型 | 75+ providers | 仅 Claude | 多模型 |
| 本地模型 | 支持 | 不支持 | 有限 |
| LSP | 原生集成 | 无 | IDE 内置 |
| Context 管理 | 自动压缩 | /compact 命令 | 自动 |

## 参考链接

- [How Coding Agents Actually Work: Inside OpenCode](https://cefboud.com/posts/coding-agents-internals-opencode-deepdive/)
- [DeepWiki - sst/opencode](https://deepwiki.com/sst/opencode)
- [OpenCode 官方文档](https://opencode.ai/docs/)
