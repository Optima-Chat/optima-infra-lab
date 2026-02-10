# 云原生架构师技能图谱

> **背景**: 基于 Optima 项目的实际架构决策，识别出的知识体系差距和学习路线。
> **目标读者**: 有完整项目落地经验、需要从"能用"提升到"深入理解为什么这样做"的工程师。

---

## 技能全景图

现代云原生架构师的知识体系可以分为四个层次，从底层到顶层逐步构建：

```
┌─────────────────────────────────────────────────────────────────┐
│                        运维与治理层                               │
│   可观测性 · FinOps 成本优化 · 安全合规 · 混沌工程                  │
├─────────────────────────────────────────────────────────────────┤
│                        应用架构层                                │
│   系统设计模式 · 认证与安全 · 性能工程 · 分布式容错                  │
├─────────────────────────────────────────────────────────────────┤
│                        平台与编排层                               │
│   Kubernetes · 容器编排(ECS) · IaC(Terraform) · CI/CD · GitOps   │
├─────────────────────────────────────────────────────────────────┤
│                        基础设施层                                │
│   网络协议 · Linux/容器底层 · 数据库工程 · 负载测试与容量规划        │
└─────────────────────────────────────────────────────────────────┘
```

### 技能矩阵

| 层次 | 技能领域 | 核心知识点 | 对应文档 | 掌握标志 |
|------|---------|-----------|---------|---------|
| **基础** | 网络协议 | TCP/IP、DNS、HTTP/2、TLS、WebSocket | [06](./06-networking-fundamentals.md) | 能用 tcpdump/curl 排查线上网络问题 |
| **基础** | Linux/容器底层 | namespace、cgroups、overlay FS、信号处理 | [07](./07-linux-container-internals.md) | 能解释容器为什么不是虚拟机 |
| **基础** | 数据库工程 | 索引原理、EXPLAIN、事务隔离、连接池、迁移 | [08](./08-database-engineering.md) | 能读懂执行计划并优化慢查询 |
| **基础** | 负载测试 | k6、压测方法论、容量规划、Chaos Engineering | [03](./03-load-testing.md) | 能用数据而非直觉做容量决策 |
| **平台** | 容器编排 | K8s 架构、Deployment、Service、Helm、Operator | [10](./10-kubernetes-orchestration.md) | 能部署和运维 K8s 集群 |
| **平台** | IaC 演进 | Terraform CI、GitOps、蓝绿部署、Feature Flags | [05](./05-infrastructure-evolution.md) | 回滚是架构默认配备而非事后补救 |
| **应用** | 系统设计 | 微服务拆分、事件驱动、Saga、CAP、幂等性 | [09](./09-system-design-patterns.md) | 能做架构权衡决策并说清楚 trade-off |
| **应用** | 分布式容错 | Circuit Breaker、Retry、Graceful Degradation | [02](./02-distributed-resilience.md) | 在设计阶段内建容错而非事后修补 |
| **应用** | 认证与安全 | OAuth2、JWT、零信任、OWASP Top 10、密钥管理 | [11](./11-auth-api-security.md) | 能设计端到端的安全认证方案 |
| **应用** | 性能工程 | 火焰图、缓存策略、Redis、连接池、Node.js 性能 | [13](./13-performance-engineering.md) | 能用 USE/RED 方法定位瓶颈 |
| **运维** | 可观测性 | Logs/Metrics/Traces、OpenTelemetry、SLI/SLO | [01](./01-observability.md) | 有统一的可观测性策略 |
| **运维** | 容器安全 | CIS Benchmark、供应链安全、纵深防御 | [04](./04-container-security.md) | 安全是体系化的而非点状防御 |
| **运维** | FinOps | 定价模型、右置化、架构成本优化、成本可观测 | [12](./12-finops-cost-optimization.md) | 每个架构决策都考虑成本维度 |

---

## 文档目录

### 基础设施层 — "知其然，知其所以然"

#### 06. [网络基础：从 HTTP 请求到负载均衡](./06-networking-fundamentals.md)
TCP/IP 四层模型、DNS 解析全过程、HTTP/1.1 vs HTTP/2 vs HTTP/3、TLS 握手、负载均衡算法（轮询/加权/一致性哈希）、WebSocket 协议、CDN 原理、网络排查工具。

**对应项目问题**: ALB 路由和 WebSocket 是"能跑就行"，不理解协议层面发生了什么，出问题靠猜。

#### 07. [Linux 与容器底层：理解容器不是虚拟机](./07-linux-container-internals.md)
Linux 进程模型（PID 1 问题）、文件描述符与 IO 模型（epoll → Node.js 事件循环）、六大 Namespace、Cgroups v2 资源限制、OverlayFS 分层原理、容器运行时（containerd/runc）、Docker 镜像最佳实践、优雅停机。

**对应项目问题**: ECS Task 的 CPU/Memory 配置是抄的，不理解底层的 cgroups 限制机制。

#### 08. [数据库工程：从写 SQL 到理解存储引擎](./08-database-engineering.md)
PostgreSQL 索引原理（B-tree/GIN/GiST）、EXPLAIN ANALYZE 实战、事务隔离与 MVCC、连接池管理（PgBouncer）、零停机迁移、读写分离、备份恢复（PITR）、分库分表思路。

**对应项目问题**: 共享 RDS 多数据库隔离是配了，但连接数规划、索引策略、迁移方案缺乏体系化认知。

#### 03. [负载测试与容量规划](./03-load-testing.md)
k6 实战、Testing Pyramid、Chaos Engineering 基础。学会用数据而非直觉做容量决策。

**对应项目问题**: 预热池大小 3 是拍脑袋的，不知道系统的真实瓶颈在哪。

### 平台与编排层 — "用对工具，管好基础设施"

#### 10. [Kubernetes 与容器编排：云原生的事实标准](./10-kubernetes-orchestration.md)
K8s 架构总览（Control Plane + Node）、核心工作负载（Pod/Deployment/StatefulSet）、Service 四种类型与 Ingress、ConfigMap/Secret、PV/PVC 存储、Helm 包管理、Operator 模式、Service Mesh（Istio/Linkerd）、ECS vs K8s 深度对比。

**对应项目问题**: 当前用 ECS 是合理的成本决策，但 K8s 是行业标准，必须深入理解才能做出未来架构演进的判断。

#### 05. [基础设施演进式架构](./05-infrastructure-evolution.md)
GitOps、Feature Flags、Terraform CI、蓝绿部署的深层逻辑。

**对应项目问题**: 回滚方案是事后补救而非架构默认配备。

### 应用架构层 — "设计经得起考验的系统"

#### 09. [系统设计与架构模式：从单体到微服务的思维升级](./09-system-design-patterns.md)
微服务拆分原则（DDD 限界上下文）、API 设计（REST/GraphQL/gRPC）、事件驱动架构（Event Sourcing/CQRS）、Saga 模式（编排型 vs 协调型）、API Gateway 模式、BFF 模式、CAP/PACELC 定理、幂等性设计、最终一致性。

**对应项目问题**: 四个核心服务的拆分是凭直觉做的，缺少 DDD 方法论的指导和 trade-off 分析。

#### 02. [分布式系统容错模式](./02-distributed-resilience.md)
Circuit Breaker、Retry with Backoff、Idempotency、Graceful Degradation。理解为什么竞态条件反复出现。

**对应项目问题**: Phase 0 的竞态修复是 case-by-case 的，缺少系统性的容错设计。

#### 11. [认证与 API 安全：从 JWT 到零信任](./11-auth-api-security.md)
OAuth 2.0 完整框架（Authorization Code + PKCE）、OpenID Connect、JWT 深入（签名算法/安全陷阱）、Session vs Token 认证、零信任架构、API 安全实践（Rate Limiting/CORS/OWASP Top 10）、密钥管理对比（Infisical/Vault/Secrets Manager）、mTLS。

**对应项目问题**: user-auth 的 JWT 实现是能用的，但对 OAuth2 完整流程、Token 吊销、零信任等缺少体系认知。

#### 13. [性能工程：从"感觉慢"到数据驱动的优化](./13-performance-engineering.md)
USE/RED 方法论、CPU 火焰图与性能分析、内存泄漏检测、缓存策略（Cache-Aside/Write-Through/雪崩/穿透/击穿）、Redis 使用模式、连接池调优、N+1 查询、异步处理与消息队列、CDN 缓存策略、Node.js 事件循环与性能特质。

**对应项目问题**: 性能问题靠"感觉"和"重启"解决，缺少系统化的分析方法和工具链。

### 运维与治理层 — "让系统可靠地运行"

#### 01. [可观测性体系](./01-observability.md)
从 console.log 到 Observability 三大支柱（Logs / Metrics / Traces）。理解 OpenTelemetry、SLI/SLO、告警策略。

**对应项目问题**: Phase 1 日志改造只是起点，缺少 Metrics 和 Traces 的整体规划。

#### 04. [容器与云原生安全](./04-container-security.md)
纵深防御、CIS Benchmark、供应链安全、密钥轮转。从点状防御到体系化安全。

**对应项目问题**: EFS AP 隔离降级为目录隔离时，缺少系统性的风险补偿方案。

#### 12. [FinOps 与云成本优化：花对每一分钱](./12-finops-cost-optimization.md)
云成本模型（按需/预留/Spot/Savings Plans）、FinOps 三阶段框架、右置化分析、架构层面成本优化（Serverless vs Container vs EC2）、数据传输/存储/数据库成本、成本可观测性（Cost Explorer/CUR/Tags）、多租户成本分摊。

**对应项目问题**: 成本决策主要靠经验和直觉，缺少系统化的 FinOps 方法论。

---

## 学习路线

### 第一阶段：补基础（4-6 周）

打好底层基础，让日常工作中的"黑盒"变透明。

| 周次 | 学习内容 | 产出 |
|------|---------|------|
| 第 1 周 | [06 网络基础](./06-networking-fundamentals.md) + 用 curl/tcpdump 抓包练习 | 能用工具排查一个实际网络问题 |
| 第 2 周 | [07 Linux/容器底层](./07-linux-container-internals.md) + 用 unshare 手建 namespace | 能解释 ECS Task 资源限制的底层原理 |
| 第 3 周 | [08 数据库工程](./08-database-engineering.md) + 在本地 PostgreSQL 跑 EXPLAIN | 能优化一条实际慢查询 |
| 第 4 周 | [13 性能工程](./13-performance-engineering.md) + 生成一次火焰图 | 能用 USE/RED 方法分析一个服务 |

### 第二阶段：建体系（4-6 周）

从"能用"到"知道为什么这样做"，建立架构思维。

| 周次 | 学习内容 | 产出 |
|------|---------|------|
| 第 5 周 | [09 系统设计模式](./09-system-design-patterns.md) + 读 DDIA 第 1-4 章 | 能画出 Optima 的 DDD 上下文图 |
| 第 6 周 | [02 分布式容错](./02-distributed-resilience.md) + 读 DDIA 第 8-9 章 | 能设计一套容错方案而非逐个修 bug |
| 第 7 周 | [11 认证安全](./11-auth-api-security.md) + OAuth2 RFC 速读 | 能做 user-auth 的安全审计 |
| 第 8 周 | [10 Kubernetes](./10-kubernetes-orchestration.md) + 用 kind 部署一套集群 | 能做 ECS 到 K8s 的迁移评估 |

### 第三阶段：上高度（4-6 周）

站在运维和治理的角度看全局。

| 周次 | 学习内容 | 产出 |
|------|---------|------|
| 第 9 周 | [01 可观测性](./01-observability.md) + OpenTelemetry 官方文档 | 输出 Optima 可观测性改造方案 |
| 第 10 周 | [03 负载测试](./03-load-testing.md) + 用 k6 跑一次压测 | 拿到系统真实的性能基线数据 |
| 第 11 周 | [04 容器安全](./04-container-security.md) + [05 IaC 演进](./05-infrastructure-evolution.md) | 输出安全加固和 GitOps 落地方案 |
| 第 12 周 | [12 FinOps](./12-finops-cost-optimization.md) + AWS Well-Architected Review | 输出 Optima 成本优化 roadmap |

---

## 必读书单

### 顶级优先（反复翻阅）

| 书名 | 作者 | 为什么必读 | 重点章节 |
|------|------|-----------|---------|
| **DDIA**《设计数据密集型应用》 | Martin Kleppmann | 分布式系统的底层原理和权衡，所有架构决策的理论基础 | 第 5-9 章（复制、分区、事务、一致性） |
| **Google SRE Book** | Google | 从 Google 视角理解大规模系统的可靠性 | Ch4 SLO、Ch6 Monitoring、Ch17 可靠性测试 |
| **Systems Performance** | Brendan Gregg | 性能分析的圣经，USE Method 的发明者 | Ch2 方法论、Ch6 CPU、Ch8 File Systems |

### 高优先

| 书名 | 作者 | 为什么读 |
|------|------|---------|
| **Building Microservices** (2nd Ed) | Sam Newman | 微服务设计模式的最佳实践指南 |
| **TCP/IP Illustrated Vol.1** | W. Richard Stevens | 网络协议的权威参考，排查网络问题的底气 |
| **The Art of PostgreSQL** | Dimitri Fontaine | PostgreSQL 从入门到精通，SQL 写法和优化技巧 |
| **Kubernetes in Action** (2nd Ed) | Marko Lukša | K8s 最好的入门到进阶教程 |

### 按需阅读

| 书名 | 适用场景 |
|------|---------|
| **Clean Architecture** — Robert C. Martin | 软件架构的通用原则 |
| **Release It!** — Michael T. Nygard | 生产环境的容错和稳定性模式 |
| **Web Scalability for Startup Engineers** — Artur Ejsmont | 面向创业公司的扩展性设计 |
| **Cloud Native Patterns** — Cornelia Davis | 云原生应用设计模式 |

---

## 在线资源

### 官方文档（最权威）

| 资源 | 链接 | 用途 |
|------|------|------|
| AWS Well-Architected Framework | aws.amazon.com/architecture/well-architected | 六大支柱：运维、安全、可靠性、性能、成本、可持续性 |
| Kubernetes 官方教程 | kubernetes.io/docs/tutorials | K8s 入门到实战 |
| OpenTelemetry Docs | opentelemetry.io/docs | 可观测性标准 |
| PostgreSQL 官方文档 | postgresql.org/docs | 索引、查询优化、复制 |
| Terraform Learn | developer.hashicorp.com/terraform/tutorials | IaC 最佳实践 |

### 学习平台

| 平台 | 推荐内容 |
|------|---------|
| **KodeKloud** | CKA/CKAD 实验环境，最好的 K8s 实操平台 |
| **A Cloud Guru / Udemy** | AWS SAA/SAP 考证课程 |
| **systemdesign.one** | 系统设计案例分析 |
| **ByteByteGo** (Alex Xu) | 系统设计面试准备，图解清晰 |

### 博客与社区

| 来源 | 推荐理由 |
|------|---------|
| **Brendan Gregg's Blog** | 性能分析领域的权威 |
| **Martin Fowler's Blog** | 软件架构模式的经典总结 |
| **AWS Architecture Blog** | 真实案例的架构决策 |
| **The Morning Paper** | 分布式系统论文精选（已归档但仍有价值） |
| **InfoQ / 极客时间** | 中文技术社区的深度内容 |

---

## 认证路线

认证不是目的，但备考过程是系统化学习的好手段。

| 认证 | 优先级 | 预计备考 | 价值 |
|------|--------|---------|------|
| **AWS SAA** (Solutions Architect Associate) | P0 | 4-6 周 | AWS 服务全景和架构最佳实践，日常工作直接受益 |
| **CKA** (Certified Kubernetes Administrator) | P1 | 6-8 周 | K8s 运维能力认证，补齐容器编排短板 |
| **Terraform Associate** | P1 | 2-3 周 | IaC 标准化，已有 Terraform 经验所以备考轻松 |
| **AWS SAP** (Solutions Architect Professional) | P2 | 8-12 周 | 高级架构设计，在 SAA 基础上进阶 |
| **CKAD** (Certified Kubernetes Application Developer) | P2 | 4-6 周 | K8s 应用开发视角，与 CKA 互补 |
| **CKS** (Certified Kubernetes Security Specialist) | P3 | 4-6 周 | K8s 安全专项，在 CKA 基础上进阶 |

---

## 现状评估

**已具备的能力**:
- 全栈工程落地：IaC (Terraform)、微服务、CI/CD、容器编排 (ECS)、密钥管理
- 成本敏感的架构决策：共享资源、按需扩容、环境隔离
- 问题排查和修复的闭环能力

**核心差距**: 不在于"不会用某个工具"，而在于某些领域缺少**体系化的思维框架**。

这 13 篇文档的目标就是把这些框架补上——不是教你用新工具，而是让你理解**底层原理和权衡**，在做架构决策时能说清楚"为什么选 A 而不是 B"。

---

### DDIA 是什么

**Designing Data-Intensive Applications**（《设计数据密集型应用》），Martin Kleppmann 著。分布式系统领域公认的必读书。

这本书好在它不教你用某个具体数据库或框架，而是讲**底层原理和权衡**：
- 为什么分布式系统中"恰好一次"这么难？
- 网络分区发生时，一致性和可用性怎么取舍？
- 不同的复制策略对你的系统意味着什么？

读完后你会发现，你在 AI Shell 中遇到的竞态条件、状态不一致、重连失败，都是分布式系统中反复出现的经典问题，有成熟的解决模式。

**中文版**: 《数据密集型应用系统设计》，可直接买中译本。
