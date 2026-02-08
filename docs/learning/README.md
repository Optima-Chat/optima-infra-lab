# 技术成长路线：从项目实践到体系化认知

> **背景**: 基于 Optima 项目的实际架构决策，识别出的知识体系差距和学习路线。
> **目标读者**: 有完整项目落地经验、需要从"能用"提升到"深入理解为什么这样做"的工程师。

---

## 现状评估

**已具备的能力**:
- 全栈工程落地：IaC (Terraform)、微服务、CI/CD、容器编排 (ECS)、密钥管理
- 成本敏感的架构决策：共享资源、按需扩容、环境隔离
- 问题排查和修复的闭环能力

**核心差距**: 不在于"不会用某个工具"，而在于某些领域缺少**体系化的思维框架**。

---

## 文档目录

### 1. [可观测性体系](./01-observability.md)
从 console.log 到 Observability 三大支柱（Logs / Metrics / Traces）。理解 OpenTelemetry、SLI/SLO、告警策略。

**对应项目问题**: Phase 1 日志改造只是起点，缺少 Metrics 和 Traces 的整体规划。

### 2. [分布式系统容错模式](./02-distributed-resilience.md)
Circuit Breaker、Retry with Backoff、Idempotency、Graceful Degradation。理解为什么竞态条件反复出现。

**对应项目问题**: Phase 0 的竞态修复是 case-by-case 的，缺少系统性的容错设计。

### 3. [负载测试与容量规划](./03-load-testing.md)
k6 实战、Testing Pyramid、Chaos Engineering 基础。学会用数据而非直觉做容量决策。

**对应项目问题**: 预热池大小 3 是拍脑袋的，不知道系统的真实瓶颈在哪。

### 4. [容器与云原生安全](./04-container-security.md)
纵深防御、CIS Benchmark、供应链安全、密钥轮转。从点状防御到体系化安全。

**对应项目问题**: EFS AP 隔离降级为目录隔离时，缺少系统性的风险补偿方案。

### 5. [基础设施演进式架构](./05-infrastructure-evolution.md)
GitOps、Feature Flags、Terraform CI、蓝绿部署的深层逻辑。

**对应项目问题**: 回滚方案是事后补救而非架构默认配备。

---

## 推荐阅读优先级

| 优先级 | 资源 | 类型 | 预计时间 | 直接受益 |
|--------|------|------|---------|---------|
| P0 | DDIA 第 8-9 章 | 书 | 2-3 天 | 分布式容错思维 |
| P0 | OpenTelemetry 官方文档 Concepts 部分 | 文档 | 半天 | Phase 1 设计质量 |
| P1 | k6 Getting Started + 跑一次负载测试 | 实操 | 1 天 | Phase 3 预热池sizing |
| P1 | Google SRE Book Ch6 (Monitoring) | 书 | 1 天 | 从日志思维到指标思维 |
| P2 | CIS Docker Benchmark | 文档 | 半天 | 容器安全基线 |
| P2 | Terraform Best Practices (HashiCorp) | 文档 | 半天 | IaC 成熟度提升 |

### DDIA 是什么

**Designing Data-Intensive Applications**（《设计数据密集型应用》），Martin Kleppmann 著。分布式系统领域公认的必读书。

这本书好在它不教你用某个具体数据库或框架，而是讲**底层原理和权衡**：
- 为什么分布式系统中"恰好一次"这么难？
- 网络分区发生时，一致性和可用性怎么取舍？
- 不同的复制策略对你的系统意味着什么？

读完后你会发现，你在 AI Shell 中遇到的竞态条件、状态不一致、重连失败，都是分布式系统中反复出现的经典问题，有成熟的解决模式。

**中文版**: 《数据密集型应用系统设计》，可直接买中译本。
