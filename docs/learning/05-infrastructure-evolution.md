# 05 - 基础设施演进式架构

> 回滚方案应该是架构默认配备，而非事后补救

---

## 我们现在在哪

当前的基础设施管理：

```
✅ 做得好的:
  - Terraform 模块化（modules/ + stacks/）
  - 多环境隔离（prod / stage / stage-ecs）
  - 远程 state + 锁（S3 + DynamoDB）
  - 成本敏感的资源规划

⚠️ 可以更好的:
  - Terraform plan 没有 CI 自动化（PR 时不会自动 plan）
  - 没有 Infrastructure 测试
  - 回滚靠环境变量开关（事后设计）
  - 没有 drift detection（实际资源 vs Terraform state 不一致）
  - 没有 policy-as-code
```

---

## 核心理念

### GitOps：用 Git 作为基础设施的 Single Source of Truth

**传统方式**（你现在的方式）:

```
开发者本地 → terraform plan → terraform apply → 基础设施变更
```

问题：
- 谁在什么时候做了什么变更？靠 git log，但 apply 可能在本地执行
- 多人同时修改时，谁的 plan 是最新的？
- apply 失败了一半怎么办？

**GitOps 方式**:

```
开发者 → 提交 PR → CI 自动 plan (评论到 PR) → 人工 review → merge → CI 自动 apply
```

好处：
- 所有变更都有 PR 记录，可追溯
- Plan 结果在 PR 中可见，review 时能看到"这次改动会影响什么"
- Apply 只在 merge 后自动执行，避免手动操作的风险
- 多人协作时，PR 保证串行化

### Infrastructure as Code 的成熟度模型

```
Level 0: 手动操作（AWS Console 点点点）
Level 1: 脚本化（bash 脚本调用 AWS CLI）
Level 2: 声明式 IaC（Terraform）                ← 你在这里
Level 3: IaC + CI/CD（PR 触发 plan/apply）       ← 下一步
Level 4: IaC + CI/CD + 测试 + Policy             ← 目标
Level 5: 自愈（drift 自动修复）                    ← 大厂水平
```

---

## 关键实践

### 1. Terraform CI Pipeline

**最高 ROI 的改进**: 在 PR 中自动运行 `terraform plan`。

```yaml
# .github/workflows/terraform-plan.yml
name: Terraform Plan

on:
  pull_request:
    paths:
      - 'stacks/**'
      - 'modules/**'

jobs:
  plan:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3

      - name: Terraform Init
        run: terraform init
        working-directory: stacks/ai-shell-ecs

      - name: Terraform Plan
        id: plan
        run: terraform plan -no-color -out=tfplan
        working-directory: stacks/ai-shell-ecs
        continue-on-error: true

      - name: Comment PR with Plan
        uses: actions/github-script@v7
        with:
          script: |
            const plan = `${{ steps.plan.outputs.stdout }}`;
            const truncated = plan.length > 60000
              ? plan.substring(0, 60000) + '\n... (truncated)'
              : plan;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `### Terraform Plan\n\`\`\`\n${truncated}\n\`\`\``
            });
```

**效果**: 每次改 Terraform 文件的 PR，自动在评论中展示 plan 结果。Review 时一目了然。

### 2. Feature Flags 作为架构模式

**当前方式**: 环境变量开关是事后想到的。

```typescript
// Phase 2 回滚方案（事后设计）
if (process.env.USE_SHARED_AP === 'true') {
  // 新逻辑
} else {
  // 旧逻辑
}
```

**更好的方式**: Feature Flag 是系统的一等公民。

```typescript
// feature-flags.ts
interface FeatureFlags {
  useSharedAccessPoint: boolean;
  enableWarmPool: boolean;
  warmPoolMinSize: number;
  enableStructuredLogging: boolean;
}

// 从环境变量或远程配置加载
function getFeatureFlags(): FeatureFlags {
  return {
    useSharedAccessPoint: env('FF_SHARED_AP', false),
    enableWarmPool: env('FF_WARM_POOL', false),
    warmPoolMinSize: env('FF_WARM_POOL_MIN_SIZE', 3),
    enableStructuredLogging: env('FF_STRUCTURED_LOGGING', true),
  };
}

// 使用
const flags = getFeatureFlags();
const bridge = flags.enableWarmPool
  ? new WarmPoolBridge(flags)
  : new ColdStartBridge(flags);
```

**关键区别**:
- 事后的环境变量开关：代码中散落的 `if (process.env.XXX)`，难以维护
- Feature Flag 系统：集中管理、有默认值、可远程切换、有类型安全

对你的规模，不需要 LaunchDarkly 这种 SaaS。一个简单的 `feature-flags.ts` 文件 + 环境变量就够了。重要的是**从设计阶段就考虑可切换性**。

### 3. 蓝绿部署的深层逻辑

你在 Stage-ECS 中已经有蓝绿部署的配置。但理解底层逻辑很重要：

```
蓝绿部署:
  Blue (当前版本) ←── ALB 流量
  Green (新版本)

部署:
  1. 启动 Green
  2. 健康检查通过
  3. ALB 切流量到 Green
  4. 观察 5 分钟
  5. 正常 → 停掉 Blue
  6. 异常 → ALB 切回 Blue（回滚）

对 AI Shell 的特殊考虑:
  - WebSocket 是长连接，切流量时现有连接不会断
  - 新连接走 Green，旧连接继续在 Blue
  - Blue 停止前需要等所有旧连接关闭（graceful drain）
  - drain timeout 要足够长（至少 > 会话平均时长）
```

**ECS 的滚动更新本质上就是简化版蓝绿**。理解这个过程后，你就知道为什么需要配置：
- `deregistration_delay`: ALB 等待旧 task 排空连接的时间
- `health_check_grace_period`: 新 task 启动后的免检期
- `minimum_healthy_percent`: 更新期间至少保持多少比例的旧 task

### 4. Drift Detection

**问题**: 有人手动在 AWS Console 改了个安全组规则，Terraform state 和实际资源不一致了。下次 `terraform apply` 可能会产生意外变更。

**解决方案**:

```bash
# 定期运行 plan，检查 drift
terraform plan -detailed-exitcode
# exit code 0 = 无变更
# exit code 1 = 错误
# exit code 2 = 有变更（drift!）
```

**自动化**:

```yaml
# .github/workflows/drift-check.yml
name: Drift Check
on:
  schedule:
    - cron: '0 8 * * 1'  # 每周一早上 8 点

jobs:
  drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: terraform init && terraform plan -detailed-exitcode
        continue-on-error: true
        id: plan
      - if: steps.plan.outcome == 'failure'
        run: |
          echo "::warning::Drift detected! Someone made manual changes."
          # 可以发 Slack 通知
```

### 5. Infrastructure 测试

**你可能没想过的**: 基础设施也可以写测试。

**分层**:

```
静态分析（秒级，CI 中必跑）:
  - terraform validate          → 语法检查
  - terraform fmt -check        → 格式检查
  - tflint                      → 最佳实践检查
  - checkov / tfsec             → 安全合规检查

Plan 级测试（分钟级）:
  - OPA / Sentinel              → policy-as-code
  - "plan 结果中不能出现 destroy 关键资源"

集成测试（10-30分钟，按需）:
  - Terratest                   → 真正创建资源 → 验证 → 销毁
  - 适合验证模块的正确性
```

**最低成本的第一步**: 在 CI 中加 `terraform validate` + `terraform fmt -check`。

```yaml
# 加到 terraform-plan.yml 中
- name: Format Check
  run: terraform fmt -check -recursive

- name: Validate
  run: terraform validate
```

---

## 演进式架构的思维模式

### 设计原则

1. **任何变更都应该是可逆的**
   - 不是"加回滚方案"，而是"设计时就保证可逆"
   - 数据库 migration 要同时写 up 和 down
   - API 变更要向后兼容

2. **渐进式发布**
   - 不要一次性切换所有流量
   - 1% → 10% → 50% → 100%
   - 在 AI Shell 中：先让新架构处理 Stage 流量，稳定后再切 Prod

3. **可观测驱动的发布**
   - 发布后看指标，不是看日志
   - SLO 没有下降 → 继续
   - SLO 下降 → 自动或手动回滚

4. **最小变更原则**
   - 每个 PR 只做一件事
   - Phase 0/1/2/3 的分阶段就是这个思想
   - 不要"顺手优化"不相关的代码

---

## 对 Optima 项目的具体建议

### 立即可做

1. 给 `optima-terraform` 仓库加一个简单的 CI:
   - PR 时自动 `terraform fmt -check` + `terraform validate`
   - 不需要自动 plan（需要 AWS 凭证，配置较复杂）

2. 在 `ai-shell` 项目中创建 `feature-flags.ts`，集中管理所有开关

### 短期（结合 Phase 0-1）

3. 每次部署前后记录关键指标（Phase 1 的日报脚本可以辅助）
4. 定义 Stage → Prod 的发布检查清单（checklist）

### 中期

5. 给 `optima-terraform` 加自动 plan PR 评论
6. 每周定时 drift check
7. 考虑用 tfsec 做安全扫描

---

## 推荐资源

| 资源 | 类型 | 时间 | 说明 |
|------|------|------|------|
| [Terraform Best Practices](https://www.terraform-best-practices.com/) | 文档 | 2h | 社区维护的最佳实践指南 |
| [HashiCorp Learn - Terraform CI/CD](https://developer.hashicorp.com/terraform/tutorials/automation) | 教程 | 3h | 官方 CI/CD 教程 |
| [Building Evolutionary Architectures](https://www.oreilly.com/library/view/building-evolutionary-architectures/9781491986356/) | 书 | 1 周 | 演进式架构的理论框架 |
| [Martin Fowler - Feature Toggles](https://martinfowler.com/articles/feature-toggles.html) | 博客 | 1h | Feature Flag 的经典文章 |
| [tfsec](https://github.com/aquasecurity/tfsec) | 工具 | 30min | Terraform 安全扫描 |
| [Spacelift / Atlantis](https://www.runatlantis.io/) | 工具 | 按需 | Terraform PR 自动化工具 |
