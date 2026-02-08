# AI Shell 架构迁移计划：Infra-Lab 研究成果落地

> **日期**: 2026-02-08
> **状态**: 计划中
> **涉及仓库**: optima-ai-shell, optima-terraform, optima-infra-lab

---

## 一、架构对比总览

### 当前 AI Shell 架构 vs Infra-Lab 验证架构

| 维度 | 当前 AI Shell | Infra-Lab 验证方案 | 差异等级 |
|------|-------------|-------------------|---------|
| **EFS Access Point** | 每用户独立 AP | 全局共享 1 个 AP | 🔴 架构级 — **未落地** |
| **Task Definition** | 每次动态注册（含用户 AP） | 1 个固定 TaskDef（复用） | 🔴 架构级 — **未落地** |
| **Task 启动模式** | 按需 RunTask | 预热池（预启动 + 按需分配） | 🔴 架构级 — **未落地** |
| **用户隔离** | AP 级（内核强制） | 目录级（应用层限制） | 🟡 安全模型 — **未落地** |
| **容器通信** | 容器启动后主动连接 Gateway | 预热 Task 预先连接，等待分配 | 🟡 通信模型 — **未落地** |
| **EC2 镜像管理** | ~~无预拉取~~ | user_data 中预拉取 | ✅ 已落地（ai-shell-ecs 模块） |
| **EC2 扩容** | ~~ASG 默认冷启动~~ | Warm Pool (Stopped) | ✅ 已落地（Stage 1台 / Prod 5台） |
| **容量策略** | ~~无~~ | Prod desired=2 + warm=5 | ✅ 已落地（terraform.tfvars） |

---

## 二、逐项详细对比

### 2.1 EFS Access Point 模型 🔴

**当前 AI Shell** (`access-point-manager.ts`):

```
用户 A → 创建 AP-A (rootDir=/workspaces/stage/userA) → 容器只能看到 /workspaces/stage/userA
用户 B → 创建 AP-B (rootDir=/workspaces/stage/userB) → 容器只能看到 /workspaces/stage/userB
```

- 每个用户 1 个 AP，通过 `ensureAccessPoint(userId)` 创建
- AP 的 RootDirectory 限制了容器的文件系统视野
- EFS 限制：每文件系统最多 1000 个 AP

**Infra-Lab 方案** (`efs.tf`):

```
共享 AP (rootDir=/workspaces) → 所有容器都能看到 /workspaces/下所有用户目录
用户隔离 → 靠 WORKSPACE_DIR 环境变量 + optima 应用层限制
```

- 全局 1 个 AP，所有 Task 共用
- 无 AP 数量瓶颈
- 启用预热池的前提条件

**迁移影响**:
- 需要废弃 `AccessPointManager` 类的动态创建/查找逻辑
- 改为启动时读取一个固定的共享 AP ID（环境变量）
- 现有用户目录数据不需要迁移（目录结构 `/workspaces/stage/{userId}` 不变）

---

### 2.2 Task Definition 注册模型 🔴

**当前 AI Shell** (`ecs-bridge.ts:registerUserTaskDefinition()`):

```
每次会话启动:
1. describeTaskDefinition(基础模板)           → ~150ms
2. 修改 volume 配置，注入用户 AP
3. 修改 container env，注入 userId/sessionId
4. registerTaskDefinition(新 revision)        → ~500ms
5. runTask(新 taskDef)

问题: 每次注册新 revision，TaskDef 版本号持续膨胀
```

**Infra-Lab 方案**:

```
启动时（一次性）:
1. 使用固定 TaskDef（共享 AP 已内嵌）
2. runTask 时通过 overrides 注入 env

每次会话启动:
1. 从预热池取 Task（内存操作）              → ~1ms
2. 发送 init_user 消息                      → ~5ms
```

**迁移影响**:
- 删除 `registerUserTaskDefinition()` 方法
- TaskDef 改为 Terraform 管理，不再动态注册
- 环境变量（userId, sessionId 等）改为运行时通过 WebSocket 消息下发
- 减少 ECS API 调用，避免 TaskDef 版本膨胀

---

### 2.3 Task 启动模型 🔴

**当前 AI Shell** (`ecs-bridge.ts:start()`):

```
用户请求
  → ensureAccessPoint(userId)               ~50-2000ms（缓存/首次）
  → registerUserTaskDefinition(apId)        ~650ms
  → runTask(userTaskDef)                    ~200ms
  → waitForTaskReady(轮询 RUNNING)          ~1000-3000ms
  → 等待 ws-bridge.js 连接                  ~200-500ms
  → flushMessageQueue()
  → 就绪                                    总计 ~3-12s
```

**Infra-Lab 方案**:

```
预热阶段（后台持续运行）:
  → runTask(固定 TaskDef)
  → Task 启动，ws-bridge 连接 Gateway
  → 注册到 WarmPoolManager.warmTasks Map
  → 等待分配...

用户请求:
  → warmPoolManager.acquireTask(userId)      ~1ms（内存查找）
  → 发送 init_user { userId, workspaceDir }  ~5ms
  → 容器: mkdir + 写 token.json              ~40ms
  → 容器: 启动 optima headless               ~240ms
  → 就绪                                     总计 ~260ms

  池空时 fallback:
  → runTask（冷启动）                         ~3-12s（同当前方案）
```

**迁移影响**:
- 新增 `WarmPoolManager` 服务（核心新组件）
- `EcsBridge.start()` 改为先尝试从预热池获取，失败再冷启动
- ws-bridge.js 需要支持预热模式（先连接 Gateway，等待 init_user 后再启动 optima）
- 需要后台任务持续补充预热池

---

### 2.4 用户隔离模型 🟡

**当前 AI Shell**:

```
安全层级:
1. EFS AP 级隔离（内核强制）—— 容器 chroot 到 /workspaces/stage/{userId}
2. 应用层隔离 —— optima 只操作 WORKSPACE_DIR

效果: 即使容器被突破，也无法访问其他用户文件
```

**Infra-Lab 方案**:

```
安全层级:
1. 应用层隔离 —— optima 只操作 WORKSPACE_DIR
2. 文件权限 —— 目录 0755（同 UID，实际无隔离）

效果: 容器内理论上可以 ls /workspaces/stage/ 看到所有用户目录
```

**风险评估**:

| 威胁 | 概率 | 影响 | 缓解措施 |
|------|------|------|---------|
| 用户通过 optima 访问他人目录 | 低 | 中 | optima 工具限制在 WORKSPACE_DIR |
| 用户通过 shell 工具执行 ls/cat | 中 | 中 | shell 工具的 cwd 限制 + 路径校验 |
| 容器逃逸 | 极低 | 高 | ECS 容器隔离 + VPC 网络隔离 |

**缓解方案（可分阶段实施）**:

1. **Phase 1（立即）**: 应用层限制 —— optima 的所有文件操作工具校验路径前缀
2. **Phase 2（后续）**: 目录权限 700 + 动态 UID —— 每用户分配唯一 UID（10000+userId hash）
3. **Phase 3（可选）**: 容器内 chroot —— 入口脚本 chroot 到用户目录

**结论**: 当前阶段可接受。用户通过 optima 交互，不能直接执行任意命令。shell 工具已有 cwd 和超时限制。

---

### 2.5 容器通信模型 🟡

**当前 AI Shell**:

```
Session Gateway 启动 Task
  → 容器 entrypoint.sh 启动 ws-bridge.js
  → ws-bridge.js 立即连接 Gateway /internal/task/{sessionId}
  → 同时启动 optima headless
  → 通信链路: Client WS ↔ Gateway ↔ Task WS ↔ optima stdin/stdout
```

**Infra-Lab 方案**:

```
预热 Task 启动（无用户上下文）
  → 容器 entrypoint.sh 启动 ws-bridge.js（预热模式）
  → ws-bridge.js 连接 Gateway /internal/warm/{taskId}
  → 等待 init_user 消息...

分配时:
  → Gateway 发送 init_user { userId, workspaceDir, token }
  → ws-bridge.js 初始化用户目录
  → 启动 optima headless（传入 workspaceDir）
  → 发送 ready 确认
  → Gateway 将 Client WS 桥接到此 Task WS
```

**迁移影响**:
- ws-bridge.js 新增预热模式（不立即启动 optima，等待 init_user）
- Gateway 新增 `/internal/warm/{taskId}` WebSocket 端点
- Token 下发改为通过 init_user 消息（而非环境变量或 EFS 预写入）

---

### 2.6 EC2 镜像预拉取 ✅ 已落地

已在 `modules/ai-shell-ecs/main.tf` 的 user_data 中实现 ECR 登录 + `docker pull`。

---

### 2.7 EC2 Warm Pool ✅ 已落地

已在 `stacks/ai-shell-ecs/terraform.tfvars` 中配置：
- Stage: `warm_pool_enabled=true`, `min_size=1`, `max_capacity=2`
- Prod: `warm_pool_enabled=true`, `min_size=5`, `max_capacity=5`

> 注：当前用 Stopped 状态，infra-lab 测试的是 Hibernated（快 10-15s），可后续评估切换。

---

### 2.8 容量策略 ✅ 已落地

Prod: desired=2, max=15, warm=5 (t3.large)。已有明确的容量配置。

---

## 三、实施计划

### ~~Phase 0: 镜像预拉取~~ ✅ 已落地

已在 `infrastructure/optima-terraform/modules/ai-shell-ecs/main.tf` 中实现。
user_data 包含 ECR 登录 + `docker pull` 脚本。

---

### Phase 1: 共享 AP + 固定 TaskDef（3-5天）

**目标**: 从「每用户独立 AP + 动态 TaskDef」迁移到「共享 AP + 固定 TaskDef」

#### 1.1 Terraform 改动 (optima-terraform)

| 任务 | 说明 |
|------|------|
| 创建共享 AP | rootDir=`/workspaces/stage`，UID/GID=1000 |
| 修改 TaskDef | volume 使用共享 AP，移除动态注册需求 |
| 输出共享 AP ID | 供 Session Gateway 读取 |

#### 1.2 Session Gateway 改动 (optima-ai-shell)

| 任务 | 文件 | 说明 |
|------|------|------|
| 简化 AP 逻辑 | `access-point-manager.ts` | 不再动态创建 AP，改为读取环境变量 `SHARED_ACCESS_POINT_ID` |
| 删除动态 TaskDef 注册 | `ecs-bridge.ts` | 删除 `registerUserTaskDefinition()`，改用固定 TaskDef |
| RunTask 使用 overrides | `ecs-bridge.ts` | userId/sessionId 通过 `containerOverrides.environment` 注入 |
| Token 写入路径调整 | `ecs-bridge.ts` | EFS 挂载点变化：从 AP root `/` 变为共享 AP 下 `/{userId}/` |

#### 1.3 容器改动 (optima-ai-shell)

| 任务 | 文件 | 说明 |
|------|------|------|
| ws-bridge 读取 userId | `ws-bridge.js` | 从环境变量读取 userId，chdir 到 `/mnt/efs/{userId}` |
| 目录初始化 | `ws-bridge.js` | 启动时确保 `/mnt/efs/{userId}` 和 `.optima/` 目录存在 |

**验证**:
- 新会话能正常启动（使用共享 AP）
- 用户文件持久化正常（重启会话后文件还在）
- 不同用户的文件互不干扰
- 启动时间应比当前快（省去 AP 创建 + TaskDef 注册）

**风险**: 中。核心启动流程改动，需要在 Stage 充分测试。

**回滚方案**: 环境变量开关 `USE_SHARED_AP=true/false`，false 时走原有逻辑。

---

### Phase 2: Task 预热池（5-7天）

**目标**: 实现预热 Task 池，启动时间从 3-5s 降到 ~260ms

#### 2.1 新增 WarmPoolManager (optima-ai-shell)

```
packages/session-gateway/src/services/warm-pool-manager.ts
```

**核心逻辑**:

```typescript
interface WarmTask {
  taskArn: string;
  taskWs: WebSocket;           // 预热 Task 的 WebSocket 连接
  state: 'warming' | 'ready' | 'assigned';
  connectedAt: Date;
}

class WarmPoolManager {
  private pool: Map<string, WarmTask>;  // taskArn → WarmTask

  config = {
    minSize: 3,                // 最小预热数
    maxSize: 10,               // 最大预热数
    replenishThreshold: 2,     // 低于此数量开始补充
  };

  // 获取一个预热 Task（分配给用户）
  async acquire(userId: string, sessionId: string): Promise<WarmTask | null>;

  // 后台补充预热池
  private async replenish(): Promise<void>;

  // 接收预热 Task 的 WebSocket 连接
  handleWarmConnection(taskArn: string, ws: WebSocket): void;
}
```

#### 2.2 ws-bridge.js 预热模式 (optima-ai-shell)

```
容器启动行为变化:

当前:
  entrypoint.sh → ws-bridge.js 连接 Gateway → 同时启动 optima headless

预热模式:
  entrypoint.sh → ws-bridge.js 连接 Gateway /internal/warm/{taskId}
               → 等待 init_user 消息
               → 收到后: mkdir 用户目录 + 写 token + 启动 optima headless
               → 发送 ready 确认
```

#### 2.3 Gateway 路由改动 (optima-ai-shell)

| 任务 | 说明 |
|------|------|
| 新增 `/internal/warm/:taskId` 端点 | 接收预热 Task 的 WebSocket 连接 |
| 修改会话创建流程 | 先尝试 `warmPoolManager.acquire()`，失败再 `ecsBridge.start()` 冷启动 |
| 后台补充任务 | 定时检查预热池，低于阈值时启动新 Task |

#### 2.4 EcsBridge 改动 (optima-ai-shell)

| 任务 | 说明 |
|------|------|
| 新增 `startFromWarm(warmTask)` | 接收预热 Task，发送 init_user，等待 ready |
| `start()` 保留为冷启动路径 | 预热池耗尽时的 fallback |
| Token 下发 | 通过 init_user 消息发送，而非 EFS 预写入 |

**验证**:
- 预热池启动后，新会话在 <1s 内就绪
- 预热池耗尽时，自动 fallback 到冷启动
- 预热池自动补充（消耗一个后补充一个）
- 空闲超时、断线重连等现有机制正常工作

**风险**: 高。核心启动流程大改，需要处理很多边界情况:
- 预热 Task 在等待期间挂掉
- 分配过程中 Task WebSocket 断开
- 并发分配竞争
- 预热池补充失败

---

### ~~Phase 3: EC2 Warm Pool + 容量策略~~ ✅ 已落地

已在 `infrastructure/optima-terraform/stacks/ai-shell-ecs/terraform.tfvars` 中配置：
- Stage: desired=1, warm_pool=1, max_capacity=2
- Prod: desired=2, warm_pool=5, max_capacity=5 (t3.large)

> **注意**: 当前 Warm Pool 状态是 `Stopped`（非 Hibernated）。
> infra-lab 测试表明 Hibernated 比 Stopped 快约 10-15s，可后续评估切换。

---

### Phase 4: 可选优化

| 优化项 | 预估效果 | 依赖 | 优先级 |
|--------|---------|------|-------|
| Golden AMI (Packer) | 冷启动 80s → 55s | Phase 0 | 低 |
| 精简 cloud-init | 冷启动 -5~10s | 无 | 低 |
| 动态 UID 隔离 | 安全增强 | Phase 1 | 中（按需） |
| optima 预加载 | 250ms → 50ms | Phase 2 | 低 |
| 前端等待提示 | UX 优化 | Phase 2 | 中 |

---

## 四、预期成果

### 启动时间对比

```
当前状态 (独立 AP, 镜像预拉取 + Warm Pool 已落地):
  首次用户:  ████████████████████████████████████████████████ 12s
  已有 AP:   ████████████████████ 3-5s
  EC2 扩容:  ████████████████████████████████████ ~35s (Warm Pool Stopped)

Phase 1 后 (共享 AP + 固定 TaskDef):
  所有用户:  ██████████████ 3s (-1~2s, 省去 AP 创建 + TaskDef 注册)
  EC2 扩容:  ████████████████████████████████████ ~35s (不变)

Phase 2 后 (预热池):
  有预热:    █ 260ms 🚀                                    (-98%)
  池空:      ██████████████ 3s (fallback, 同 Phase 1)
  EC2 扩容:  ████████████████████████████████████ ~35s (不变)
```

### 成本影响

| 项目 | 当前 | 改造后 | 变化 |
|------|------|-------|------|
| ECS Task（预热池 3 个） | $0 | ~$15/月 | +$15 |
| EC2 Warm Pool（2 台 Hibernated） | $0 | ~$5/月 | +$5 |
| EFS AP 数量 | N 个 | 1 个 | 简化 |
| TaskDef 版本 | 持续膨胀 | 固定 | 简化 |
| **总增量** | | | **~$20/月** |

### 运维简化

| 方面 | 当前 | 改造后 |
|------|------|-------|
| AP 管理 | 需要定期清理废弃 AP | 无需管理 |
| TaskDef 管理 | 版本号持续增长 | Terraform 统一管理 |
| 启动排查 | 多环节（AP→TaskDef→RunTask→连接） | 简化为预热池分配 |
| 容量规划 | 无 | 明确的预热池 + Warm Pool 策略 |

---

## 五、关键决策点

### 需要确认的事项

1. **安全隔离降级是否可接受？**
   - 从 AP 级（内核）降为目录级（应用）
   - 当前阶段: 用户通过 optima 交互，不能直接 ssh 到容器
   - 建议: Phase 1 先上，后续按需加动态 UID

2. **预热池大小？**
   - 建议起步 3 个，根据实际流量调整
   - 监控指标: 预热池命中率、冷启动 fallback 频率

3. **回滚策略？**
   - Phase 1: 环境变量开关 `USE_SHARED_AP`
   - Phase 2: 环境变量开关 `ENABLE_WARM_POOL`
   - 每个 Phase 独立部署，可单独回滚

4. **部署顺序？**
   - ~~Phase 0~~ ✅ → ~~Phase 3~~ ✅ → **Phase 1 → Phase 2**
   - 基础设施层已落地，剩余工作全在 AI Shell 代码层
   - Phase 1 是 Phase 2 的前提，必须先完成

---

## 六、相关文档

| 文档 | 说明 |
|------|------|
| [task-prewarming-results.md](./task-prewarming-results.md) | 预热池实测数据 |
| [startup-optimization.md](./startup-optimization.md) | 启动优化总方案 |
| [capacity-simulation.md](./capacity-simulation.md) | 容量策略模拟 |
| [ec2-image-prepull.md](./ec2-image-prepull.md) | 镜像预拉取方案 |
| [ec2-warm-pool-results.md](./ec2-warm-pool-results.md) | EC2 Warm Pool 测试 |
| AI Shell CLAUDE.md | 项目架构和开发指南 |
| AI Shell `ecs-bridge.ts` | 当前 ECS 启动核心代码 |
| AI Shell `access-point-manager.ts` | 当前 AP 管理代码 |
