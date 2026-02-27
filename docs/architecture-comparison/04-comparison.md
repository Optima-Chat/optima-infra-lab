# 三方核心能力对比表

> OpenCode vs OpenClaw vs Optima 详细对比

## 一、总体定位

| 维度 | OpenCode | OpenClaw | Optima |
|------|----------|----------|--------|
| **定位** | 开源终端 AI 编码助手 | 开源通用 AI Agent 操作系统 | 电商垂直 AI Agent 平台 |
| **核心场景** | 代码编写/调试/重构 | 生活/工作/自动化（通过消息应用）| 电商运营（商品/订单/营销）|
| **Stars** | 110K+ | 190K+ | 私有 |
| **开源** | MIT | MIT | 闭源 |
| **创始团队** | Dax Raad (SST/Anomaly Co) | Peter Steinberger (→ OpenAI) | Optima 团队 |
| **语言** | TypeScript | TypeScript | TypeScript |
| **运行时** | Bun | Node.js 22 | Node.js 20 |

## 二、系统架构对比

| 维度 | OpenCode | OpenClaw | Optima |
|------|----------|----------|--------|
| **架构风格** | Client/Server (HTTP+SSE) | Gateway-centric (WebSocket) | 三层分离 (前端+网关+Agent) |
| **通信协议** | HTTP REST + SSE | WebSocket (ws://127.0.0.1:18789) | WebSocket + HTTP |
| **服务器框架** | Hono (Bun) | 自研 Node.js | Next.js + 自研 |
| **进程模型** | 单进程（Server + Agent 同进程）| 单进程 Gateway | 多进程（网关 + 容器化 Agent）|
| **多客户端** | TUI + Desktop + IDE + Web | CLI + macOS + iOS + Android + Web | Web UI |
| **客户端共享** | 多客户端可连同一 Server | 多客户端连同一 Gateway | 目前仅 Web 前端 |

### 架构关键差异

```
OpenCode:     [Client] ←HTTP/SSE→ [Server+Agent 同进程]
OpenClaw:     [Client] ←WebSocket→ [Gateway+Agent 同进程]
Optima:       [前端] ←WS→ [Gateway] ←WS→ [容器化 Agent]
                                         ↑ 独立进程，可弹性伸缩
```

**Optima 独有的分离优势**：Gateway 和 Agent 完全解耦，Agent 在独立容器中运行，支持：
- 多用户多租户并发
- 容器级资源隔离
- 弹性伸缩（ECS Auto Scaling）
- 预热池加速启动

## 三、Agent 系统对比

| 维度 | OpenCode | OpenClaw | Optima |
|------|----------|----------|--------|
| **Agent Runtime** | 自研 (Vercel AI SDK) | Pi Runtime (外部嵌入) | Claude Agent SDK (封装) |
| **内置 Agent** | Build (全权限) + Plan (只读) | Pi Agent (极简) | 单一 Agent (bypassPermissions) |
| **自定义 Agent** | JSON/Markdown 定义 | 通过 AGENTS.md 配置 | 不支持 |
| **Agent 切换** | Tab 键切换 | 按场景自动 | 无 |
| **系统提示词** | 程序化组装 | < 1,000 tokens (极简) | ~2000+ tokens (含 Skill 列表) |
| **SDK 依赖度** | 低 (自研循环) | 低 (Pi 极简) | 高 (~80%) |

### Agent 循环对比

**OpenCode** — 最完整的自研循环：
```
用户输入 → 准备上下文 → Vercel AI SDK → LLM 响应
    → Tool Call → 执行 → LSP 诊断反馈 → 继续循环
    → 纯文本 → 持久化 → SSE 广播
```

**OpenClaw (Pi)** — 最极简的循环：
```
用户消息 → 注入 AGENTS.md/SOUL.md/TOOLS.md + 按需 Skill
    → 查询 Memory → 调用 LLM → Tool Call → 执行(可能沙盒)
    → 结果流式回传 → 持久化 Session
```

**Optima** — SDK 驱动的循环：
```
用户消息 → session-gateway 路由 → 容器内 optima-agent
    → Claude SDK query() → LLM → Tool Call → canUseTool 检查
    → 执行 → 结果反馈 → 持久化 → ws-bridge 回传
```

## 四、Tool 系统对比

| 维度 | OpenCode | OpenClaw | Optima |
|------|----------|----------|--------|
| **核心工具数** | 7 | 4 | SDK 内置 (read/write/edit/bash 等) |
| **工具列表** | read, write, edit, grep, glob, bash, LSP | read, write, edit, bash | SDK 管理 |
| **独有工具** | **LSP 诊断** | 无（靠 bash 自我扩展）| **Memory MCP** |
| **权限模型** | allow/ask/deny + 模式匹配 | Layer1 身份 + Layer2 范围 | bypassPermissions + canUseTool 回调 |
| **沙盒** | **无**（明确声明不提供）| Docker 沙盒 | 容器隔离 |
| **自定义工具** | Plugin API (`@opencode-ai/plugin`) | Skill 中定义 bash 脚本 | 不支持 |
| **MCP 支持** | 原生 (stdio + remote) | 桥接 (mcporter) | 部分 (Memory MCP) |

### 权限控制对比

```
OpenCode:
  bash: { "git *": "allow", "rm -rf *": "deny", "*": "ask" }
  → 模式匹配，最灵活

OpenClaw:
  Layer 1: 身份验证（DM 配对、白名单）
  Layer 2: 工具策略 + 沙盒隔离
  → 多层安全，最严格

Optima:
  canUseTool(toolName, input) → allow/deny
  → 程序化控制，按角色决策
```

## 五、Skill 系统对比

| 维度 | OpenCode | OpenClaw | Optima |
|------|----------|----------|--------|
| **Skill 格式** | Markdown (`.opencode/agent/`) | Markdown (`SKILL.md`) | Markdown (`.claude/skills/`) |
| **加载方式** | Agent 定义时指定 | **按需注入**（LLM 判断相关性）| **全量注入** System Prompt |
| **Skill 数量** | 自定义 | 5,705+ (ClawHub) | 18 个内置 |
| **热重载** | 需重启 | 250ms debounce | 需重新部署 |
| **AI 自创建** | 不支持 | **支持**（Agent 观察模式后自动生成）| 不支持 |
| **社区市场** | 无 | ClawHub | 无 |
| **版本控制** | Git | Git + ClawHub 版本 | Git |

### 关键差异：Skill 注入策略

```
OpenCode:  Agent 定义时静态绑定 Skill
           ↓ 编译时确定，精确控制

OpenClaw:  列表注入 → LLM 判断相关 → 按需读取 SKILL.md
           ↓ 运行时按需，节省 Context

Optima:    全部 18 个 Skill 注入 System Prompt
           ↓ 简单直接，但消耗 Context Window
```

## 六、Session / 持久化对比

| 维度 | OpenCode | OpenClaw | Optima |
|------|----------|----------|--------|
| **存储引擎** | SQLite (本地) | JSONL 文件 | PostgreSQL (服务端) |
| **Session 类型** | 单用户本地 | DM/群聊/隔离 | 多用户多租户 |
| **消息格式** | 结构化表 | JSONL 追加写入 | Prisma ORM 结构化 |
| **Context 压缩** | **自动** (70%预警→95%触发) | 依赖 LLM Provider | 依赖 Claude SDK |
| **对话恢复** | 本地文件重读 | JSONL 重播 | Session 状态机 + restore_conversations |
| **跨设备** | 不支持（本地 SQLite）| WebSocket 多设备同步 | 服务端持久化 |
| **历史搜索** | SQL 查询 | 语义搜索（Memory 插件）| 数据库查询 |

### Context 压缩策略

```
OpenCode（最完善）:
  70% → 预警
  90% → 紧急预警
  95% → 自动触发 Summarization Agent
       → 用摘要替换原始历史
       → 裁剪旧工具输出
       → 用户无感知

OpenClaw:
  依赖底层 LLM Provider 的 Context 管理
  Memory 系统提供语义搜索辅助

Optima:
  依赖 Claude SDK 内部行为
  无显式压缩策略
  → 潜在风险：长对话可能超出 Context Window
```

## 七、LLM Provider 对比

| 维度 | OpenCode | OpenClaw | Optima |
|------|----------|----------|--------|
| **Provider 数量** | **75+** | 多个（Claude, GPT, DeepSeek, Gemini, Ollama）| 2 (OpenAI + Anthropic) |
| **默认模型** | 可配置 | 可配置 | gpt-4.1-mini |
| **Provider 抽象** | Vercel AI SDK + Models.dev | Pi 内置适配 | Claude Agent SDK (仅 Claude) |
| **本地模型** | 支持 (llama.cpp) | 支持 (Ollama) | 不支持 |
| **模型切换** | 配置文件/运行时 | 配置/运行时 | 前端 UI 选择 |
| **转换层** | 消息格式、Tool Call ID、Schema 适配 | Pi 统一封装 | 无（SDK 处理）|

### Provider 灵活性

```
OpenCode:  75+ Provider → Vercel AI SDK 统一 → Agent 无感知
           ↓ 最开放，甚至支持 llama.cpp 本地

OpenClaw:  ~6 Provider → Pi 内部适配
           ↓ 较灵活，支持本地 Ollama

Optima:    前端选模型 → 但 Agent 层锁定 Claude SDK
           ↓ 前端有 21 个模型选项，但 Agent 只能用 Claude
```

**注意**：Optima 前端 agentic-chat 支持 21 个模型，但 session-gateway + optima-agent 只支持 Claude（因为 Agent 层使用 Claude Agent SDK）。这意味着前端的模型选择对 Agent 行为无影响。

## 八、部署运维对比

| 维度 | OpenCode | OpenClaw | Optima |
|------|----------|----------|--------|
| **部署方式** | npm install / 源码 | npm / Docker / Fly.io / Render | ECS / Docker / Lambda / AgentCore |
| **容器化** | 不需要（本地工具）| Docker Compose | **深度容器化**（Gateway + Agent 分离）|
| **弹性伸缩** | N/A（单用户）| N/A（单用户）| **ECS Auto Scaling** |
| **预热池** | N/A | N/A | **WarmPool** (260ms 启动) |
| **多租户** | 不支持 | 有限（通过 Session 隔离）| **原生支持**（EFS Access Point）|
| **Token 管理** | 用户自备 | 用户自备 | **TokenPool**（多 Token 轮转）|
| **监控** | 无 | 无 | CloudWatch + Observability |
| **CI/CD** | 无 | Docker Build | GitHub Actions + ECS Update |

### Optima 的云原生优势

Optima 在部署运维方面远超两个开源项目（它们本质是单用户工具）：

1. **Bridge 抽象**：一套代码适配 4 种运行环境
2. **WarmPool**：预热容器实现亚秒级响应
3. **TokenPool**：多 Token 分散限速压力
4. **弹性伸缩**：CPU > 70% 自动扩容
5. **文件系统隔离**：EFS Access Point 实现用户级隔离
6. **Lazy Start**：不发消息不启动容器

## 九、安全模型对比

| 维度 | OpenCode | OpenClaw | Optima |
|------|----------|----------|--------|
| **沙盒** | 无 | Docker 沙盒 + Full Gateway Docker | 容器隔离 |
| **身份验证** | 无（本地工具）| DM 配对 + 白名单 + @提及门控 | JWT + OAuth |
| **工具权限** | allow/ask/deny 模式匹配 | 多层策略 + 执行审批 | canUseTool 回调 |
| **文件系统** | 完全访问 | bind-mount 限制 | EFS Access Point 隔离 |
| **网络** | 无限制 | 无限制 | VPC + Security Group |
| **已知风险** | 明确不提供沙盒 | Tool Poisoning + 恶意 Skill | 容器逃逸 |

## 十、扩展性对比

| 维度 | OpenCode | OpenClaw | Optima |
|------|----------|----------|--------|
| **插件系统** | `@opencode-ai/plugin` (npm) | Skill + Extensions | 无 |
| **MCP** | 原生 (stdio + remote) | 桥接 (mcporter, 13K+ 服务) | Memory MCP 仅 |
| **自定义工具** | Plugin API | Bash 脚本/Skill | 不支持 |
| **自定义 Agent** | JSON/Markdown | AGENTS.md + SOUL.md | 不支持 |
| **社区生态** | 无 | ClawHub (5,705+ Skill) | 无 |
| **Hooks** | before/after tool call | 热重载 + AI 自创建 | 无 |

## 十一、总结矩阵

| 能力 | OpenCode | OpenClaw | Optima |
|------|:--------:|:--------:|:------:|
| Provider 无关 | ★★★★★ | ★★★☆☆ | ★☆☆☆☆ |
| 工具系统 | ★★★★★ | ★★★☆☆ | ★★★☆☆ |
| Skill 生态 | ★★☆☆☆ | ★★★★★ | ★★★☆☆ |
| Session 管理 | ★★★★☆ | ★★★☆☆ | ★★★★★ |
| Context 管理 | ★★★★★ | ★★★☆☆ | ★★☆☆☆ |
| 多租户/云原生 | ★☆☆☆☆ | ★☆☆☆☆ | ★★★★★ |
| 安全隔离 | ★☆☆☆☆ | ★★★★☆ | ★★★★☆ |
| 扩展性 | ★★★★☆ | ★★★★★ | ★★☆☆☆ |
| 代码质量 | ★★★★★ | ★★★★☆ | ★★★☆☆ |
| 文档 | ★★★★☆ | ★★★☆☆ | ★★☆☆☆ |
