# OpenClaw 技术架构详解

> GitHub: [openclaw/openclaw](https://github.com/openclaw/openclaw)
> 官网: [openclaw.ai](https://openclaw.ai/)
> Stars: 190K+ | Forks: 20,000+ | Commits: 14,724+ | 许可: MIT

## 一、项目背景

OpenClaw（前身 Clawdbot → Moltbot）由奥地利开发者 Peter Steinberger 于 2025 年 11 月创建。2026 年 1 月因 Anthropic 商标投诉更名为 Moltbot，三天后再次更名为 OpenClaw。2026 年 2 月，Steinberger 宣布加入 OpenAI，项目移交开源基金会。

**关键区别**: OpenClaw 不是编码工具，而是一个**通用 AI Agent 操作系统**，通过消息应用与用户交互，覆盖生活/工作/自动化等多领域。

## 二、四层架构

```
┌─────────────────────────────────────────────────┐
│              Intelligence Layer                   │
│   LLM Providers: Claude, GPT, DeepSeek,          │
│   Gemini, Ollama (本地模型)                       │
├─────────────────────────────────────────────────┤
│              Execution Layer                      │
│   Pi Agent Runtime: 4 Core Tools +               │
│   Extensions + Docker Sandbox                    │
├─────────────────────────────────────────────────┤
│              Integration Layer                    │
│   Channels: WhatsApp, Telegram, Discord,         │
│   Slack, Signal, iMessage, Teams, Matrix         │
├─────────────────────────────────────────────────┤
│              Control Plane (Gateway)              │
│   WebSocket Server @ ws://127.0.0.1:18789        │
│   Sessions, Routing, Security, State             │
└─────────────────────────────────────────────────┘
```

## 三、Gateway 控制平面

Gateway 是整个系统的**单一事实来源**，以单一 Node.js 进程运行。

### 核心职责

| 功能 | 说明 |
|------|------|
| Agent 执行 | 运行 AI 模型，执行 tool use 和流式输出 |
| Channel 路由 | 从多个消息平台接收消息，路由到对应 Agent |
| Session 管理 | JSONL 文件持久化对话历史 |
| Tool 执行 | 级联策略和沙盒隔离 |
| Node 协调 | 配对伴随设备（macOS、iOS、Android）的平台能力 |

### 通信协议

所有客户端（CLI、macOS 菜单栏、iOS/Android Node、Control UI、WebChat）通过 WebSocket 连接 Gateway。Gateway 在同一端口处理：
- WebSocket 控制消息
- HTTP API（OpenAI 兼容格式）
- 浏览器端 Control UI

### 状态持久化

`~/.openclaw/` 目录下存储所有持久状态：
- 网关配置、环境变量
- Agent 数据、认证档案
- 对话记录（JSONL 格式）
- 凭证和会话

## 四、Pi Agent Runtime

OpenClaw 最有特色的部分。它**没有自己实现 Agent Runtime**，而是内嵌了 **Pi** ——由 Mario Zechner 编写的极简编码 Agent。

### Pi 设计哲学

> "你不放进去的东西比你放进去的东西更重要"

- 系统提示词不到 1,000 tokens
- 仅 4 个核心工具
- 需要 Agent 做新事情？让 Agent 自己扩展自己

### 4 个核心工具

| 工具 | 功能 |
|------|------|
| `read` | 读取文件和图片 |
| `write` | 创建/覆写文件 |
| `edit` | 精确编辑文件 |
| `bash` | 执行 shell 命令 |

有了这 4 个工具，Agent 就能"自我扩展"——编写脚本、安装包、创建配置文件。

### 执行循环

```
1. 接收用户消息
2. 组装上下文：
   - AGENTS.md、SOUL.md、TOOLS.md（workspace 注入）
   - 按需注入相关 Skills（不是全部）
   - 查询 Memory 系统，检索语义相似历史
   - 加载 Session 历史
3. 调用 LLM（流式输出）
4. 如果有 Tool Call：
   - 执行工具（可能在 Docker 沙盒中）
   - 结果流式回传
   - 模型继续生成
5. 持久化更新的 Session 状态
```

## 五、Session / Sandbox 机制

### Session 管理

| 类型 | 说明 |
|------|------|
| DM | 通常共享一个主 Session |
| 群聊 | 每个群聊独立 Session |
| 隔离 Session | 特定联系人/安全场景 |

### Docker 沙盒

两种互补模式：

| 模式 | 说明 |
|------|------|
| **Full Gateway in Docker** | 整个 Gateway 在容器中（容器边界隔离） |
| **Tool Sandbox** | Gateway 在主机，工具执行在容器中隔离 |

沙盒策略：
- 非主 Session 可在 Docker 容器中运行
- 容器通过 bind-mount 只能访问选定目录
- 防止 Skill 注入攻击访问整个文件系统

### 多层安全

| 层级 | 机制 |
|------|------|
| Layer 1: Identity | DM 配对（审批码）、白名单、群组白名单、@提及门控 |
| Layer 2: Scope | 工具策略、沙盒隔离、执行审批 |
| Node 权限 | macOS TCC 集成、每 Session bash 提升切换 |

## 六、Skill 系统

### Skill = Markdown

Skill 不是编译代码，而是 **Markdown 格式的指令文档** (`SKILL.md`)。

### Skill 生命周期

1. Agent 启动，加载 Skill 列表
2. 上下文组装时，注入精简的 Skill 清单
3. LLM 判断某 Skill 相关时，**按需读取** SKILL.md
4. 热重载：编辑文件后 Agent 下一轮感知（250ms debounce）
5. **Agent 可自己创建和编辑 Skill** — 观察用户使用模式，自动生成

### Skill 来源

| 来源 | 说明 |
|------|------|
| Bundled | 内置技能 |
| Managed | 通过 ClawHub 安装 |
| Workspace | 用户自定义 |

### ClawHub

OpenClaw 的官方技能注册表，定位为 "AI Agent 的 npm"。截至 2026 年 2 月托管 **5,705+** 个社区 Skill。

### MCP 集成

通过 `mcporter` 桥接支持 MCP，可接入 13,000+ 个 MCP 服务器。但 VISION.md 明确**不会将 MCP 作为一等运行时**，保持桥接方式以维护灵活性。

### Memory 系统

支持多种 Memory 插件，提供语义搜索。使用 Markdown 文件作为单一事实来源，零外部依赖。

## 七、多通道集成

OpenClaw 支持 50+ 集成：

**消息平台**: WhatsApp (Baileys), Telegram (grammY), Slack (Bolt), Discord (discord.js), Signal (signal-cli), iMessage (BlueBubbles), Microsoft Teams, Google Chat, Matrix, Zalo, WebChat

**其他能力**: 语音 (ElevenLabs)、Camera、Screen Recording、Location、Cron Jobs、Webhooks、Gmail Pub/Sub

## 八、代码仓库结构

```
openclaw/openclaw/                  # pnpm monorepo
├── src/                           # TypeScript 源代码
│   ├── cli/                      # CLI 入口
│   ├── commands/                 # 命令实现
│   ├── infra/                    # 基础设施
│   └── media/                    # 媒体处理
├── apps/                          # 伴随应用
│   ├── macOS/ (Swift)            # macOS 菜单栏
│   ├── iOS/ (Swift)              # iOS Node
│   └── Android/ (Kotlin)        # Android Node
├── ui/                            # React Web 界面
├── extensions/                    # 插件 (workspace packages)
├── skills/                        # 内置技能
├── packages/                      # 共享包
├── AGENTS.md                      # Agent 上下文注入
├── SOUL.md                        # Agent 个性定义
└── TOOLS.md                       # 工具说明注入
```

### 技术栈

| 类别 | 技术 |
|------|------|
| 语言 | TypeScript (主), Swift, Kotlin, Python |
| 运行时 | Node.js >= 22 |
| 包管理 | pnpm (monorepo) |
| 构建 | tsdown |
| 代码检查 | oxlint, oxfmt |
| 测试 | Vitest + V8 coverage (70% 阈值) |
| 文档 | Mintlify (docs.openclaw.ai) |

## 九、部署

| 方式 | 说明 |
|------|------|
| npm | `npm install -g openclaw@latest && openclaw onboard --install-daemon` |
| Docker | `docker-compose.yml`，Volume 持久化 `~/.openclaw/` 和 workspace |
| Source | `git clone + pnpm install + pnpm build` |
| Fly.io | 内置 `fly.toml`，一键部署 |
| Render | `render.yaml` |

## 十、安全争议

尽管完全免费开源，OpenClaw 引发了安全争议：
- CrowdStrike 和 Bitdefender 警告了 Tool Poisoning 和恶意 Skill 风险
- 社区上传的 Skill 中已发现数据外泄脚本
- 攻击面较大（消息、文件、浏览器等多维度权限）

## 参考链接

- [OpenClaw Architecture, Explained](https://ppaolo.substack.com/p/openclaw-system-architecture-overview)
- [Architecture Deep Dive - DeepWiki](https://deepwiki.com/openclaw/openclaw/15.1-architecture-deep-dive)
- [Pi: The Minimal Agent Within OpenClaw](https://lucumr.pocoo.org/2026/1/31/pi/)
- [OpenClaw Wikipedia](https://en.wikipedia.org/wiki/OpenClaw)
