# 04 - 容器与云原生安全

> 从点状防御到纵深防御

---

## 我们现在在哪

当前的安全措施：

```
✅ 有的:
  - JWT 验证（用户认证）
  - EFS Access Point 隔离（容器间文件隔离）
  - 密钥管理（Infisical + SSM）
  - VPC 网络隔离
  - 安全组限制

❌ 没有的:
  - 容器安全加固（root 运行、可写 rootfs）
  - 镜像漏洞扫描
  - 密钥自动轮转
  - 服务间 mTLS
  - 运行时威胁检测
  - 审计日志
```

问题不在于"安全性差"——对你的业务阶段来说，现有措施已经够用。问题在于你需要**知道自己选择性忽略了什么**，以及**什么时候需要补上**。

---

## 核心概念：纵深防御 (Defense in Depth)

```
攻击者需要突破的层次：

  ┌─────────────────────────────┐
  │ 网络层: VPC、安全组、WAF      │ ← 你有
  │  ┌─────────────────────────┐│
  │  │ 认证层: JWT、OAuth       ││ ← 你有
  │  │  ┌─────────────────────┐││
  │  │  │ 容器层: 隔离、加固    │││ ← 部分有
  │  │  │  ┌─────────────────┐│││
  │  │  │  │ 应用层: 输入校验  ││││ ← 部分有
  │  │  │  │  ┌─────────────┐││││
  │  │  │  │  │ 数据层: 加密  │││││ ← 传输加密有，静态加密部分
  │  │  │  │  └─────────────┘││││
  │  │  │  └─────────────────┘│││
  │  │  └─────────────────────┘││
  │  └─────────────────────────┘│
  └─────────────────────────────┘
```

每一层的意义：即使外层被突破，内层仍能保护。这就是为什么"AP 级隔离降为目录级隔离"需要谨慎评估——你去掉了一层防御。

---

## 五个关键领域

### 1. 容器加固

**当前风险**: AI Shell 容器内运行 `optima-agent`，它可以执行 shell 命令（通过 shell 工具）。如果一个恶意用户构造出特殊 prompt 让 agent 执行危险命令...

**CIS Docker Benchmark 关键检查项**:

| 检查项 | 你的状态 | 建议 |
|--------|---------|------|
| 以 non-root 用户运行容器 | ⚠️ 需检查 Dockerfile | `USER aiuser` 在 Dockerfile 中 |
| 只读 rootfs | ❌ | `readonlyRootFilesystem: true` in TaskDef |
| 限制 capabilities | ❌ | `drop: ALL` 然后只加需要的 |
| 禁止特权模式 | ✅ | ECS 默认不允许 |
| 资源限制 | ✅ | TaskDef 中已设置 CPU/Memory |
| 禁止访问 Docker socket | ✅ | ECS 任务默认隔离 |

**最重要的一步**: 确保容器以 non-root 运行 + 只读 rootfs + drop all capabilities。

```json
// ECS TaskDefinition 中：
{
  "containerDefinitions": [{
    "user": "1000:1000",
    "readonlyRootFilesystem": true,
    "linuxParameters": {
      "capabilities": {
        "drop": ["ALL"]
      }
    },
    // 需要写入的目录通过 tmpfs 或 EFS 挂载
    "mountPoints": [
      { "sourceVolume": "workspace", "containerPath": "/mnt/efs" },
      { "sourceVolume": "tmp", "containerPath": "/tmp" }
    ]
  }]
}
```

### 2. 镜像供应链安全

**威胁模型**: 如果你依赖的 base image 或 npm 包中有恶意代码/已知漏洞。

**当前状态**: 没有镜像扫描。

**分层方案**:

```
构建时:
  1. 使用官方/可信 base image（node:20-slim 而非来路不明的镜像）
  2. 固定 base image 版本（node:20.11-slim 而非 node:latest）
  3. npm audit / yarn audit 在 CI 中运行
  4. Trivy 扫描构建产物

推送时:
  5. ECR 开启镜像扫描（免费功能，AWS 原生支持）

运行时:
  6. 定期扫描已部署的镜像
```

**最低成本的第一步**: 开启 ECR 的自动扫描。

```hcl
# Terraform 中，对 ECR 仓库开启扫描
resource "aws_ecr_repository" "ai_shell" {
  name = "optima-ai-shell"

  image_scanning_configuration {
    scan_on_push = true  # ← 加这一行
  }
}
```

这样每次 push 镜像时会自动扫描 CVE，在 AWS Console 中可以查看结果。零成本、零运维。

### 3. 密钥管理进阶

**当前做得好的**: Infisical + SSM，密钥不在代码中。

**可以更好的**:

| 方面 | 当前 | 最佳实践 |
|------|------|---------|
| 密钥轮转 | 手动 | 自动定期轮转（90 天） |
| 泄露检测 | 无 | GitHub Secret Scanning + git-secrets |
| 最小权限 | ⚠️ | 每个服务只能访问自己的密钥路径 |
| 审计 | ⚠️ | 谁在什么时候读取了哪个密钥 |

**密钥轮转的基本思路**:

```
当前: API key 写死在 Infisical → 容器启动时读取 → 永远不变

更好的:
  1. Infisical 中配置轮转策略（90 天）
  2. 新密钥生成后，同时保留新旧两个版本
  3. 下次容器启动/重启自动拿到新密钥
  4. 旧密钥在过渡期后删除

最好的（对于数据库密码）:
  1. 数据库支持双密码（PostgreSQL 不原生支持，但可以通过角色实现）
  2. 或者用 IAM 认证（RDS 支持 IAM token 登录）
```

**建议优先级**: 先开 GitHub Secret Scanning（免费），再考虑自动轮转。

### 4. 网络安全

**当前**: 安全组限制了端口级访问。

**缺少的**:

- **服务间认证**: session-gateway 调用 ECS task 的 WebSocket 连接没有认证。如果某个容器被入侵，可以冒充任何 session 连接 Gateway。

- **Network Policy / Service Mesh**: 无法限制"只有 session-gateway 能调用 ECS API"之类的策略。

**务实的建议**: 对你目前的规模，安全组已经够用。但要知道：
- 如果将来有多团队、多租户，需要 service mesh（如 AWS App Mesh）
- 内部 WebSocket 连接（`/internal/task/*`）应该至少验证一个 shared secret

```typescript
// 简单的内部认证：容器启动时注入一个随机 token
// ws-bridge.js 连接时带上这个 token
// session-gateway 验证 token 匹配

// 环境变量: INTERNAL_WS_TOKEN=random-uuid-generated-at-start
const ws = new WebSocket(`wss://gateway/internal/task/${sessionId}`, {
  headers: { 'X-Internal-Token': process.env.INTERNAL_WS_TOKEN }
});
```

### 5. AI 特有的安全考虑

**这是你项目特有的威胁面**:

- **Prompt Injection**: 用户构造恶意 prompt，让 optima-agent 执行危险操作（读取其他用户文件、发送网络请求到恶意地址）

- **Tool Abuse**: shell 工具理论上可以执行任何系统命令

**当前缓解措施**:
- shell 工具有 timeout（30s）
- 工作目录限制在 `/home/aiuser`
- 文件操作工具验证路径

**可以加强的**:
- shell 工具的命令白名单或黑名单
- seccomp profile 限制系统调用（禁止 mount、ptrace 等）
- 网络出站限制（只允许访问 Anthropic API 和特定服务）

---

## 安全评估框架：STRIDE

当你评估一个新功能的安全性时，用 STRIDE 检查清单：

| 威胁 | 含义 | 对 AI Shell 的检查 |
|------|------|-------------------|
| **S**poofing（伪装） | 冒充其他身份 | JWT 是否正确验证？内部 WS 有认证吗？ |
| **T**ampering（篡改） | 修改数据 | 消息在传输中能被篡改吗？EFS 文件权限对吗？ |
| **R**epudiation（抵赖） | 否认做过的事 | 有操作审计日志吗？ |
| **I**nformation Disclosure（信息泄露） | 看到不该看的 | 共享 AP 后用户能访问他人文件吗？ |
| **D**enial of Service（拒绝服务） | 使系统不可用 | 一个用户能耗尽预热池吗？有配额限制吗？ |
| **E**levation of Privilege（提权） | 获得更高权限 | 容器能突破到宿主机吗？普通用户能 root 吗？ |

每次设计新功能时，过一遍这 6 个问题，大部分安全问题都能提前发现。

---

## 实践路线

### 立即可做（几分钟）

1. 开启 ECR 镜像扫描（Terraform 一行配置）
2. 开启 GitHub Secret Scanning（repo settings 里勾选）

### 短期（结合 Phase 0-1）

3. 检查 Dockerfile：确认 non-root 用户、固定 base image 版本
4. 给内部 WebSocket 端点加简单的 shared secret 认证
5. 在 CI 中加 `npm audit`

### 中期（Phase 2-3 时）

6. 共享 AP 迁移后，评估目录权限方案（700 + 动态 UID）
7. 预热池实现时，加 seccomp profile 和网络出站限制
8. 考虑 Quota（每用户并发 session 限制）防止 DoS

---

## 推荐资源

| 资源 | 类型 | 时间 | 说明 |
|------|------|------|------|
| [CIS Docker Benchmark](https://www.cisecurity.org/benchmark/docker) | 文档 | 2h | 容器安全的权威检查清单 |
| [AWS ECS Security Best Practices](https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/security.html) | 文档 | 1h | 我们用的平台的安全指南 |
| [OWASP Top 10 for LLM Applications](https://owasp.org/www-project-top-10-for-large-language-model-applications/) | 文档 | 1h | AI 应用特有的安全威胁 |
| [AWS Well-Architected Security Pillar](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/) | 文档 | 按需 | AWS 安全架构的完整框架 |
| [Trivy - Container Scanner](https://github.com/aquasecurity/trivy) | 工具 | 30min | 开源镜像扫描，可集成 CI |
