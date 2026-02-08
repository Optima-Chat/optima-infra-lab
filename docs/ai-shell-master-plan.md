# AI Shell 综合改进计划：稳定性 + 可观测性 + 架构迁移

> **日期**: 2026-02-08
> **状态**: Phase 0-1 已完成并合并 main | Phase 2+3 Stage 基本通过，待 Prod 部署
> **涉及仓库**: optima-ai-shell, optima-terraform, optima-infra-lab

---

## 背景

通过对最近两周 session-gateway-prod 日志的排查，发现了 **5 类**导致用户"长时间无回复"的问题（21 次明确错误，10 个用户受影响）。同时，infra-lab 已验证的架构优化（共享 AP + 预热池）尚未落地。此外，当前的日志和监控体系不完善，无法高效定位问题或生成统计报告。

本计划将三方面工作整合为分阶段的执行路线。

## 计划总览

```
Phase 0: 紧急修复 (1天)        ✅ 已完成 — 已合并 main，Stage 已验证
Phase 1: 可观测性 (2-3天)      ✅ 已完成 — 已合并 main，Stage 日志/日报/查询模板均已验证
Phase 2+3: 共享 AP + 预热池      ✅ Stage 基本通过 — 预热 47ms, 首字 4s, resume 正常
```

```
Prod 部署待定: Phase 2+3 待验证项全部通过后合并 main 部署
```

---

## Phase 0: 紧急修复 (1天) ✅ 已完成

> **分支**: `feature/phase0-stability-fixes` → 已合并 `main` (2026-02-08)
> **提交**: `42f5e0d`, `cc4db1f`, `8d62d55`

### 0.1 IAM 权限修复 ✅

**问题**: session-gateway 调用 `ecs:DescribeTasks` 时返回 `AccessDeniedException`，导致 task 状态检查失败、重启逻辑无法正确执行。排查报告中记录了 **10 次**此类错误。

**文件**: `infrastructure/optima-terraform/stacks/ai-shell-ecs/main.tf` 中的 IAM policy（`ai-shell-ecs` module 的 `session_gateway_task_role_policy`）

**改动**: 给 session-gateway 的 ECS Task Role 添加 `ecs:DescribeTasks` 权限

```hcl
# 在现有 ECS policy 的 Action 列表中添加：
"ecs:DescribeTasks"
```

**影响**: 修复 10 次 `AccessDeniedException` 导致的 task 重启失败

**落地状态**: ✅ 代码已在 `modules/ai-shell-ecs/main.tf` 中（stage + prod 共用模块）。IAM 权限已 apply 生效。

---

### 0.2 Session Resume 竞态条件修复 ✅

**问题**: 用户断线重连时，存在两个竞态场景导致 "No ECS bridge found" 错误（共 **11 次**）：

1. **Task 连接过早**: ECS 容器内的 `ws-bridge.js` 连接 `/internal/task/{sessionId}` 时，对应的 EcsBridge 实例尚未注册到 `containerManager`
2. **旧 Session 正在停止**: 用户重连触发新 session 创建，但旧 session 的 ECS task 尚未完全停止，造成资源冲突

**改动 1** — `packages/session-gateway/src/index.ts` (handleTaskConnection 重试):

```typescript
// 当前代码（立即失败）:
const bridge = containerManager.getBridgeBySessionId(sessionId);
if (bridge && 'handleTaskConnection' in bridge) {
  (bridge as any).handleTaskConnection(ws);
} else {
  console.error(`[WS] No ECS bridge found for session ${sessionId}`);
  ws.close(1008, 'Session not found');
}

// 改为（等待最多 5s 重试）:
let bridge = containerManager.getBridgeBySessionId(sessionId);
if (!bridge || !('handleTaskConnection' in bridge)) {
  // Bridge 可能还未注册，等待重试
  for (let i = 0; i < 50; i++) {  // 50 * 100ms = 5s
    await sleep(100);
    bridge = containerManager.getBridgeBySessionId(sessionId);
    if (bridge && 'handleTaskConnection' in bridge) break;
  }
}

if (bridge && 'handleTaskConnection' in bridge) {
  (bridge as any).handleTaskConnection(ws);
} else {
  console.error(`[WS] No ECS bridge found for session ${sessionId} after 5s retry`);
  ws.close(1008, 'Session not found');
}
```

**改动 2** — `packages/session-gateway/src/ws-connection-handler.ts` (session resume 等待旧 session):

在 session resume 流程中，如果旧 session 正在停止中（`status === 'stopping'`），等待其完成（最多 10s）再创建新 session。具体位置在 `handleResumeSession()` 方法中。

**影响**: 修复 11 次竞态条件导致的 "No ECS bridge found" → task 重启失败

---

### 0.3 Task 重启失败时通知客户端 ✅

**问题**: `restartTask()` 在 `start()` 阶段失败时，虽然有 catch 块发送错误消息给客户端，但某些中间错误（如 `DescribeTasks` 失败）会在 `start()` 内部被吞掉，导致客户端永远等待。

**文件**: `packages/session-gateway/src/bridges/ecs-bridge.ts`

**现状**: 第 612-622 行的 catch 块已经有错误通知逻辑 ✅，但需要确保 `start()` 内部的所有异常都能正确冒泡到这里。

**改动**:
1. 在 `start()` 方法中，确保 `DescribeTasks` 等 API 调用失败时 throw error 而非静默处理
2. 在 `restartTask()` 的 catch 块中增加更详细的错误信息（包含具体失败原因）
3. 添加超时保护：如果 `restartTask()` 整体超过 30s 未完成，向客户端发送超时错误

```typescript
// restartTask 超时保护
const RESTART_TIMEOUT_MS = 30_000;
const timeoutPromise = new Promise<never>((_, reject) =>
  setTimeout(() => reject(new Error('Task restart timeout')), RESTART_TIMEOUT_MS)
);

try {
  await Promise.race([this.doRestartTask(), timeoutPromise]);
} catch (error) {
  this.sendToClient(JSON.stringify({
    type: 'error',
    error: {
      message: `会话恢复失败: ${error.message}，请刷新页面重试`,
      code: 'TASK_RESTART_FAILED'
    }
  }));
}
```

**影响**: 即使重启失败，用户至少知道发生了什么，而非永远等待

---

### 0.4 Restart 期间 detachWebSocket 误杀竞态条件 ✅

**问题**: `restartTask()` 过程中，`start()` 调用 `attachWebSocket(this.ws)` 时，`attachWebSocket()` 先调用 `detachWebSocket()` 清理旧连接。但此时 `processingState` 已被 `doRestartTask()` 设为 `'idle'`，导致 `detachWebSocket()` 认为 task 空闲 → 调用 `stop()` → **杀死刚启动的新 task**。restart 流程继续报告 "success" 但 task 实际已死。

**发现方式**: 通过 Stage 环境用户日志排查（session `ce751bc9`），精确复现了时间线。

**修复** (`8d62d55`):

1. **`detachWebSocket()`**: 增加 `isRestarting` 守卫，restart 期间跳过 `stop()`
2. **`resetIdleTimer()`**: 增加 `isRestarting` 守卫，restart 期间不启动 idle timer
3. **`doRestartTask()`**: restore 和 flush 后验证 `taskWs` 仍然存活

**验证**: Stage 部署后确认 `Skipping stop during restart` 日志出现，restart 成功率恢复正常。

---

### Phase 0 验证 ✅

- [x] 部署后在 Stage 环境模拟空闲超时 → 重连场景，确认 task 重启成功
- [x] 检查 CloudWatch 无 `AccessDeniedException` 错误
- [x] 模拟快速断开重连，确认无 "No ECS bridge found"
- [x] 模拟 `start()` 失败场景，确认客户端收到错误消息
- [x] 验证 `isRestarting` 守卫生效（`Skipping stop during restart` 日志确认）

---

## Phase 1: 可观测性 (2-3天) ✅ 已完成

> **提交**: `a9ef9a2` (核心 7 文件), `f9bfa2f` (剩余 18 文件扫尾)
> **infra-lab 提交**: `fb3059d` (日报脚本修正), `ed036a3` (日报 + 查询模板)

**目标**: 统一日志格式 + 关键链路耗时记录 + 自动日报

### 1.1 统一结构化日志 ✅

**现状问题**:

| 文件 | 当前日志方式 | 状态 |
|------|------------|------|
| `bridges/ecs-bridge.ts` | `this.log()` JSON 结构化 | ✅ 较好 |
| `ws-connection-handler.ts` | `console.log('[Tag]', ...)` 前缀标记 | ❌ 需改造 |
| `container-bridge.ts` | `console.log(...)` | ❌ 需改造 |
| `services/session-cleanup.service.ts` | `console.log(...)` | ❌ 需改造 |
| `index.ts` | `console.log('[✓]', ...)` emoji 前缀 | ❌ 需改造 |
| `utils/logger.ts` | 定义了 Logger 类 | ⚠️ 存在但几乎没人用 |

**`@optima-chat/observability`** 提供了 `createLogger()` 方法，但当前未被 session-gateway 采用。

**改动**:

#### 1. 重写 `utils/logger.ts`

替换为基于 `@optima-chat/observability` 的结构化 logger，统一输出 JSON 格式：

```typescript
import { createLogger } from '@optima-chat/observability';

// 创建全局 logger
const baseLogger = createLogger({
  service: 'session-gateway',
  environment: process.env.NODE_ENV || 'development',
});

// 导出各模块 logger
export const logger = baseLogger;
export const wsLogger = baseLogger.child({ module: 'ws-handler' });
export const bridgeLogger = baseLogger.child({ module: 'ecs-bridge' });
export const cleanupLogger = baseLogger.child({ module: 'cleanup' });
export const containerLogger = baseLogger.child({ module: 'container-bridge' });
```

每条日志包含统一字段：

```json
{
  "timestamp": "2026-02-08T12:00:00.000Z",
  "level": "info",
  "service": "session-gateway",
  "module": "ecs-bridge",
  "event": "task_started",
  "sessionId": "xxx",
  "userId": "xxx",
  "traceId": "xxx",
  "requestId": "xxx",
  "duration_ms": 4500,
  "message": "ECS task started successfully"
}
```

#### 2. 替换各文件的 console.log

| 文件 | 改动 |
|------|------|
| `ws-connection-handler.ts` | 所有 `console.log('[Auth]', ...)` → `wsLogger.info('auth_verified', { userId })` |
| `container-bridge.ts` | 所有 `console.log(...)` → `containerLogger.info(...)` |
| `services/session-cleanup.service.ts` | `console.log(...)` → `cleanupLogger.info(...)` |
| `index.ts` | 启动日志保留 console.log（banner），其余换成结构化 |

#### 3. ecs-bridge.ts 的 `this.log()` 方法

当前 `ecs-bridge.ts` 已有自己的 `this.log()` 方法，输出格式较好。改造方式：
- 内部改为调用 `bridgeLogger`，保持外部 API 不变
- 自动注入 `sessionId`, `userId`, `taskArn` 等上下文

---

### 1.2 关键链路事件和耗时埋点 ✅

在 `ecs-bridge.ts` 中增加结构化的 **lifecycle event** 日志，方便 CloudWatch Logs Insights 查询。

#### 事件定义

| 事件 | phase | 关键字段 | 说明 |
|------|-------|---------|------|
| `task_lifecycle` | `session_create` | `duration_ms` | 从 WS 连接到 session_ready 的总耗时 |
| `task_lifecycle` | `task_start` | `duration_ms` | RunTask API 调用耗时 |
| `task_lifecycle` | `task_pending` | `duration_ms` | PENDING → RUNNING 的等待时间 |
| `task_lifecycle` | `task_connect` | `duration_ms` | RUNNING → task WS 连接的等待时间 |
| `task_lifecycle` | `task_ready` | `duration_ms` | 从 RunTask 到完全就绪的总耗时 |
| `task_lifecycle` | `task_restart` | `duration_ms`, `success` | 重启耗时和结果 |
| `task_lifecycle` | `ws_disconnect` | `processingState`, `reason` | 客户端断开时的状态 |
| `task_lifecycle` | `message_roundtrip` | `duration_ms` | 用户消息发出到首个 AI 回复的时间 |

#### 日志格式示例

```json
{
  "event": "task_lifecycle",
  "phase": "task_ready",
  "duration_ms": 4500,
  "breakdown": {
    "access_point_ms": 50,
    "register_taskdef_ms": 650,
    "run_task_ms": 200,
    "pending_to_running_ms": 2100,
    "wait_connection_ms": 1500
  },
  "sessionId": "sess_abc123",
  "userId": "user_xyz",
  "taskArn": "arn:aws:ecs:ap-southeast-1:585891120210:task/optima-stage-cluster/abc123"
}
```

#### 实现方式

在 `ecs-bridge.ts` 的 `start()` 方法各阶段记录时间戳：

```typescript
async start(options?: { skipFlush?: boolean }): Promise<void> {
  const startTime = Date.now();
  const timings: Record<string, number> = {};

  // 1. Access Point
  let t0 = Date.now();
  const accessPointId = await this.ensureAccessPoint();
  timings.access_point_ms = Date.now() - t0;

  // 2. Register TaskDef
  t0 = Date.now();
  const taskDefArn = await this.registerUserTaskDefinition(accessPointId);
  timings.register_taskdef_ms = Date.now() - t0;

  // 3. RunTask
  t0 = Date.now();
  const taskArn = await this.runTask(taskDefArn);
  timings.run_task_ms = Date.now() - t0;

  // 4. Wait RUNNING
  t0 = Date.now();
  await this.waitForTaskRunning(taskArn);
  timings.pending_to_running_ms = Date.now() - t0;

  // 5. Wait WS connection
  t0 = Date.now();
  await this.waitForTaskConnection();
  timings.wait_connection_ms = Date.now() - t0;

  // Emit lifecycle event
  this.log('info', 'task_lifecycle', {
    event: 'task_lifecycle',
    phase: 'task_ready',
    duration_ms: Date.now() - startTime,
    breakdown: timings,
  });
}
```

同样在 `handleClientMessage()` 中记录消息往返延迟：

```typescript
// 记录用户消息发送时间
const msgSentAt = Date.now();
this.pendingMessageTimestamps.set(messageId, msgSentAt);

// 收到 AI 首个回复时
const roundtrip = Date.now() - msgSentAt;
this.log('info', 'task_lifecycle', {
  event: 'task_lifecycle',
  phase: 'message_roundtrip',
  duration_ms: roundtrip,
});
```

---

### 1.3 日报脚本 (Python) ✅

**新文件**: `ai-tools/optima-infra-lab/scripts/daily_report.py`

使用 boto3 CloudWatch Logs Insights 生成每日统计报告。

#### 输出格式

```
=== AI Shell 日报 (2026-02-08) ===

会话统计:
  新建会话: 156
  Task 启动: 189 (含 33 次重启)
  Task 成功连接: 182 (96.3%)
  连接失败: 7

启动耗时:
  P50: 4.2s | P90: 7.8s | P99: 15.3s | Max: 48.5s
  >10s: 5次 | >30s: 2次

错误统计:
  AccessDeniedException: 0
  Task 连接超时: 1
  竞态条件(No bridge): 0
  Token 过期: 3

连接稳定性:
  WS 断开(processing): 12
  WS 断开(idle): 45
  Gateway 重启: 0

消息响应:
  平均首字延迟: 1.2s (AI 回复首个 token)
  用户消息总数: 892

⚠️ 异常高亮:
  - Task 连接超时比昨日增加 2 次
  - P99 启动耗时 > 15s (阈值 10s)
```

#### 实现方式

- 使用 `boto3` `logs.start_query()` + `logs.get_query_results()` 执行 Logs Insights 查询
- 预定义 5-6 个查询模板覆盖各维度
- 输出格式: Markdown（默认） / JSON（机器读取）
- 支持参数: `--date 2026-02-08`, `--range 7d`, `--env prod/stage`, `--format md/json`
- 异常检测: 与前一天对比，指标异常时高亮告警
- 可选: `--compare` 与指定日期对比

#### 依赖

- `boto3` (已安装在工作环境)
- 需要 Phase 1.1-1.2 的结构化日志先部署

---

### 1.4 CloudWatch Logs Insights 查询模板 ✅

查询模板内嵌在 Python 脚本中，同时导出为独立文件方便手动使用。

**新目录**: `ai-tools/optima-infra-lab/scripts/queries/`

| 文件 | 说明 |
|------|------|
| `task-startup-latency.query` | 启动耗时 P50/P90/P99 分布 |
| `errors-summary.query` | 错误分类统计 |
| `ws-disconnects.query` | 断开原因和状态分析 |
| `user-activity.query` | 用户活跃度和会话数 |
| `restart-analysis.query` | Task 重启成功率和耗时 |

#### 查询示例

**启动耗时分布** (`task-startup-latency.query`):

```
fields @timestamp, duration_ms, breakdown.access_point_ms, breakdown.run_task_ms, breakdown.pending_to_running_ms, breakdown.wait_connection_ms
| filter event = "task_lifecycle" and phase = "task_ready"
| stats
    count() as total,
    pct(duration_ms, 50) as p50,
    pct(duration_ms, 90) as p90,
    pct(duration_ms, 99) as p99,
    max(duration_ms) as max_ms,
    avg(duration_ms) as avg_ms
    by bin(1h)
```

**错误分类统计** (`errors-summary.query`):

```
fields @timestamp, @message
| filter level = "error"
| stats count() as error_count by event
| sort error_count desc
| limit 20
```

---

### Phase 1 验证 ✅

- [x] 部署后检查日志格式统一为 JSON — Stage 已确认所有模块输出结构化 JSON
- [x] 运行日报脚本，确认各指标正确 — `python3 scripts/daily_report.py --env stage --date 2026-02-08` 正常输出
- [x] 在 CloudWatch Logs Insights 中执行预置查询 — startup-latency, restart-analysis, message-roundtrip 均返回有效数据
- [x] Stage 实测数据: 启动 P50=5.4s, P90=8.6s; PENDING→RUNNING P50=3.7s, P90=5.1s; 消息首字延迟 4.6s

---

## ✅ 已处理: Terraform Launch Template Apply + 启动耗时基线测试

`infrastructure/optima-terraform/stacks/ai-shell-ecs/` Launch Template 已 apply（2026-02-08）：

1. **AMI 更新**: `ami-0bbc16506b71ca849` → `ami-080e5034ac2b93626`（新版 ECS-optimized AMI）
2. **user_data 镜像预拉取**: 增加 EC2 启动时后台 `docker pull` 预拉取 AI Shell 镜像

**Apply 状态**: Stage ✅ + instance refresh 完成 | Prod ✅ launch template 已更新（现有实例不受影响）

**Stage 启动耗时基线测试** (直接 RunTask + DescribeTasks 轮询):

| | 旧实例 (LT v2) | 新实例 (LT v3) |
|---|---|---|
| Run 1 | 2006ms | 3903ms |
| Run 2 | 3857ms | 2683ms |
| Run 3 | 3367ms | 1971ms |
| Run 4 | 3221ms | 2022ms |
| **平均** | **3113ms** | **2645ms** |

**结论**: 镜像预拉取对日常 PENDING→RUNNING 无显著影响（镜像已被之前 task 缓存）。2-4s 波动来自 ECS 调度 + 容器创建 + EFS 挂载，需要 Phase 3 预热池才能根本优化。

---

## Phase 2+3: 共享 AP + 固定 TaskDef + 预热池 ✅ Stage 基本通过

> **分支**: `feature/phase2-3-warm-pool` (optima-ai-shell)
> **Terraform**: `dd4d8d9` on main (optima-terraform)
> **Stage 验证日期**: 2026-02-08
> **详细实施方案**: [Claude Plan](~/.claude/plans/wild-floating-wren.md)

Phase 2 和 Phase 3 合并在一个分支中实施，因为共享 AP 是预热池的前提。

### 核心改动

#### Phase 2: 共享 AP + 固定 TaskDef

| 任务 | 文件/位置 | 说明 | 状态 |
|------|----------|------|------|
| 创建共享 EFS Access Point | `optima-terraform` `modules/ai-shell-ecs/main.tf` | rootDir=`/workspaces/{env}`，共享 AP `fsap-0b5c731caa40bb7bb` | ✅ Stage apply |
| 固定 TaskDef | `optima-terraform` `modules/ai-shell-ecs/main.tf` | volume 使用固定共享 AP，mountPath `/mnt/efs` | ✅ Stage apply |
| 简化 ecs-bridge | `session-gateway` `bridges/ecs-bridge.ts` | 删除动态 AP/TaskDef，改用 container overrides 传递用户信息 | ✅ |
| Symlink 兼容 | `docker/ws-bridge.js` | `/home/aiuser` → `/mnt/efs/{userId}` symlink，所有文件 API 无需修改 | ✅ |
| Dockerfile 权限 | `docker/Dockerfile` | `chmod 1777 /home` 允许 aiuser 创建 symlink | ✅ |

#### Phase 3: 预热池

| 任务 | 文件/位置 | 说明 | 状态 |
|------|----------|------|------|
| WarmPoolManager | `session-gateway` `services/warm-pool-manager.ts` | **新增**，管理预热 Task 池，支持 acquire/replenish/evict | ✅ |
| 预热模式 | `docker/ws-bridge.js` | `WARM_POOL_MODE=true` 时连接 `/internal/warm/{taskId}`，等待 `init_user` | ✅ |
| 内部端点 | `session-gateway` `index.ts` | `/internal/warm/{taskId}` 接收预热 Task 连接 | ✅ |
| EcsBridge 集成 | `session-gateway` `bridges/ecs-bridge.ts` | 新增 `startFromWarmTask()` + `waitForWarmReady()` | ✅ |
| 过期淘汰 | `session-gateway` `services/warm-pool-manager.ts` | ready task 超过 TTL 自动停止并补充 | ✅ |

### 提交历史 (optima-ai-shell, feature/phase2-3-warm-pool)

```
f7bfea1 debug: 启用 DEBUG_CLAUDE_AGENT_SDK 捕获 resume 崩溃原因
66921a0 fix: 允许 aiuser 在 /home 下创建 symlink (chmod 1777)
db0dac2 fix: 修复 ws-bridge symlink 创建失败 (require is not defined)
15b7c17 fix: warm pool task 传递正确的 GATEWAY_WS_URL
da5845e feat: 添加 warm pool ready task 过期淘汰机制
38d95ad fix: 修复 warm pool manager 无限启动 bug + 环境变量穿透
6189835 fix: 使用 symlink 保持 /home/aiuser 路径兼容
b65e0e4 test: 更新 ecs-bridge 测试适配 Phase 2 变更
f7a8a77 feat: Phase 2+3 共享 AP + 固定 TaskDef + 预热池
2e57bcc merge: Phase 0-1 稳定性修复 + 可观测性改造
```

### Stage 验证结果 (2026-02-08)

#### 1. 预热池 ✅
- 预热 task 成功连接 `/internal/warm/{taskId}`
- acquire 耗时: **47ms**，总重启时间: **368ms**

#### 2. 会话对话 ✅
- 新建会话正常，AI 正常回复
- 首字到达: ~4s，回复完成: ~6-10s

#### 3. Session Resume ✅ 已修复
- **问题发现**: idle 超时后重连，Claude Code `--resume` 崩溃（exit code 1）
- **根因**: symlink 中 `require('fs')` 在 ESM 失败 + `/home` 权限不足
- **额外发现**: Claude Agent SDK 默认 `stderr="ignore"`，完全隐藏崩溃原因
- **修复后**: resume 成功，AI 记住之前对话内容

#### 4. 性能对比

| 消息 | 预热池 | SESSION_RESET | 首字到达 | 回复完成 |
|------|--------|--------------|---------|---------|
| 旧代码 (symlink bug) | +41ms | ⚠️ +2968ms | +7624ms | +12363ms |
| 旧代码 (第二条) | +45ms | ⚠️ +3520ms | +8484ms | +20414ms |
| **修复后** | +47ms | ✅ 无 | +4268ms | +6848ms |
| 同进程后续消息 | N/A | ✅ 无 | +3869ms | +6624ms |

**关键改善**: SESSION_RESET 消除，首字到达 ~8s→~4s (-50%)，回复完成 ~12-20s→~6-10s

#### 5. 待验证

- [ ] 跨容器 resume（idle 超时 → 新 warm task → 验证 AI 记忆）
- [ ] 池耗尽 fallback 到冷启动
- [ ] 多用户隔离
- [ ] 长时间运行稳定性

#### 6. 待清理

- [ ] 移除或条件化 `DEBUG_CLAUDE_AGENT_SDK = '1'`
- [ ] 清理 deprecated `registerUserTaskDefinition()` 方法

### 功能开关

| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `ENABLE_WARM_POOL` | `false` | 主开关 |
| `WARM_POOL_TARGET_SIZE` | `3` | 预热池目标大小 |
| `WARM_POOL_MAX_SIZE` | `10` | 预热池最大大小 |

**回滚**: `ENABLE_WARM_POOL=false` → 所有新会话走冷启动，预热 task 自动过期停止

### Prod 部署 ⏳ 待定

- **前提**: 待验证项目全部通过
- **Terraform**: `terraform apply` prod 模块（创建 prod 共享 AP + 更新 TaskDef）
- **Infisical**: `ECS_TASK_DEFINITION` → `ai-shell-prod-user-task`（去掉 revision 号）
- **镜像 + Gateway**: 合并到 main 后从 main 分支部署
- **预热池**: 先 `ENABLE_WARM_POOL=false`，验证通过后再启用

---

## 关键文件变更清单

| 文件 | Phase | 改动类型 | 状态 |
|------|-------|---------|------|
| `infrastructure/optima-terraform/modules/ai-shell-ecs/main.tf` | 0 | 添加 `ecs:DescribeTasks` IAM 权限 | ✅ 已 apply |
| `infrastructure/optima-terraform/modules/ai-shell-ecs/main.tf` | — | Launch Template AMI + 镜像预拉取 user_data | ⚠️ 代码已提交但未 apply |
| `session-gateway/src/index.ts` | 0, 1 | handleTaskConnection 重试 + 结构化日志 | ✅ |
| `session-gateway/src/ws-connection-handler.ts` | 0, 1 | 竞态修复 + 结构化日志 | ✅ |
| `session-gateway/src/bridges/ecs-bridge.ts` | 0, 1 | 错误通知 + lifecycle 埋点 + restart 竞态修复 | ✅ |
| `session-gateway/src/utils/logger.ts` | 1 | 重写为结构化 logger | ✅ |
| `session-gateway/src/container-bridge.ts` | 1 | console.log → 结构化日志 | ✅ |
| `session-gateway/src/services/session-cleanup.service.ts` | 1 | console.log → 结构化日志 | ✅ |
| `session-gateway/src/routes/files.ts` | 1 | apiLogger → createLogger 统一 | ✅ |
| `session-gateway/src/auth.ts` | 1 | 结构化日志 | ✅ |
| `session-gateway/src/bridges/lambda-bridge.ts` | 1 | 结构化日志 | ✅ |
| `session-gateway/src/routes/*.ts` (5 文件) | 1 | 结构化日志 | ✅ |
| `session-gateway/src/services/*.ts` (6 文件) | 1 | 结构化日志 | ✅ |
| `session-gateway/src/utils/message-transformer.ts` | 1 | 结构化日志 | ✅ |
| `optima-infra-lab/scripts/daily_report.py` | 1 | **新增** 日报脚本 | ✅ |
| `optima-infra-lab/scripts/queries/*.query` (6 文件) | 1 | **新增** 查询模板 | ✅ |
| `session-gateway/src/bridges/ecs-bridge.ts` | 2+3 | 简化 start() + startFromWarmTask() + container overrides | ✅ |
| `session-gateway/src/services/warm-pool-manager.ts` | 3 | **新增** 预热池管理 | ✅ |
| `session-gateway/src/index.ts` | 3 | 新增 `/internal/warm/{taskId}` 端点 | ✅ |
| `session-gateway/src/ws-connection-handler.ts` | 2+3 | 集成 warm pool acquire | ✅ |
| `docker/ws-bridge.js` | 2+3 | 预热模式 + symlink 兼容 + DEBUG_CLAUDE_AGENT_SDK | ✅ |
| `docker/entrypoint.sh` | 2 | 共享 AP 目录初始化 | ✅ |
| `docker/Dockerfile` | 2 | chmod 1777 /home | ✅ |
| `infrastructure/optima-terraform/modules/ai-shell-ecs/main.tf` | 2+3 | 共享 AP + 固定 TaskDef + WARM_POOL_MODE env | ✅ Stage apply |

---

## 预期成果

### 启动时间对比

```
当前状态:
  首次用户:  ████████████████████████████████████████████████ 12s
  已有 AP:   ████████████████████ 3-5s

Phase 0 后 (修复竞态 + 错误通知):
  所有用户:  ████████████████████ 3-5s (不变，但重连成功率大幅提升)

Phase 1 后 (可观测性):
  所有用户:  ████████████████████ 3-5s (不变，但能精确度量每个阶段)

Phase 2+3 后 (共享 AP + 固定 TaskDef + 预热池) — Stage 实测:
  有预热:    █ 47ms acquire + 368ms 总重启 🚀
  池空:      ██████████████ ~3s (fallback 冷启动)
  首字到达:  从 ~8s 降到 ~4s (-50%)
  回复完成:  从 ~12-20s 降到 ~6-10s
```

### 稳定性提升

| 指标 | 当前 | Phase 0 后 |
|------|------|-----------|
| 重连成功率 | ~50%（估算） | >95% |
| 用户感知到的"无回复" | 21 次/2周 | <2 次/2周 |
| 错误静默率 | 高 | 接近 0 |

### 可观测性提升

| 维度 | 当前 | Phase 1 后 |
|------|------|-----------|
| 日志格式 | 混合（文本+JSON） | 统一 JSON |
| 启动耗时度量 | 无 | P50/P90/P99 |
| 错误分类统计 | 手动 grep | 自动日报 |
| 问题定位时间 | 1-2 小时 | 5-10 分钟 |

---

## 相关文档

| 文档 | 说明 |
|------|------|
| [ai-shell-migration-plan.md](./ai-shell-migration-plan.md) | Phase 2-3 详细架构迁移计划 |
| [task-prewarming-results.md](./task-prewarming-results.md) | 预热池实测数据 |
| [startup-optimization.md](./startup-optimization.md) | 启动优化总方案 |
| [capacity-simulation.md](./capacity-simulation.md) | 容量策略模拟 |
| [ec2-warm-pool-results.md](./ec2-warm-pool-results.md) | EC2 Warm Pool 测试 |
