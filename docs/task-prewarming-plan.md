# Task 预热池测试计划

> **目标**: 验证 "共享 AP + Task 预热池" 方案能否将启动时间从 12s 降到 1-2s
> **基于**: `notes-private/projects/active/ai-shell/startup-optimization.md`

---

## 测试背景

### 已有结论（EC2 Warm Pool）

| 场景 | 时间 |
|------|------|
| EC2 Warm Pool (Stopped → InService) | ~20s |
| EC2 + ECS Task 调度 | ~22s |

**问题**: EC2 Warm Pool 优化的是实例启动，但用户等待 22s 仍然太长。

### 新方案：Task 预热池

```
核心思路：
- 预先启动一批 ECS Task（挂载共享 AP）
- 用户连接时，直接分配已启动的 Task
- Task 切换到用户目录，启动 optima
- 理论启动时间：1-2s
```

---

## 测试目标

### 关键指标

| 指标 | 目标值 | 说明 |
|------|-------|------|
| **预热 Task 分配延迟** | < 100ms | 从池中取出 Task 的时间 |
| **用户目录初始化** | < 500ms | 创建目录 + 设置权限 |
| **optima headless 启动** | < 1s | 启动 optima 进程到就绪 |
| **端到端启动时间** | < 2s | 用户请求到可交互 |

### 对比基准

| 场景 | 当前时间 | 目标时间 |
|------|---------|---------|
| 有预热 Task | 12s | **1-2s** |
| 无预热（冷启动） | 22s+ | 22s（无变化） |

---

## 测试架构

```
┌─────────────────────────────────────────────────────────────────┐
│                       测试架构                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────┐         ┌──────────────────────────────────┐  │
│  │ Test Client │ ──────> │ Mock Session Gateway             │  │
│  │ (scripts/)  │         │ (gateway/)                       │  │
│  └─────────────┘         │ - WarmPoolManager                │  │
│                          │ - WebSocket Server (:5174)       │  │
│                          │ - REST API (/api/acquire)        │  │
│                          └──────────────┬───────────────────┘  │
│                                         │                       │
│                    ┌────────────────────┼────────────────────┐  │
│                    │                    ▼                    │  │
│                    │  ┌──────────┐ ┌──────────┐ ┌──────────┐ │  │
│                    │  │ Task 1   │ │ Task 2   │ │ Task 3   │ │  │
│                    │  │ (WARM)   │ │ (WARM)   │ │ (WARM)   │ │  │
│                    │  └────┬─────┘ └────┬─────┘ └────┬─────┘ │  │
│                    │       │            │            │       │  │
│                    │  预热 Task 池 (ECS EC2)                  │  │
│                    └───────┴────────────┴────────────┴───────┘  │
│                                         │                       │
│                                         ▼                       │
│                    ┌─────────────────────────────────────────┐  │
│                    │  共享 EFS Access Point                   │  │
│                    │  /workspaces/                            │  │
│                    │  ├─ user-001/                            │  │
│                    │  ├─ user-002/                            │  │
│                    │  └─ ...                                  │  │
│                    └─────────────────────────────────────────┘  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 测试阶段

### Phase 1: 基础验证（使用测试镜像）

验证预热池机制本身的可行性。

#### 测试 1.1: 共享 AP 挂载验证

**目标**: 确认多个 Task 可以同时挂载共享 AP

```bash
# 启动 3 个 Task
aws ecs update-service --cluster fargate-warm-pool-test \
  --service fargate-warm-pool-test-ec2-service \
  --desired-count 3

# 进入每个容器，验证 EFS 挂载
aws ecs execute-command --cluster fargate-warm-pool-test \
  --task <task-arn> --container test \
  --interactive --command "/bin/sh"

# 在容器内执行
ls -la /mnt/efs/
mkdir -p /mnt/efs/test-user-001
echo "hello" > /mnt/efs/test-user-001/test.txt
cat /mnt/efs/test-user-001/test.txt
```

**预期结果**:
- [ ] 所有 Task 都能访问 `/mnt/efs/`
- [ ] 可以创建用户目录
- [ ] 文件在多个 Task 间可见

#### 测试 1.2: Task 分配延迟测试

**目标**: 测量从"池中取 Task"到"Task 确认分配"的时间

```bash
# 运行分配测试脚本
cd scripts/
python3 test-task-allocation.py --count 10

# 输出示例：
# Run 1: allocation_time=45ms
# Run 2: allocation_time=52ms
# ...
# Average: 48ms, P95: 62ms, P99: 78ms
```

**预期结果**:
- [ ] 平均分配时间 < 100ms
- [ ] P99 < 200ms

#### 测试 1.3: 目录初始化时间

**目标**: 测量创建用户目录的时间

```bash
# 在容器内运行
time mkdir -p /mnt/efs/test-user-$(date +%s)

# 或运行脚本
python3 test-directory-init.py --count 20
```

**预期结果**:
- [ ] 首次创建目录 < 500ms
- [ ] 已存在目录切换 < 100ms

---

### Phase 2: AI Shell 镜像测试

使用真实的 AI Shell 镜像验证完整流程。

#### 测试 2.1: 切换到 AI Shell 镜像

**修改 terraform 配置**:

```hcl
# terraform/variables.tf 添加
variable "use_ai_shell_image" {
  type    = bool
  default = false
}

variable "ai_shell_image" {
  type    = string
  default = "585891120210.dkr.ecr.ap-southeast-1.amazonaws.com/optima-ai-shell:latest"
}

# terraform/ec2-warm-pool.tf 修改
container_definitions = jsonencode([
  {
    name  = "ai-shell"
    image = var.use_ai_shell_image ? var.ai_shell_image : "${aws_ecr_repository.test.repository_url}:latest"
    # ...
  }
])
```

**部署**:

```bash
terraform apply -var="use_ai_shell_image=true"
```

#### 测试 2.2: optima headless 启动时间

**目标**: 测量 optima headless 从启动到就绪的时间

```bash
# 进入预热的 Task
aws ecs execute-command --cluster fargate-warm-pool-test \
  --task <task-arn> --container ai-shell \
  --interactive --command "/bin/bash"

# 在容器内执行
export HOME=/mnt/efs/test-user-001
export WORKSPACE_DIR=$HOME
cd $HOME

# 测量启动时间
time timeout 10 optima headless --version
```

**预期结果**:
- [ ] optima 可执行文件存在
- [ ] 启动时间 < 1s

#### 测试 2.3: 端到端流程测试

**目标**: 模拟完整的用户连接流程

```
1. 用户发起连接请求
2. Gateway 从池中分配 Task
3. Gateway 发送 init_user 消息
4. Task 切换到用户目录
5. Task 启动 optima headless
6. Task 返回 ready
7. 用户可以交互
```

**测试脚本**:

```bash
# scripts/test-e2e-flow.py
python3 test-e2e-flow.py \
  --gateway-url ws://localhost:5174 \
  --user-id test-user-001 \
  --count 5
```

**预期结果**:
- [ ] 端到端时间 < 2s
- [ ] 所有步骤无错误

---

### Phase 3: 负载测试

#### 测试 3.1: 并发分配测试

**目标**: 测试多用户同时请求时的表现

```bash
# 预热 5 个 Task
aws ecs update-service --cluster fargate-warm-pool-test \
  --service fargate-warm-pool-test-ec2-service \
  --desired-count 5

# 同时发起 5 个请求
python3 test-concurrent-allocation.py --concurrency 5

# 再发起 3 个请求（超过预热池容量）
python3 test-concurrent-allocation.py --concurrency 3
```

**预期结果**:
- [ ] 5 个请求都在 2s 内完成
- [ ] 超出容量的请求需要冷启动（22s+）

#### 测试 3.2: 预热池补充速度

**目标**: 测量分配后补充新 Task 的时间

```bash
# 分配所有预热 Task
python3 test-pool-exhaustion.py

# 等待补充
watch "aws ecs list-tasks --cluster fargate-warm-pool-test --service-name fargate-warm-pool-test-ec2-service | jq '.taskArns | length'"

# 记录补充时间
```

**预期结果**:
- [ ] 新 Task 启动时间 ~22s（使用 EC2 Warm Pool）
- [ ] ECS Service 自动补充

---

## 测试脚本清单

### 需要创建的脚本

| 脚本 | 用途 |
|------|------|
| `scripts/test-task-allocation.py` | 测试 Task 分配延迟 |
| `scripts/test-directory-init.py` | 测试目录初始化时间 |
| `scripts/test-e2e-flow.py` | 端到端流程测试 |
| `scripts/test-concurrent-allocation.py` | 并发分配测试 |
| `scripts/test-pool-exhaustion.py` | 预热池耗尽测试 |

### 已有的脚本

| 脚本 | 用途 |
|------|------|
| `scripts/test-warm-start.sh` | EC2 Warm Pool 启动测试 |

---

## Terraform 修改清单

### 支持 AI Shell 镜像

```hcl
# variables.tf
variable "use_ai_shell_image" {
  description = "Use AI Shell image instead of test image"
  type        = bool
  default     = false
}

variable "ai_shell_image" {
  description = "AI Shell ECR image URI"
  type        = string
  default     = "585891120210.dkr.ecr.ap-southeast-1.amazonaws.com/optima-ai-shell:latest"
}
```

### Task Definition 修改

```hcl
# 添加预热模式环境变量
environment = [
  { name = "WARM_POOL_MODE", value = "true" },
  { name = "GATEWAY_WS_URL", value = "ws://gateway:5174" },
]
```

---

## Mock Gateway 设计

简化版 Session Gateway，用于测试预热池机制。

### API 设计

```
POST /api/acquire
  Request: { "userId": "user-001" }
  Response: { "taskArn": "...", "latency": 45 }

GET /api/status
  Response: { "warmCount": 3, "assignedCount": 2, "tasks": [...] }

WebSocket /internal/warm/{taskId}
  Task 连接端点，用于预热 Task 注册
```

### 核心逻辑

```typescript
// gateway/src/warm-pool.ts
class WarmPoolManager {
  private warmTasks: Map<string, WarmTask> = new Map();

  registerWarmTask(taskId: string, ws: WebSocket): void {
    this.warmTasks.set(taskId, { taskId, ws, state: 'warm' });
  }

  async acquireWarmTask(userId: string): Promise<WarmTask | null> {
    for (const [id, task] of this.warmTasks) {
      if (task.state === 'warm') {
        task.state = 'assigned';
        task.userId = userId;
        task.ws.send(JSON.stringify({
          type: 'init_user',
          userId,
          workspaceDir: `/mnt/efs/${userId}`
        }));
        return task;
      }
    }
    return null;
  }
}
```

---

## 执行计划

### Day 1: 基础设施准备

- [ ] 确认现有 Terraform 资源正常
- [ ] 创建 `variables.tf` 添加 AI Shell 镜像配置
- [ ] 验证共享 AP 挂载

### Day 2: 测试脚本开发

- [ ] 创建 `test-task-allocation.py`
- [ ] 创建 `test-directory-init.py`
- [ ] 测试 Phase 1 (基础验证)

### Day 3: AI Shell 集成

- [ ] 切换到 AI Shell 镜像
- [ ] 创建 `test-e2e-flow.py`
- [ ] 测试 Phase 2 (AI Shell 镜像)

### Day 4: 负载测试和总结

- [ ] 创建并发测试脚本
- [ ] 测试 Phase 3 (负载测试)
- [ ] 整理测试报告

---

## 预期结论

### 成功标准

| 指标 | 目标 | 说明 |
|------|------|------|
| 预热启动时间 | < 2s | 有预热 Task 时 |
| 冷启动时间 | < 25s | 无预热时，使用 EC2 Warm Pool |
| 预热池维护 | 自动 | ECS Service 自动补充 |

### 风险和应对

| 风险 | 可能性 | 应对 |
|------|--------|------|
| optima 启动慢 | 中 | 优化 optima 启动流程 |
| EFS 延迟高 | 低 | 使用 General Purpose 模式 |
| Task 分配延迟高 | 低 | 优化 Gateway 逻辑 |

---

## 相关文档

- [启动优化方案](../../private/notes-private/projects/active/ai-shell/startup-optimization.md)
- [EC2 Warm Pool 测试结果](./TEST-RESULTS.md)
- [容量策略模拟](./SIMULATION-RESULTS.md)
