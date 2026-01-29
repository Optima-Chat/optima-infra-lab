# AI Shell 启动时间优化方案

> **状态**: 方案设计中
> **更新日期**: 2026-01-28
> **相关项目**: ai-tools/optima-ai-shell, ai-tools/fargate-warm-pool-test

---

## 优化效果总结

### 启动时间对比

| 场景 | 旧方案 | 新方案 | 优化幅度 |
|------|--------|--------|---------|
| **正常启动（预热池有容量）** | 12s | **1-2s** | 🚀 **85%** |
| EC2 扩容（Warm Pool） | 27s | 15s | 44% |
| EC2 冷启动 | 3min | 2min | 33% |

### 核心变化

| 方面 | 旧方案（独立 AP） | 新方案（共享 AP） |
|------|------------------|------------------|
| AP 数量 | 每用户 1 个 | **全局 1 个** |
| 用户上限 | 10,000 | **无限**（UID 42 亿） |
| Task 预热 | ❌ 不可行 | ✅ **可行** |
| 启动时间 | ~12s | **~1-2s** |
| 目录结构 | 不变 | 不变 |

---

## 一、核心方案：共享 AP + Task 预热池

### 为什么之前不能预热？

```
旧方案问题：
每用户独立 AP → AP 在 Task Definition 绑定 → Task 启动后无法切换
                                              ↓
                                        预热不可行
```

### 为什么现在可以？

```
新方案：
所有 Task 挂载同一个共享 AP
→ 用户隔离靠目录，不靠 AP
→ 预热 Task 只需切换目录即可分配给任何用户
→ 启动时间：1-2 秒
```

### 时间分解

| 阶段 | 旧方案 | 新方案 |
|------|--------|--------|
| AP 创建 | 2s | 0s（共享） |
| Task 启动 | 10s | 0s（预热） |
| 目录切换 + 初始化 | - | 1s |
| **总计** | **12s** | **1-2s** |

### 架构图

```
预热 Task 池 (5 个)
├─ Task-1 (WARM) ─┐
├─ Task-2 (WARM)  │  都挂载共享 AP
├─ Task-3 (WARM)  │  等待分配
├─ Task-4 (WARM)  │
└─ Task-5 (WARM) ─┘

用户请求:
1. 从池中取一个 Task         (0s)
2. 发送 init_user 消息        (0.1s)
3. Task 切换到用户目录        (0.5s)
4. 启动 optima headless      (0.5s)
5. 就绪                       (总计 ~1s)

后台自动补充预热池
```

---

## 二、用户隔离方案

### 目录结构（不变）

```
/workspaces/stage/           ← 共享 AP rootDirectory
├─ user-001/                 ← 用户 1 工作空间
│   ├─ .optima/
│   └─ projects/
├─ user-002/                 ← 用户 2 工作空间
└─ ...
```

### 隔离机制

**现状**：所有容器以 `aiuser` (UID=1000) 运行

**隔离方式**：应用层限制

```javascript
// 容器分配给用户后
process.env.WORKSPACE_DIR = `/mnt/efs/${userId}`;
process.chdir(process.env.WORKSPACE_DIR);

// optima headless 只在 WORKSPACE_DIR 下操作
```

**安全边界**：
- ✅ 应用层：optima 只操作 WORKSPACE_DIR
- ⚠️ 容器层：理论上可访问其他目录
- ✅ 实际风险：低（用户无法执行任意代码）

### 未来增强（可选）

动态 UID 方案：
- 每个用户分配唯一 UID（10000 + userId）
- 目录权限 700，只有 owner 可访问
- 需要在分配后通过 setuid 切换

---

## 三、EC2 冷启动优化

### 当前状态

| 场景 | 时间 | 说明 |
|------|------|------|
| EC2 Hibernated → InService | ~15s | ✅ 已优化 |
| EC2 Stopped → InService | ~20s | 对比参考 |
| EC2 冷启动 | ~180s | 需要优化 |

### 已实施的优化

- [x] **Warm Pool Hibernated** - 比 Stopped 快 5s
- [x] **EBS 深度预热** - 首次启动时读取所有文件，避免 lazy loading
- [x] **gp3 高 IOPS (3000)** - 加速 I/O
- [x] **Docker 镜像预拉取** - 避免 docker pull

### 进一步优化空间

| 优化项 | 预估效果 | 难度 | 说明 |
|--------|---------|------|------|
| **禁用 EBS 加密** | 快 5-10s | 低 | 但 Hibernation 需要加密 ❌ |
| **禁用 cloud-init** | 快 1-2s | 低 | 如果不需要动态配置 |
| **精简 User Data** | 快 1-2s | 低 | 减少启动脚本 |
| **Golden AMI** | 快 5-10s | 中 | 预装所有依赖的自定义 AMI |
| **更大实例类型** | 不确定 | 低 | t3.medium → t3.large |

### 推荐的 EC2 冷启动优化

```bash
# 1. 禁用不必要的 cloud-init 模块
# /etc/cloud/cloud.cfg.d/99-disable-slow.cfg
cloud_final_modules:
  - scripts-user  # 只保留必要的

# 2. 精简 User Data（只保留 ECS 配置）
cat >> /etc/ecs/ecs.config <<EOF
ECS_CLUSTER=${CLUSTER_NAME}
ECS_WARM_POOLS_CHECK=true
ECS_IMAGE_PULL_BEHAVIOR=prefer-cached
EOF

# 3. 移除 EBS 预热（已经在 Warm Pool 状态下预热过了）
# 只在首次启动时执行，Hibernated 恢复时跳过
```

### Golden AMI 方案（中期）

预构建包含所有依赖的 AMI，每次 Docker 镜像更新时自动构建。

#### 概念

| 比喻 | 说明 |
|------|------|
| 普通 AMI | 毛坯房，每次入住都要装修 |
| Golden AMI | 精装房，拎包入住 |

#### 自动构建流程

```
AI Shell 代码 push
    ↓
Docker 镜像构建 & 推送 ECR
    ↓
触发 Golden AMI 构建（Packer）
    ↓
更新 Launch Template 使用新 AMI
    ↓
ASG 自动使用新 AMI 启动实例
```

#### Packer 配置

```hcl
# packer/ai-shell-golden.pkr.hcl

source "amazon-ebs" "golden" {
  ami_name      = "ai-shell-golden-${formatdate("YYYYMMDD-hhmm", timestamp())}"
  instance_type = "t3.medium"
  region        = "ap-southeast-1"

  source_ami_filter {
    filters = {
      name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  ssh_username = "ec2-user"
}

build {
  sources = ["source.amazon-ebs.golden"]

  # 1. 配置 ECS
  provisioner "shell" {
    inline = [
      "sudo tee /etc/ecs/ecs.config <<EOF",
      "ECS_CLUSTER=ai-shell-cluster",
      "ECS_IMAGE_PULL_BEHAVIOR=prefer-cached",
      "ECS_WARM_POOLS_CHECK=true",
      "EOF"
    ]
  }

  # 2. 预拉取 Docker 镜像
  provisioner "shell" {
    inline = [
      "aws ecr get-login-password --region ap-southeast-1 | docker login --username AWS --password-stdin 585891120210.dkr.ecr.ap-southeast-1.amazonaws.com",
      "docker pull 585891120210.dkr.ecr.ap-southeast-1.amazonaws.com/ai-shell:latest"
    ]
  }

  # 3. 预热 EBS（读取所有文件触发从 S3 加载）
  provisioner "shell" {
    inline = [
      "sudo find /var/lib/docker -type f -exec cat {} \\; > /dev/null 2>&1 || true",
      "sudo find /usr/bin /usr/lib64 -type f -exec cat {} \\; > /dev/null 2>&1 || true"
    ]
  }
}
```

#### GitHub Actions

```yaml
# .github/workflows/build-golden-ami.yml
name: Build Golden AMI

on:
  workflow_run:
    workflows: ["Build AI Shell Image"]
    types: [completed]
  workflow_dispatch:

jobs:
  build-ami:
    runs-on: ubuntu-latest
    if: ${{ github.event.workflow_run.conclusion == 'success' }}

    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-packer@v3

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ap-southeast-1

      - name: Build Golden AMI
        run: |
          packer init packer/
          packer build packer/ai-shell-golden.pkr.hcl

      - name: Update Launch Template
        run: |
          # 获取新 AMI ID
          AMI_ID=$(aws ec2 describe-images \
            --filters "Name=name,Values=ai-shell-golden-*" \
            --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
            --output text)

          echo "New AMI: $AMI_ID"

          # 更新 Launch Template
          aws ec2 create-launch-template-version \
            --launch-template-name ai-shell-ecs \
            --source-version '$Latest' \
            --launch-template-data "{\"ImageId\":\"$AMI_ID\"}"

          # 设为默认版本
          aws ec2 modify-launch-template \
            --launch-template-name ai-shell-ecs \
            --default-version '$Latest'
```

#### 构建时间

| 步骤 | 时间 |
|------|------|
| 启动临时 EC2 | 1-2 min |
| 拉取 Docker 镜像 | 2-3 min |
| 预热 EBS | 1-2 min |
| 创建 AMI 快照 | 3-5 min |
| **总计** | **8-12 min** |

#### 效果

冷启动时间：180s → **60-90s**

---

## 四、详细实现设计

### 1. 共享 AP 配置

```hcl
# Terraform
resource "aws_efs_access_point" "shared" {
  file_system_id = aws_efs_file_system.workspaces.id

  root_directory {
    path = "/workspaces/${var.environment}"
    creation_info {
      owner_uid   = 1000  # aiuser
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  posix_user {
    uid = 1000
    gid = 1000
  }

  tags = {
    Name = "ai-shell-shared-ap-${var.environment}"
  }
}
```

### 2. Task Definition 修改

```hcl
# 所有 Task 使用同一个共享 AP
volume {
  name = "workspaces"

  efs_volume_configuration {
    file_system_id     = aws_efs_file_system.workspaces.id
    transit_encryption = "ENABLED"

    authorization_config {
      access_point_id = aws_efs_access_point.shared.id  # 共享 AP
      iam             = "ENABLED"
    }
  }
}
```

### 3. WarmPoolManager

```typescript
// session-gateway/src/services/warm-pool-manager.ts

interface WarmTask {
  taskArn: string;
  ws: WebSocket;
  state: 'warm' | 'assigned';
  assignedTo?: string;
}

class WarmPoolManager {
  private warmTasks: Map<string, WarmTask> = new Map();

  config = {
    minWarmTasks: 5,
    maxWarmTasks: 20,
    replenishThreshold: 3,
  };

  async acquireTask(userId: string): Promise<WarmTask> {
    const task = this.findAvailableTask();

    if (task) {
      task.state = 'assigned';
      task.assignedTo = userId;

      // 通知容器初始化用户环境
      task.ws.send(JSON.stringify({
        type: 'init_user',
        userId: userId,
        workspaceDir: `/mnt/efs/${userId}`,
      }));

      // 后台补充
      this.replenishPool();

      return task;
    }

    // 池空了，冷启动
    return this.startNewTask(userId);
  }
}
```

### 4. 容器内处理

```javascript
// docker/ws-bridge.js

let optimaProcess = null;

ws.on('message', (data) => {
  const msg = JSON.parse(data);

  if (msg.type === 'init_user') {
    const workspaceDir = msg.workspaceDir;

    // 确保目录存在
    if (!fs.existsSync(workspaceDir)) {
      fs.mkdirSync(workspaceDir, { recursive: true });
    }

    // 设置环境变量
    process.env.HOME = workspaceDir;
    process.env.WORKSPACE_DIR = workspaceDir;
    process.chdir(workspaceDir);

    // 启动 optima headless
    optimaProcess = spawn('optima', ['headless'], {
      cwd: workspaceDir,
      env: { ...process.env, HOME: workspaceDir },
    });

    ws.send(JSON.stringify({ type: 'ready' }));
  }
});
```

---

## 五、实施计划

### Phase 1：共享 AP + 预热池（核心）

目标：启动时间 12s → 1-2s

- [ ] 创建共享 Access Point（Terraform）
- [ ] 修改 Task Definition 使用共享 AP
- [ ] 实现 WarmPoolManager
- [ ] 修改 ws-bridge.js 支持预热模式
- [ ] 测试启动时间

### Phase 2：小优化

- [ ] entrypoint.sh 精简（移除版本输出）
- [ ] ECS 配置优化（prefer-cached, binpack）
- [ ] 精简 EC2 User Data

### Phase 3：EC2 冷启动优化（可选）

- [ ] 禁用不必要的 cloud-init
- [ ] 评估 Golden AMI 方案

---

## 六、风险和注意事项

### 兼容性

- ✅ 目录结构不变，现有用户数据无需迁移
- ✅ 容器内路径从 `/mnt/efs/` 改为 `/mnt/efs/{userId}/`
- ⚠️ 需要更新容器内的 WORKSPACE_DIR 逻辑

### 安全

- ⚠️ 共享 AP 下，容器理论上可以访问其他用户目录
- ✅ 实际风险低：optima 只操作 WORKSPACE_DIR，用户无法执行任意代码
- 📌 后续可增强：动态 UID 或 chroot

### 容量规划

- 预热池大小：建议 5-20 个 Task
- 补充阈值：低于 3 个时开始补充
- 监控指标：预热池使用率、分配延迟

---

## 七、相关文档

### 测试项目

- **[fargate-warm-pool-test](../../../fargate-warm-pool-test/)** - 独立测试项目
  - [测试计划](../../../fargate-warm-pool-test/TASK-PREWARMING-TEST-PLAN.md)
  - [EC2 Warm Pool 测试结果](../../../fargate-warm-pool-test/TEST-RESULTS.md)
  - [容量策略模拟](../../../fargate-warm-pool-test/SIMULATION-RESULTS.md)

### 本项目文档

- [前期测试结论](./baseline-results/)

### 外部参考

- [AWS ECS 任务启动优化](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-recommendations.html)
- [加速 EC2 启动（depot.dev）](https://depot.dev/blog/faster-ec2-boot-time)
- [加速 ECS 部署（Nathan Peck）](https://nathanpeck.com/speeding-up-amazon-ecs-container-deployments/)
