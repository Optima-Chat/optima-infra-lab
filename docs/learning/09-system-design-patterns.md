# 09 - 系统设计与架构模式

> 从单体到微服务的思维升级：不是拆得越细越好，而是拆在正确的边界上

---

## 我们现在在哪

```
Optima 平台的架构现状：

✅ 做得好的:
  - 四个核心服务（user-auth / commerce-backend / mcp-host / agentic-chat）职责清晰
  - 每个服务独立数据库、独立容器、独立部署
  - MCP Host 作为编排层统一调度 7 个 MCP 工具
  - Cloud Map 内部 DNS 用于服务发现（xxx-ecs.optima-stage.local）
  - ALB 统一外部入口，Listener Rules 按域名路由

⚠️ 可以更好的:
  - 服务拆分是凭直觉做的，缺少 DDD 方法论的指导和边界分析
  - 服务间全部用 HTTP 同步调用，没有事件驱动或异步通信
  - 没有 API 版本策略，前端后端强耦合
  - 电商订单流程缺少 Saga 等分布式事务模式
  - mcp-host 调 mcp 工具失败时没有补偿机制
  - 没有 API Gateway 层（ALB 只做 L7 路由，不做限流/聚合/认证卸载）
  - 前端（Web + 移动端）调用同一套 API，无 BFF 层
  - 服务间调用缺少幂等性设计
```

架构模式不是银弹，每一个模式都有它的代价。这章的目标是让你在做架构决策时，能清楚地说出 **"我选 A 而不是 B，因为在我们的场景下 X 比 Y 更重要"**。

---

## 1. 微服务拆分原则

### 为什么要拆

单体应用在团队小（<5 人）、业务简单时是最高效的选择。问题出在两个时刻：
- **组织扩张**：多个团队同时修改同一个代码库，互相踩脚
- **部署耦合**：改一行用户登录逻辑，必须重新部署整个电商系统

微服务的本质是**组织问题的技术映射**（康威定律）：

```
康威定律（Conway's Law）:

  组织的沟通结构 ─→ 系统架构

  如果有 4 个团队，系统就会倾向于被拆成 4 个模块。
  不是因为技术上需要 4 个模块，而是因为 4 个团队需要独立工作。

Optima 现状:
  ┌─────────────┐   ┌──────────────┐   ┌───────────┐   ┌──────────────┐
  │  user-auth  │   │  commerce-   │   │  mcp-host │   │  agentic-    │
  │  认证团队    │   │  backend     │   │  AI 团队   │   │  chat        │
  │             │   │  电商团队     │   │           │   │  AI 团队      │
  └─────────────┘   └──────────────┘   └───────────┘   └──────────────┘

  问: mcp-host 和 agentic-chat 都是 AI 团队负责，有必要拆成两个服务吗？
  答: 看下面的"拆分粒度判断"。
```

### DDD 限界上下文（Bounded Context）

限界上下文是 DDD 中最重要的概念之一。它定义了一个模型的适用边界——同一个词在不同上下文中含义不同。

```
"用户" 在不同上下文中的含义:

┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│   认证上下文          │  │   电商上下文          │  │   AI 聊天上下文       │
│   (user-auth)       │  │   (commerce)        │  │   (agentic-chat)    │
│                     │  │                     │  │                     │
│   User:             │  │   Customer:         │  │   Participant:      │
│   - email           │  │   - shipping_addr   │  │   - session_id      │
│   - password_hash   │  │   - payment_method  │  │   - preferred_model │
│   - roles           │  │   - order_history   │  │   - conversation_   │
│   - last_login      │  │   - credit_balance  │  │     history         │
│                     │  │                     │  │                     │
│   关注点:            │  │   关注点:            │  │   关注点:            │
│   认证、授权、安全    │  │   购物、支付、物流    │  │   对话、模型、工具    │
└─────────────────────┘  └─────────────────────┘  └─────────────────────┘

  三个上下文通过 user_id 关联，但各自维护自己的"用户"视图。
  认证上下文不关心送货地址，电商上下文不关心对话历史。
```

**数据所有权原则**：每个限界上下文拥有自己的数据，其他上下文只能通过 API 或事件获取。

```
✅ 正确: 每个服务一个数据库

  user-auth ──→ optima_auth      (auth_user 读写)
  commerce  ──→ optima_commerce  (commerce_user 读写)
  mcp-host  ──→ optima_mcp       (mcp_user 读写)
  chat      ──→ optima_chat      (chat_user 读写)

  commerce 需要用户名？通过 API 调 user-auth 获取，不是直接查 optima_auth。

✗ 错误: 多个服务共享一张表

  commerce ──┐
             ├──→ users 表    ← 谁负责 schema 变更？谁加索引？
  chat ──────┘               ← 一个服务改了字段，另一个就挂了

  Optima 已经做对了这一点（每个服务独立数据库）。
```

### 拆分粒度判断

拆太粗和拆太细都有代价：

```
拆太粗（单体思维）:
┌───────────────────────────────┐
│         optima-backend        │  代价:
│  auth + commerce + chat + mcp │  - 部署耦合，改一行要全部重部署
│                               │  - 技术栈锁定，想用 Rust 写 MCP？不行
└───────────────────────────────┘  - 团队协作冲突，合并代码是噩梦

拆太细（微服务狂热）:
┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
│ login  │ │ signup │ │ token  │ │ role   │ │ passwd │ │ profile│
└────────┘ └────────┘ └────────┘ └────────┘ └────────┘ └────────┘
  代价:
  - 每个操作跨 3-5 个服务，延迟飙升
  - 分布式事务地狱（注册用户要同时写 4 个服务的数据库）
  - 运维负担爆炸（6 个服务 × ECR + ECS + CloudWatch + ...）
  - 调试时一个请求链路跨 6 个容器

Optima 的选择（合理的中间态）:
┌───────────┐ ┌──────────────┐ ┌───────────┐ ┌──────────────┐
│ user-auth │ │   commerce-  │ │  mcp-host │ │  agentic-    │
│           │ │   backend    │ │           │ │  chat        │
│ 登录 注册  │ │ 订单 产品 支付 │ │ 调度 工具管理│ │ 对话 Agent    │
│ 角色 JWT  │ │ 库存 物流    │ │           │ │ Session      │
└───────────┘ └──────────────┘ └───────────┘ └──────────────┘
```

**拆分决策清单**（回答以下问题来决定是否该拆）：

| 问题 | 答 Yes → 拆 | 答 No → 不拆 |
|------|------------|-------------|
| 这两个功能由不同团队维护吗？ | 减少协调成本 | 拆了反而多一层通信 |
| 它们有不同的扩容需求吗？ | 独立扩容更省钱 | 一起扩容就行 |
| 它们有不同的发布节奏吗？ | 独立发布更快 | 一起发布也没什么 |
| 它们有不同的技术栈需求吗？ | 各用各的语言/框架 | 统一技术栈更简单 |
| 拆了之后事务一致性好处理吗？ | 事件最终一致可接受 | 强一致不能妥协 |

**Optima 的 mcp-host vs agentic-chat 分析**：

```
mcp-host 和 agentic-chat 要不要合并？

  mcp-host: 调度 MCP 工具（comfy-mcp, fetch-mcp, shopify-mcp...）
  agentic-chat: 管理对话 session、调用 LLM、组装 Agent 回复

  不同的扩容需求？ → Yes
    mcp-host 是 CPU/IO 密集（等待 MCP 工具响应），chat 是内存密集（维护 session）
  不同的发布节奏？ → Yes
    新增一个 MCP 工具只改 mcp-host，不影响 chat
  事务一致性？ → 不需要强一致
    chat 调 mcp-host 失败了，给用户返回"工具暂不可用"就行

  结论: 拆分是合理的。
```

---

## 2. API 设计哲学

### REST 成熟度模型（Richardson Maturity Model）

Leonard Richardson 提出的 REST 成熟度四级模型，帮助你评估"你的 API 有多 RESTful"：

```
Level 0 — 一个 URL，一个 POST（RPC 风格）
  POST /api
  Body: { "action": "getUser", "userId": 123 }
  Body: { "action": "createOrder", "items": [...] }

  所有请求走同一个 endpoint，靠 body 里的 action 字段区分操作。
  这不是 REST，这是 HTTP 上的 RPC。

Level 1 — 多个 URL（引入资源概念）
  POST /api/users/123        ← 至少有了资源的概念
  POST /api/orders

  但所有操作都是 POST，没有利用 HTTP 方法的语义。

Level 2 — HTTP 方法 + 状态码（大多数团队到这里）
  GET    /api/users/123      → 200 OK
  POST   /api/orders         → 201 Created
  PUT    /api/orders/456     → 200 OK
  DELETE /api/orders/456     → 204 No Content
  GET    /api/orders?status=pending → 200 OK

  使用 GET/POST/PUT/DELETE 表达操作意图。
  使用 2xx/4xx/5xx 状态码表达结果。
  Optima 的 API 基本在这个级别。

Level 3 — HATEOAS（超媒体驱动，几乎没人做到）
  GET /api/orders/456
  {
    "id": 456,
    "status": "pending",
    "_links": {
      "self": { "href": "/api/orders/456" },
      "cancel": { "href": "/api/orders/456/cancel", "method": "POST" },
      "payment": { "href": "/api/payments?order=456", "method": "POST" }
    }
  }

  客户端通过响应中的链接发现下一步可以做什么。
  优点: API 自描述，客户端不需要硬编码 URL。
  现实: 过于理想化，增加了大量复杂度，实践中几乎没人做到 Level 3。
```

**务实建议**：做到 Level 2 就够了。把精力放在 API 的一致性、文档和版本管理上，比追求 HATEOAS 有用得多。

### GraphQL 适用场景

```
REST 的痛点（Over-fetching / Under-fetching）:

  场景: 移动端展示商品卡片，需要商品名 + 价格 + 一张缩略图

  REST 方式:
    GET /api/products/123    → 返回 50 个字段（over-fetching，浪费带宽）
    GET /api/products/123/images → 还要再发一个请求（under-fetching）

  GraphQL 方式:
    query {
      product(id: 123) {
        name
        price
        images(first: 1) { thumbnail_url }
      }
    }
    → 精确返回需要的 3 个字段

GraphQL 适合:                        GraphQL 不适合:
  ✅ 前端驱动的数据获取              ✗ 简单的 CRUD API
  ✅ 移动端（带宽敏感）              ✗ 文件上传/下载
  ✅ 多种客户端需要不同数据形状        ✗ 实时流式响应（用 WebSocket）
  ✅ 复杂嵌套关系的数据              ✗ 服务间内部通信（用 gRPC）
  ✅ 快速迭代的产品（前端自由取数据）   ✗ 团队不愿投入 schema 维护
```

### gRPC 用于内部通信

```
为什么服务间调用考虑 gRPC 而不是 REST：

  REST (JSON over HTTP/1.1):
    POST /api/generate-image
    Content-Type: application/json
    {"prompt": "a sunset", "size": "512x512"}

    特点:
    - 文本格式，人类可读
    - 序列化/反序列化开销大
    - 没有强类型校验（靠文档和约定）
    - 每个请求一个 TCP 连接（HTTP/1.1）

  gRPC (Protocol Buffers over HTTP/2):
    // image_service.proto
    service ImageService {
      rpc Generate(GenerateRequest) returns (GenerateResponse);
      rpc StreamGenerate(GenerateRequest) returns (stream ImageChunk);
    }

    message GenerateRequest {
      string prompt = 1;
      string size = 2;
    }

    特点:
    - 二进制格式，体积小 3-10 倍
    - 强类型，编译时校验（proto 文件即合约）
    - HTTP/2 多路复用，一个连接跑多个请求
    - 原生支持流式传输（Server/Client/Bidirectional streaming）
    - 自动生成客户端代码（TypeScript / Python / Go / ...）

Optima 的场景:
  mcp-host ──HTTP/JSON──→ comfy-mcp       （当前）
  mcp-host ──gRPC──→ comfy-mcp             （未来可考虑）

  收益: 延迟降低（二进制小）、类型安全（proto 文件）、流式支持（图像生成进度）
  代价: 需要维护 proto 文件、调试不如 curl 方便、浏览器直接调用需要 gRPC-Web

  现阶段建议: 暂时保持 HTTP/JSON（简单），等服务间调用量大了再考虑 gRPC。
```

### API 版本策略

```
三种版本策略对比:

  1. URL 版本（最常见，最简单）
     GET /api/v1/products/123
     GET /api/v2/products/123    ← v2 增加了字段

     优点: 直观，curl 和浏览器都能看到版本
     缺点: URL 不纯（REST 纯粹主义者不满）

  2. Header 版本
     GET /api/products/123
     Accept: application/vnd.optima.v2+json

     优点: URL 干净
     缺点: 调试不方便，Postman/curl 要手动加 header

  3. Query 参数版本
     GET /api/products/123?version=2

     优点: 简单
     缺点: 缓存不友好（CDN 可能忽略 query 参数）

务实建议:
  对外 API → URL 版本（/api/v1/...），最清晰
  对内 API → 不版本化，直接改，因为你控制所有客户端
  破坏性变更 → 新版本 + 旧版本并行运行 + 设定淘汰时间
```

---

## 3. 事件驱动架构

### 从同步到异步

```
同步调用链（当前 Optima 的方式）:

  用户 ──→ agentic-chat ──→ mcp-host ──→ comfy-mcp ──→ 返回
          等待...          等待...       等待...       （可能 30s+）

  问题:
  - 整条链路的延迟 = 所有服务延迟之和
  - 任何一个环节超时，整个请求失败
  - chat 服务的线程/连接被 hold 住，无法服务其他用户

事件驱动（异步）:

  用户 ──→ agentic-chat ──→ 发事件 "ImageGenerationRequested" ──→ 返回 202 Accepted
                                       │
                                       ▼
                            mcp-host 消费事件 → comfy-mcp
                                       │
                                       ▼
                            发事件 "ImageGenerationCompleted"
                                       │
                                       ▼
                            agentic-chat 推送结果给用户（WebSocket）

  优点:
  - chat 服务立即释放，不被长任务阻塞
  - 生产者和消费者解耦，可以独立扩容
  - 天然支持重试（消息没被确认就会重新投递）
```

### Event Sourcing（事件溯源）

Event Sourcing 的核心思想：**不存储当前状态，存储导致状态变化的所有事件**。

```
传统方式（存状态）:
  orders 表:
  | id  | status    | total | updated_at          |
  |-----|-----------|-------|---------------------|
  | 001 | shipped   | 99.00 | 2025-01-15 10:00:00 |

  问题: 这个订单之前是什么状态？谁改的？什么时候改的？不知道。

Event Sourcing（存事件）:
  order_events 表:
  | event_id | order_id | event_type        | data                    | timestamp           |
  |----------|----------|-------------------|-------------------------|---------------------|
  | e001     | 001      | OrderCreated      | {"items": [...]}        | 2025-01-15 08:00:00 |
  | e002     | 001      | PaymentReceived   | {"amount": 99.00}       | 2025-01-15 08:05:00 |
  | e003     | 001      | OrderShipped      | {"tracking": "SF123"}   | 2025-01-15 10:00:00 |

  当前状态 = 重放所有事件
  完整的审计日志，任何时刻的状态都可以重建
```

```typescript
// Event Sourcing 概念示例
interface OrderEvent {
  eventId: string;
  orderId: string;
  eventType: 'OrderCreated' | 'PaymentReceived' | 'OrderShipped' | 'OrderCancelled';
  data: Record<string, unknown>;
  timestamp: Date;
}

// 从事件流重建当前状态
function rebuildOrderState(events: OrderEvent[]): OrderState {
  let state: OrderState = { status: 'unknown', total: 0, items: [] };

  for (const event of events) {
    switch (event.eventType) {
      case 'OrderCreated':
        state = { ...state, status: 'pending', items: event.data.items as Item[] };
        break;
      case 'PaymentReceived':
        state = { ...state, status: 'paid', total: event.data.amount as number };
        break;
      case 'OrderShipped':
        state = { ...state, status: 'shipped', trackingNumber: event.data.tracking as string };
        break;
      case 'OrderCancelled':
        state = { ...state, status: 'cancelled', cancelReason: event.data.reason as string };
        break;
    }
  }
  return state;
}
```

**Event Sourcing 的代价**：

| 优点 | 缺点 |
|------|------|
| 完整审计日志 | 事件 schema 演化复杂 |
| 可以重建任何时刻的状态 | 查询困难（需要 CQRS 配合） |
| 天然支持时间旅行调试 | 存储量更大 |
| 事件可以驱动多个消费者 | 最终一致性（不能即时查到最新状态） |

**务实建议**：大多数场景不需要 Event Sourcing。在以下场景值得考虑：
- 金融交易（需要完整审计链）
- 订单状态机（需要知道"怎么到这个状态的"）
- 协作编辑（需要冲突解决）

### CQRS（命令查询职责分离）

CQRS 经常和 Event Sourcing 搭配使用，解决"事件存储查询困难"的问题：

```
传统方式（读写同一个模型）:
  ┌─────────────────────────┐
  │      orders 表           │
  │  CREATE / UPDATE / READ  │  ← 读写用同一个模型
  └─────────────────────────┘

  问题: 写优化（范式化）和读优化（反范式化）的需求冲突

CQRS（读写分离）:
  写端（Command）                    读端（Query）
  ┌──────────────┐                 ┌──────────────────┐
  │ 写入事件存储   │ ──事件投影──→  │ 读取优化的视图     │
  │ (append-only) │                │ (反范式化、预计算)  │
  └──────────────┘                 └──────────────────┘

  写端:
    INSERT INTO order_events (event_type, data) VALUES ('OrderCreated', ...);

  投影（异步处理事件，更新读模型）:
    当收到 OrderCreated 事件 → INSERT INTO order_read_model (id, customer_name, total, ...)
    当收到 OrderShipped 事件 → UPDATE order_read_model SET status = 'shipped' WHERE ...

  读端:
    SELECT * FROM order_read_model WHERE customer_id = 123 ORDER BY created_at DESC;
    ← 已经反范式化，不需要 JOIN，查询飞快

Optima 场景:
  commerce-backend 可以考虑:
    写端 → 处理订单创建、支付、发货等命令
    读端 → 商品列表、订单历史、销售报表等查询

  agentic-chat 可以考虑:
    写端 → 记录对话消息事件
    读端 → 对话历史展示、消息搜索
```

### AWS 消息服务选型

```
AWS 消息服务对比:

┌─────────────────┬──────────────────┬──────────────────┬──────────────────┐
│                 │     SNS          │     SQS          │   EventBridge    │
│                 │  (通知服务)       │  (队列服务)       │  (事件总线)       │
├─────────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 模式            │ Pub/Sub          │ 点对点队列        │ 事件路由          │
│ 消息保留        │ 不保留（推送即走）  │ 最多 14 天       │ 最多 24 小时      │
│ 消费者          │ 多个订阅者同时收到  │ 单个消费者        │ 规则匹配多目标    │
│ 重试            │ 有限重试          │ 自动重试 + DLQ   │ 自动重试 + DLQ   │
│ 过滤            │ 消息属性过滤       │ 无               │ 强大的事件模式    │
│ 典型场景        │ 广播通知          │ 任务队列          │ 事件驱动集成      │
│ 延迟            │ 毫秒级            │ 毫秒级           │ ~0.5 秒          │
│ 价格/百万消息    │ ~$0.50           │ ~$0.40          │ ~$1.00           │
└─────────────────┴──────────────────┴──────────────────┴──────────────────┘

常见组合:

  SNS + SQS（Fan-out 模式）:
  ┌─────────┐     ┌─────────┐     ┌─────────────────┐
  │ 订单服务  │────→│  SNS    │────→│ SQS: 库存队列    │──→ 库存服务
  │         │     │ Topic:  │     └─────────────────┘
  │         │     │ Order   │     ┌─────────────────┐
  │         │     │ Created │────→│ SQS: 通知队列    │──→ 通知服务
  │         │     │         │     └─────────────────┘
  │         │     │         │     ┌─────────────────┐
  │         │     │         │────→│ SQS: 分析队列    │──→ 分析服务
  └─────────┘     └─────────┘     └─────────────────┘

  一个事件，多个消费者各自独立处理。

Optima 推荐:
  近期 → SQS（简单任务队列，如 MCP 工具调用异步化）
  中期 → SNS + SQS（订单事件 fan-out 到库存/通知/分析）
  长期 → EventBridge（当服务多了需要复杂路由规则时）
```

---

## 4. Saga 模式

### 为什么需要 Saga

在单体应用中，一个数据库事务可以保证 ACID：

```sql
-- 单体: 一个事务搞定
BEGIN;
  INSERT INTO orders (...) VALUES (...);
  UPDATE inventory SET stock = stock - 1 WHERE product_id = 123;
  INSERT INTO payments (...) VALUES (...);
COMMIT;
-- 任何一步失败，全部回滚
```

微服务中，每个服务有自己的数据库，**不能用跨数据库事务**（2PC 太慢太脆弱）。Saga 是替代方案：把一个大事务拆成多个小事务，每个小事务有对应的补偿操作。

### 编排型 Saga（Orchestration）

有一个中心协调者（Orchestrator）控制流程：

```
Optima 订单流程 - 编排型 Saga:

                    ┌───────────────┐
                    │   Saga 编排器  │
                    │ (commerce-    │
                    │  backend)     │
                    └───────┬───────┘
                            │
          ┌─────────────────┼─────────────────┐
          │                 │                 │
    Step 1: 创建订单   Step 2: 扣减库存   Step 3: 处理支付
          │                 │                 │
          ▼                 ▼                 ▼
    ┌──────────┐     ┌──────────┐     ┌──────────┐
    │ 订单服务  │     │ 库存服务  │     │ 支付服务  │
    │ 创建订单  │     │ 扣减库存  │     │ 扣款     │
    │ (PENDING) │     │ -1       │     │ ¥99     │
    └──────────┘     └──────────┘     └──────────┘

如果 Step 3 支付失败:
    编排器执行补偿:
          │                 │
    补偿 1: 取消订单   补偿 2: 恢复库存
          │                 │
          ▼                 ▼
    ┌──────────┐     ┌──────────┐
    │ 订单服务  │     │ 库存服务  │
    │ 标记取消  │     │ +1       │
    └──────────┘     └──────────┘
```

```typescript
// 编排型 Saga 示例
class OrderSaga {
  private steps: SagaStep[] = [
    {
      name: 'createOrder',
      execute: async (ctx) => {
        const order = await orderService.create(ctx.items, ctx.userId);
        ctx.orderId = order.id;
      },
      compensate: async (ctx) => {
        await orderService.cancel(ctx.orderId);
      },
    },
    {
      name: 'reserveInventory',
      execute: async (ctx) => {
        await inventoryService.reserve(ctx.items);
      },
      compensate: async (ctx) => {
        await inventoryService.release(ctx.items);
      },
    },
    {
      name: 'processPayment',
      execute: async (ctx) => {
        const payment = await paymentService.charge(ctx.userId, ctx.totalAmount);
        ctx.paymentId = payment.id;
      },
      compensate: async (ctx) => {
        await paymentService.refund(ctx.paymentId);
      },
    },
  ];

  async execute(context: OrderContext): Promise<void> {
    const completedSteps: SagaStep[] = [];

    for (const step of this.steps) {
      try {
        await step.execute(context);
        completedSteps.push(step);
      } catch (error) {
        console.error(`Saga step "${step.name}" failed, compensating...`);
        // 按反序执行补偿
        for (const completed of completedSteps.reverse()) {
          try {
            await completed.compensate(context);
          } catch (compError) {
            // 补偿失败：记录并告警，需要人工介入
            console.error(`Compensation "${completed.name}" failed!`, compError);
          }
        }
        throw new SagaFailedError(step.name, error);
      }
    }
  }
}
```

### 协调型 Saga（Choreography）

没有中心协调者，每个服务监听事件并决定下一步：

```
Optima 订单流程 - 协调型 Saga:

  commerce-backend                库存模块                    支付模块
       │                           │                          │
       │  1. OrderCreated 事件      │                          │
       │─────────────────────────→ │                          │
       │                           │  2. 扣减库存              │
       │                           │  3. InventoryReserved 事件 │
       │                           │─────────────────────────→ │
       │                           │                          │  4. 处理支付
       │                           │                          │  5. PaymentCompleted 事件
       │ ←────────────────────────────────────────────────────│
       │  6. 更新订单状态为 CONFIRMED │                          │
       │                           │                          │

如果支付失败:
       │                           │                          │
       │                           │                          │  PaymentFailed 事件
       │                           │ ←────────────────────────│
       │ ←─────────────────────────│  InventoryReleased 事件   │
       │  标记订单为 CANCELLED       │  恢复库存                │
```

### 编排 vs 协调的选择

```
┌─────────────────────┬──────────────────────┬──────────────────────┐
│                     │  编排型 Orchestration │  协调型 Choreography │
├─────────────────────┼──────────────────────┼──────────────────────┤
│ 流程可见性          │ ✅ 集中看到完整流程    │ ✗ 分散在各服务中      │
│ 耦合度              │ 编排器知道所有参与方   │ ✅ 服务间完全解耦      │
│ 单点故障            │ ✗ 编排器挂了全挂      │ ✅ 没有单点            │
│ 复杂流程            │ ✅ 容易处理复杂逻辑    │ ✗ 事件链条难以追踪     │
│ 新增步骤            │ 改编排器              │ 加一个事件监听者       │
│ 调试难度            │ ✅ 在编排器中看全貌    │ ✗ 需要追踪事件链       │
│ 适用场景            │ 3+ 步骤的复杂流程      │ 2-3 步的简单流程       │
└─────────────────────┴──────────────────────┴──────────────────────┘

Optima 建议:
  - 订单流程（创建→库存→支付→通知）→ 编排型（步骤多，需要清晰的流程控制）
  - MCP 工具调用（chat → mcp-host → 工具）→ 已经是编排型（mcp-host 就是编排器）
  - 简单通知（订单完成 → 发邮件）→ 协调型（一个事件一个消费者）
```

---

## 5. API Gateway 模式

### 为什么需要 API Gateway

```
没有 Gateway（当前 Optima 的方式）:

  客户端                                    后端服务
  ┌──────┐     ┌──────┐
  │ Web  │────→│ ALB  │──→ auth.stage.optima.onl  ──→ user-auth
  │      │     │      │──→ api.stage.optima.onl   ──→ commerce
  │      │     │      │──→ host.mcp.stage.optima.onl → mcp-host
  └──────┘     └──────┘──→ ai.stage.optima.onl    ──→ chat

  ALB 只做 L7 路由（按域名转发），不做:
  - 认证验证（每个服务自己验 JWT）
  - 限流（任何人可以无限调用）
  - 请求聚合（前端要调多个服务才能拼出一个页面）
  - 协议转换（全部是 HTTP）

有 Gateway:

  客户端      API Gateway                    后端服务
  ┌──────┐   ┌────────────────────┐
  │ Web  │──→│  ① 认证卸载（验JWT） │──→ user-auth（不用自己验）
  │      │   │  ② 限流（100 req/s） │──→ commerce（被保护）
  │      │   │  ③ 请求聚合          │──→ mcp-host
  │      │   │  ④ 协议转换          │──→ chat
  │      │   │  ⑤ 缓存/压缩        │
  └──────┘   └────────────────────┘
```

### Gateway 的核心能力

```
① 认证卸载（Auth Offloading）
  - Gateway 统一验证 JWT，通过后把 user_id 放到 header 转发
  - 后端服务不需要各自实现 JWT 验证逻辑
  - 好处: 认证逻辑集中管理，改一处生效全局

② 限流（Rate Limiting）
  - 按用户/IP/API Key 限制请求频率
  - 防止恶意用户或 bug 导致的请求风暴

③ 路由（Routing）
  - /api/v1/products/* → commerce-backend
  - /api/v1/chat/*     → agentic-chat
  - /api/v1/tools/*    → mcp-host

④ 请求聚合（Aggregation）
  - 前端一个请求 → Gateway 并行调用多个后端服务 → 合并结果返回
  - 减少前端需要发起的请求数量

⑤ 响应转换
  - 后端返回详细错误 → Gateway 脱敏后返回给客户端
  - 不同版本的客户端 → Gateway 做响应格式适配
```

### AWS 方案选型

```
┌─────────────────┬──────────────┬────────────────┬──────────────┐
│                 │   ALB        │  API Gateway   │   Kong       │
│                 │  (当前)       │  (AWS 托管)     │  (开源/企业)  │
├─────────────────┼──────────────┼────────────────┼──────────────┤
│ 定位            │ L7 负载均衡   │ API 管理平台    │ API 管理平台  │
│ 认证            │ ✗            │ ✅ JWT/Cognito │ ✅ 插件丰富   │
│ 限流            │ ✗            │ ✅ Usage Plans │ ✅ 细粒度      │
│ 请求转换        │ ✗            │ ✅ VTL 模板    │ ✅ Lua 脚本   │
│ WebSocket       │ ✅           │ ✅ 专门的 API  │ ✅            │
│ gRPC            │ ✅           │ ✅ HTTP/2      │ ✅            │
│ 延迟            │ ~1ms         │ ~10-30ms       │ ~2-5ms       │
│ 月费            │ ~$25         │ 按请求量        │ 自托管免费    │
│ 运维            │ 全托管        │ 全托管          │ 自己运维      │
├─────────────────┼──────────────┼────────────────┼──────────────┤
│ 适合场景        │ 简单路由      │ 公开 API、     │ 大规模、      │
│                 │ 内部服务      │ 需要管理和计量  │ 多团队、      │
│                 │              │               │ 需要高度定制  │
└─────────────────┴──────────────┴────────────────┴──────────────┘

Optima 路线:
  现在 → ALB（够用，成本低）
  当需要限流和认证卸载时 → ALB + API Gateway（ALB 做内部路由，API Gateway 做外部入口）
  当服务多到需要完整 API 管理时 → 评估 Kong 或继续 API Gateway
```

---

## 6. BFF 模式（Backend for Frontend）

### 为什么不同客户端需要不同的 API

```
问题场景:

  Web 端（桌面浏览器）:
    - 大屏幕，一页展示商品列表 + 推荐 + 分类 + 用户信息
    - 带宽充裕，可以接受较大的 JSON 响应
    - 需要: 一次性获取大量数据

  移动端（手机 App）:
    - 小屏幕，一页只展示商品卡片
    - 带宽可能有限（4G/弱 WiFi）
    - 需要: 最精简的数据，分页加载

  AI Agent 端（agentic-chat 的 API 消费者）:
    - 不需要 UI 数据，只要结构化结果
    - 需要: 工具调用结果、Session 状态

共用一套 API 的问题:
  GET /api/products/123 →
  {
    "id": 123,
    "name": "产品名",
    "description": "很长的描述...",        ← 移动端不需要
    "specifications": { ... },             ← 移动端不需要
    "related_products": [ ... ],           ← 移动端不需要
    "reviews": [ ... ],                    ← 移动端第一屏不需要
    "seo_metadata": { ... },               ← Agent 端不需要
    "price": 99.00,
    "images": [ ... 10张高清图 ... ]        ← 移动端只要缩略图
  }

  要么 over-fetching（移动端收到不需要的数据）
  要么 under-fetching（Web 端要调多次 API 才能凑齐数据）
```

### BFF 的架构

```
没有 BFF:
  ┌──────┐
  │ Web  │──────┐
  └──────┘      │
  ┌──────┐      │     ┌──────────────┐
  │ 移动  │──────┼────→│   通用 API    │──→ 后端服务
  └──────┘      │     └──────────────┘
  ┌──────┐      │
  │Agent │──────┘
  └──────┘

有 BFF:
  ┌──────┐     ┌──────────────┐
  │ Web  │────→│  Web BFF     │──┐
  └──────┘     │ 聚合 + 大响应  │  │
               └──────────────┘  │
  ┌──────┐     ┌──────────────┐  │     ┌──────────────┐
  │ 移动  │────→│ Mobile BFF   │──┼────→│   后端服务     │
  └──────┘     │ 精简 + 分页   │  │     │ user-auth    │
               └──────────────┘  │     │ commerce     │
  ┌──────┐     ┌──────────────┐  │     │ mcp-host     │
  │Agent │────→│ Agent BFF    │──┘     │ chat         │
  └──────┘     │ 结构化 + 流式  │       └──────────────┘
               └──────────────┘

每个 BFF 做:
  - 聚合: 并行调用多个后端服务，合并结果
  - 裁剪: 只返回该客户端需要的字段
  - 适配: 格式转换（Web 要 HTML-friendly，Agent 要工具结果）
```

**BFF 的代价**：

- 多了一层服务需要维护（但每个 BFF 很薄，逻辑简单）
- 可能的代码重复（不同 BFF 可能调用同样的后端 API）
- 团队所有权：理想情况下 BFF 由前端团队维护（谁用谁维护）

**Optima 的考虑**：

```
当前阶段不需要 BFF，因为:
  - 客户端类型少（主要是 Web + Agent）
  - 团队规模小，维护多个 BFF 不经济
  - API 还在快速迭代，拆 BFF 太早会增加改动成本

什么时候需要:
  - 有原生 App 且数据需求和 Web 差异大
  - 前端团队和后端团队分离，BFF 作为"前端的后端"
  - API 稳定后想优化客户端体验
```

---

## 7. Sidecar / Ambassador 模式

### Sidecar 模式

Sidecar 的思想：**把跨切面关注（日志、监控、重试、TLS）从业务代码中抽出来，放到一个伴随进程中**。

```
没有 Sidecar:
  ┌──────────────────────────────────┐
  │         user-auth                │
  │                                  │
  │  业务逻辑                        │
  │  + JWT 验证                      │
  │  + 日志收集（console.log → ???）  │  ← 每个服务重复实现
  │  + Metrics 上报                  │
  │  + 重试逻辑                      │
  │  + TLS 证书管理                  │
  │  + 链路追踪                      │
  └──────────────────────────────────┘

有 Sidecar:
  ┌──────────────────────┬──────────────────┐
  │     user-auth        │     Sidecar      │
  │                      │                  │
  │  纯业务逻辑           │  日志收集         │
  │  只关心认证、用户管理   │  Metrics 上报    │
  │                      │  mTLS            │
  │  localhost:8000 ←──→ │  重试/熔断        │
  │                      │  链路追踪         │
  └──────────────────────┴──────────────────┘
  ← 同一个 Pod / 同一个 ECS Task Definition →

  业务代码只发 HTTP 到 localhost，Sidecar 负责所有"管道工作"。
```

### Ambassador 模式

Ambassador 是 Sidecar 的一个特化：**代理出站连接**。

```
Ambassador 模式:

  ┌──────────────┐     ┌───────────────┐     ┌─────────────┐
  │  user-auth   │────→│  Ambassador   │────→│  外部服务    │
  │              │     │  (代理)        │     │  (Redis,    │
  │ 连接         │     │  - 连接池管理   │     │   RDS,      │
  │ localhost:   │     │  - 重试逻辑    │     │   第三方API) │
  │ 6379         │     │  - 熔断        │     │             │
  └──────────────┘     │  - TLS        │     └─────────────┘
                       └───────────────┘

  业务代码连接 localhost:6379（以为是本地 Redis），
  实际上 Ambassador 代理连接到真正的 ElastiCache Redis，
  并处理连接池、重试、TLS 等。
```

### Service Mesh — Sidecar 的规模化

```
Service Mesh（服务网格）就是把 Sidecar 模式标准化、规模化:

  ┌──────────────────────────────────────────┐
  │              Control Plane               │  ← 集中管理配置
  │  (Istio istiod / Linkerd control plane)  │
  └────────────────────┬─────────────────────┘
                       │ 下发配置
         ┌─────────────┼─────────────────┐
         ▼             ▼                 ▼
  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
  │ user-auth    │ │ commerce     │ │ chat         │
  │ ┌──────────┐ │ │ ┌──────────┐ │ │ ┌──────────┐ │
  │ │ Envoy    │ │ │ │ Envoy    │ │ │ │ Envoy    │ │  ← Data Plane
  │ │ Sidecar  │←──→│ │ Sidecar  │←──→│ │ Sidecar  │ │  (Sidecar 代理)
  │ └──────────┘ │ │ └──────────┘ │ │ └──────────┘ │
  └──────────────┘ └──────────────┘ └──────────────┘

  所有服务间通信都经过 Sidecar 代理:
  - mTLS 加密（零信任，不信任内网）
  - 自动重试/熔断
  - 流量可观测（延迟、错误率、调用链）
  - 灰度发布（1% 流量到新版本）
  - 故障注入（测试弹性）

Optima 现状:
  当前用 Cloud Map 内部 DNS 直连，没有 Service Mesh。
  现阶段不需要（服务数量少，运维复杂度收益比低）。

  什么时候考虑:
  - 服务数量 > 10 个
  - 需要 mTLS（零信任安全要求）
  - 需要细粒度的流量控制（灰度发布、A/B 测试）
  - 迁移到 Kubernetes 之后（ECS 上跑 Service Mesh 很不方便）
```

---

## 8. CAP 定理与 PACELC

### CAP 定理 — 不是简单的三选二

CAP 定理说的是：在网络分区（Partition）发生时，你只能选一致性（Consistency）或可用性（Availability）。

```
三个属性:
  C (Consistency)  — 所有节点在同一时刻看到相同的数据
  A (Availability) — 每个请求都能在合理时间内得到非错误的响应
  P (Partition Tolerance) — 节点之间的网络中断时系统仍能运作

常见误解:
  ✗ "CAP 是三选二，我们选 CP 或 AP"
  ✗ "选了 AP 就永远不要一致性"

正确理解:
  ✅ P 不是可选的 — 在分布式系统中网络分区一定会发生
  ✅ 真正的选择是: 当分区发生时，选 C 还是 A？
  ✅ 在没有分区时，可以同时有 C 和 A（正常情况）
  ✅ 这是一个光谱，不是二元选择
```

```
场景模拟:

  正常情况（无分区）— C 和 A 都有:
  ┌──────────┐     ┌──────────┐
  │  Node 1  │←───→│  Node 2  │   网络正常
  │ balance: │     │ balance: │   两个节点数据一致
  │  ¥100    │     │  ¥100    │   请求都能响应
  └──────────┘     └──────────┘

  网络分区发生:
  ┌──────────┐  ✗  ┌──────────┐
  │  Node 1  │     │  Node 2  │   Node 1 和 Node 2 无法通信
  │ balance: │     │ balance: │
  │  ¥100    │     │  ¥100    │
  └──────────┘     └──────────┘

  用户往 Node 1 存了 ¥50:

  选 CP（一致性优先）:                选 AP（可用性优先）:
  ┌──────────┐  ✗  ┌──────────┐    ┌──────────┐  ✗  ┌──────────┐
  │  Node 1  │     │  Node 2  │    │  Node 1  │     │  Node 2  │
  │ balance: │     │          │    │ balance: │     │ balance: │
  │  ¥150    │     │ 拒绝服务  │    │  ¥150    │     │  ¥100    │
  └──────────┘     └──────────┘    └──────────┘     └──────────┘
                                                     ← 数据不一致！
  Node 2 拒绝读写请求，               Node 2 继续服务，但返回旧数据。
  直到分区恢复才恢复服务。             分区恢复后需要合并冲突。
```

### PACELC — CAP 的实用扩展

PACELC 比 CAP 更贴近实际：

```
PACELC:
  If Partition → choose Availability or Consistency
  Else (正常运行时) → choose Latency or Consistency

  PA/EL — 分区时选可用性，正常时选低延迟   → DynamoDB, Cassandra
  PA/EC — 分区时选可用性，正常时选一致性   → 很少见
  PC/EL — 分区时选一致性，正常时选低延迟   → 很少见
  PC/EC — 分区时选一致性，正常时选一致性   → PostgreSQL, MySQL (同步复制)

Optima 的场景:

  用户余额（commerce-backend）:
    分区时 → 选 C（不能让用户余额不一致！）
    正常时 → 选 C（宁可慢一点也要保证准确）
    → PC/EC — 用 PostgreSQL 主从同步复制

  商品浏览量（commerce-backend）:
    分区时 → 选 A（浏览量不准几个没关系）
    正常时 → 选 L（展示要快）
    → PA/EL — 可以用 Redis 缓存，异步更新数据库

  AI 对话历史（agentic-chat）:
    分区时 → 选 A（用户能继续对话更重要）
    正常时 → 选 L（对话要流畅）
    → PA/EL — 本地写入成功就返回，异步复制
```

### 对架构决策的指导

```
不是所有数据都需要同样的一致性级别:

┌─────────────────────┬───────────────┬────────────────┐
│ 数据类型            │ 一致性需求     │ 推荐方案        │
├─────────────────────┼───────────────┼────────────────┤
│ 账户余额            │ 强一致         │ 数据库事务      │
│ 订单状态            │ 强一致         │ 数据库事务      │
│ 库存数量            │ 最终一致*      │ 预留 + 异步扣减 │
│ 用户 session        │ 最终一致       │ Redis + TTL    │
│ 商品浏览量/点赞      │ 最终一致       │ Redis → 批量写  │
│ 搜索索引            │ 最终一致       │ 异步同步到 ES   │
│ 推荐结果            │ 最终一致       │ 定时计算        │
└─────────────────────┴───────────────┴────────────────┘

* 库存: 用"预留"模式 — 下单时预留库存（强一致），
  支付成功后正式扣减（最终一致），超时未支付自动释放。
```

---

## 9. 幂等性设计

### 为什么需要幂等

```
网络不可靠，客户端可能重试:

  用户点击 "支付 ¥99"
       │
       ▼
  POST /api/payments  ──→ 服务端扣了 ¥99 ──→ 响应返回中
       │                                        │
       ✗ ← 网络超时，客户端没收到响应 ←────────────│
       │
  用户不确定是否成功，再次点击 "支付 ¥99"
       │
       ▼
  POST /api/payments  ──→ 服务端又扣了 ¥99 ← 灾难！扣了两次！

幂等的含义: 同一个操作执行一次和执行多次，效果相同。
  f(x) = f(f(x))

天然幂等的 HTTP 方法:
  GET    /api/users/123     — 读操作，天然幂等
  PUT    /api/users/123     — 用完整数据替换，天然幂等
  DELETE /api/users/123     — 删除，天然幂等（已删除的再删还是已删除）

不幂等的:
  POST   /api/payments      — 每次调用都可能产生新支付！
  PATCH  /api/users/123     — 增量更新，可能不幂等（如 balance += 10）
```

### 幂等键（Idempotency Key）

```
客户端生成唯一的幂等键，服务端据此去重:

  第一次请求:
  POST /api/payments
  Idempotency-Key: pay_abc123     ← 客户端生成的 UUID
  Body: { "amount": 99, "user_id": 456 }

  服务端:
  1. 查找 key "pay_abc123" → 不存在
  2. 处理支付 → 扣 ¥99
  3. 存储: idempotency_keys["pay_abc123"] = { status: "success", response: {...} }
  4. 返回 200 OK

  第二次请求（重试）:
  POST /api/payments
  Idempotency-Key: pay_abc123     ← 相同的 key
  Body: { "amount": 99, "user_id": 456 }

  服务端:
  1. 查找 key "pay_abc123" → 已存在，结果是 success
  2. 直接返回之前的响应，不重复执行
  3. 返回 200 OK（和第一次一模一样）
```

```typescript
// 幂等性中间件示例
async function idempotencyMiddleware(req: Request, res: Response, next: NextFunction) {
  const idempotencyKey = req.headers['idempotency-key'] as string;

  if (!idempotencyKey) {
    return next(); // 没有幂等键，正常处理
  }

  // 1. 查找已有结果
  const cached = await redis.get(`idempotency:${idempotencyKey}`);
  if (cached) {
    const { statusCode, body } = JSON.parse(cached);
    return res.status(statusCode).json(body);
  }

  // 2. 加锁防止并发执行（同一个 key 的并发请求）
  const lockAcquired = await redis.set(
    `idempotency-lock:${idempotencyKey}`,
    'locked',
    'NX',  // 只在不存在时设置
    'EX',  // 过期时间
    60     // 60 秒锁超时
  );

  if (!lockAcquired) {
    return res.status(409).json({ error: 'Request is being processed' });
  }

  // 3. 拦截响应，缓存结果
  const originalJson = res.json.bind(res);
  res.json = (body: unknown) => {
    // 缓存结果 24 小时
    redis.set(
      `idempotency:${idempotencyKey}`,
      JSON.stringify({ statusCode: res.statusCode, body }),
      'EX',
      86400
    );
    // 释放锁
    redis.del(`idempotency-lock:${idempotencyKey}`);
    return originalJson(body);
  };

  next();
}
```

### 去重策略

```
策略 1: 数据库唯一约束（最简单）

  CREATE TABLE payments (
    id SERIAL PRIMARY KEY,
    idempotency_key VARCHAR(64) UNIQUE,  ← 唯一约束
    amount DECIMAL(10, 2),
    status VARCHAR(20),
    created_at TIMESTAMP DEFAULT NOW()
  );

  -- 重复插入会报 unique violation，捕获异常即可
  INSERT INTO payments (idempotency_key, amount, status)
  VALUES ('pay_abc123', 99.00, 'pending');

策略 2: Redis 缓存（高性能）

  优点: 查询快，不增加数据库负担
  缺点: Redis 挂了或过期了，可能重复执行
  适用: 对极端情况可容忍的场景

策略 3: 数据库唯一约束 + Redis 缓存（双重保险）

  1. 先查 Redis（快路径）→ 有结果直接返回
  2. Redis 没有 → 查数据库 → 有结果放 Redis 并返回
  3. 都没有 → 执行业务逻辑 → 写数据库（唯一约束兜底）→ 写 Redis

  Optima 的支付系统建议用这种方案。
```

### 支付系统的幂等设计

```
Optima commerce-backend 的支付幂等方案:

  ┌───────────┐     ┌──────────────────────────────────────────────┐
  │  客户端    │     │              commerce-backend                │
  │           │     │                                              │
  │ 生成      │     │  ┌──────────┐   ┌──────────┐   ┌──────────┐ │
  │ 幂等键    │────→│  │ 1.Redis  │──→│ 2.数据库  │──→│ 3.支付   │ │
  │ pay_xxx   │     │  │ 查缓存   │   │ 查+插入   │   │ 网关调用  │ │
  │           │     │  └──────────┘   └──────────┘   └──────────┘ │
  └───────────┘     └──────────────────────────────────────────────┘

  完整流程:
  1. 客户端生成 Idempotency-Key（格式: pay_{orderId}_{timestamp}_{random}）
  2. 服务端收到请求:
     a. Redis GET idempotency:{key} → 命中？返回缓存结果
     b. Redis SETNX lock:{key} → 获取锁（防并发）
     c. 数据库 INSERT ... ON CONFLICT (idempotency_key) DO NOTHING
        → 如果已存在，查询已有记录返回
     d. 调用支付网关
     e. 更新数据库记录
     f. 设置 Redis 缓存
     g. 释放锁

  关键: 支付网关本身也必须支持幂等
  Stripe: 原生支持 Idempotency-Key header
  支付宝: 用 out_trade_no（商户订单号）去重
  微信支付: 用 out_trade_no 去重
```

---

## 10. 最终一致性

### 强一致 vs 最终一致

```
强一致性（Strong Consistency）:
  写入完成后，所有后续读取都能看到最新值。

  时间线:
  t1: 写入 balance = 150 → 成功
  t2: 读取 balance → 一定是 150（任何节点）

  代价: 延迟高（要等所有副本确认）、可用性低（副本不可达时拒绝服务）

最终一致性（Eventual Consistency）:
  写入完成后，如果没有更多写入，所有副本最终会收敛到同一个值。
  但在收敛之前，不同读取可能返回旧值。

  时间线:
  t1: 写入 balance = 150 → 成功（主节点）
  t2: 读取 balance → 可能是 100（从节点还没同步）
  t3: 读取 balance → 可能是 100（仍在同步中）
  t4: 读取 balance → 150（同步完成）

  "不一致窗口" 通常是毫秒到秒级。

  代价: 短暂的数据不一致、应用逻辑需要处理陈旧数据
```

### 一致性级别光谱

```
从强到弱:

  线性一致性（Linearizability）
    │  最强，所有操作按全局时间排序
    │  像只有一个副本一样
    │  代价: 延迟最高
    ▼
  顺序一致性（Sequential Consistency）
    │  所有操作按某个一致的顺序排列
    │  不一定是实际时间顺序
    ▼
  因果一致性（Causal Consistency）
    │  有因果关系的操作保持顺序
    │  无因果关系的操作可以乱序
    ▼
  读己之写一致性（Read Your Writes）
    │  用户能看到自己的最新写入
    │  不保证看到其他人的最新写入
    ▼
  单调读一致性（Monotonic Reads）
    │  不会读到比之前更旧的数据
    │  但可能读到旧数据
    ▼
  最终一致性（Eventual Consistency）
       最弱，只保证"最终"会一致
       不保证什么时候一致
```

### 读己之写一致性（Read Your Writes）

这是实践中最常需要的一致性保证：**用户修改了数据后，立即能看到自己的修改**。

```
问题场景:

  用户修改了头像:
  1. POST /api/profile/avatar → 写入主库 → 200 OK
  2. GET /api/profile → 读从库 → 返回旧头像！

  用户: "我明明改了，怎么还是旧的？刷新...还是旧的！Bug！"

解决方案:

  方案 1: 写后读主（简单粗暴）
    用户写入后的 N 秒内，该用户的读请求走主库。

    实现: 写入时在 session/cookie 中标记时间戳
    if (now - lastWriteTime < 10s) {
      readFromPrimary();  // 10 秒内读主库
    } else {
      readFromReplica();  // 10 秒后读从库
    }

  方案 2: 版本号比较
    响应中返回数据版本号，客户端记住最新版本号。
    如果读到的版本号比记住的旧，重试或等待。

  方案 3: 客户端乐观更新
    不等服务端确认，客户端直接展示新数据（乐观 UI）。
    如果服务端最终返回失败，再回滚 UI。

    React 伪代码:
    // 点击保存头像
    setAvatar(newAvatar);          // 1. 立即更新 UI
    try {
      await api.updateAvatar(newAvatar); // 2. 异步提交
    } catch {
      setAvatar(oldAvatar);        // 3. 失败回滚
      showError("保存失败");
    }
```

### Optima 场景的一致性选择

```
┌──────────────────────┬────────────────────┬───────────────────────┐
│ 场景                 │ 一致性选择          │ 实现方式              │
├──────────────────────┼────────────────────┼───────────────────────┤
│ 用户登录/注册        │ 强一致              │ 主库读写              │
│ (user-auth)         │                    │                       │
├──────────────────────┼────────────────────┼───────────────────────┤
│ 订单创建/支付        │ 强一致              │ 数据库事务            │
│ (commerce)          │                    │                       │
├──────────────────────┼────────────────────┼───────────────────────┤
│ 用户修改个人信息      │ 读己之写            │ 写后 10s 读主库       │
│ (user-auth)         │                    │                       │
├──────────────────────┼────────────────────┼───────────────────────┤
│ 商品列表/搜索        │ 最终一致（秒级）     │ Redis 缓存 + TTL     │
│ (commerce)          │                    │                       │
├──────────────────────┼────────────────────┼───────────────────────┤
│ AI 对话消息          │ 因果一致            │ 消息带序列号          │
│ (agentic-chat)      │                    │ 客户端按序渲染        │
├──────────────────────┼────────────────────┼───────────────────────┤
│ MCP 工具调用结果      │ 最终一致            │ 异步回调 + WebSocket  │
│ (mcp-host)          │                    │                       │
├──────────────────────┼────────────────────┼───────────────────────┤
│ 浏览量/点赞数        │ 最终一致（分钟级）   │ Redis 累加 → 批量写   │
│ (commerce)          │                    │                       │
└──────────────────────┴────────────────────┴───────────────────────┘
```

---

## 架构决策总结

```
Optima 架构的当前状态和演进路线:

  现在（合理的起点）:
  ┌──────────────────────────────────────────────┐
  │  客户端 → ALB → 4个核心服务（HTTP 同步调用）   │
  │                                              │
  │  服务发现: Cloud Map 内部 DNS                  │
  │  数据: 每服务独立数据库（PostgreSQL）           │
  │  缓存: 共享 Redis（Database 隔离）             │
  │  部署: ECS + Docker                           │
  └──────────────────────────────────────────────┘

  下一步（当出现明确需求时）:
  ┌──────────────────────────────────────────────┐
  │  ① 引入消息队列（SQS）                        │
  │    → MCP 工具调用异步化                        │
  │    → 订单事件 fan-out                          │
  │                                              │
  │  ② API Gateway 或应用层限流                    │
  │    → 当有外部 API 消费者时                      │
  │    → 当需要防恶意调用时                         │
  │                                              │
  │  ③ 关键流程 Saga 编排                          │
  │    → 订单创建 → 库存 → 支付 → 通知              │
  │    → 补偿事务保证一致性                         │
  │                                              │
  │  ④ 幂等性中间件                               │
  │    → 支付接口必须幂等                          │
  │    → 订单创建接口应该幂等                       │
  └──────────────────────────────────────────────┘

  未来（团队和业务规模增长后）:
  ┌──────────────────────────────────────────────┐
  │  ⑤ BFF 层（当有原生 App 时）                   │
  │  ⑥ CQRS（当读写性能需求分化时）                │
  │  ⑦ Service Mesh（迁移到 K8s 后）              │
  │  ⑧ Event Sourcing（金融审计需求时）            │
  └──────────────────────────────────────────────┘
```

核心原则：**不要为了用模式而用模式**。每个模式都有它的代价。在你的业务复杂度和团队规模还没有到那个阶段时，简单的方案就是最好的方案。YAGNI（You Ain't Gonna Need It）是每个架构师最需要的纪律。

---

## 推荐资料

### 经典书籍

| 书名 | 作者 | 为什么读 | 优先级 |
|------|------|---------|--------|
| **Designing Data-Intensive Applications (DDIA)** | Martin Kleppmann | 分布式系统原理圣经，本章每个主题的理论基础都在这本书里 | P0 |
| **Building Microservices** (2nd Ed) | Sam Newman | 微服务拆分、通信、部署的最佳实践，DDD 落地指南 | P0 |
| **Clean Architecture** | Robert C. Martin | 软件架构的通用原则，依赖反转、边界划分 | P1 |
| **Domain-Driven Design** | Eric Evans | DDD 的原书，限界上下文、聚合根等概念的出处 | P1（可先读精简版） |
| **Implementing DDD** | Vaughn Vernon | DDD 的实战指南，比 Evans 的原书更易读 | P1 |
| **Enterprise Integration Patterns** | Gregor Hohpe | 消息传递、事件驱动架构的模式百科 | P2 |
| **Release It!** (2nd Ed) | Michael T. Nygard | 生产环境的容错、稳定性、部署模式 | P2 |
| **Microservices Patterns** | Chris Richardson | Saga、CQRS、API Gateway 等模式的详细讲解 | P1 |

### System Design 面试资源

| 资源 | 类型 | 推荐理由 |
|------|------|---------|
| **ByteByteGo** (Alex Xu) | Newsletter + 书 | 图解系统设计，清晰直观，《System Design Interview》Vol.1 & Vol.2 |
| **systemdesign.one** | 网站 | 真实系统的架构案例分析 |
| **Grokking the System Design Interview** | 在线课程 | 经典系统设计面试题的逐步拆解 |
| **Martin Fowler 的博客** | 博客 | CQRS、Event Sourcing、Microservices 等模式的定义级文章 |
| **AWS Architecture Blog** | 博客 | 基于 AWS 的真实架构案例 |
| **InfoQ 架构频道** | 中文社区 | 中文世界质量最高的架构内容 |

### 实际案例推荐

| 案例 | 关键词 | 学习价值 |
|------|--------|---------|
| **Netflix 微服务架构演进** | API Gateway (Zuul)、Circuit Breaker (Hystrix)、Service Mesh | 大规模微服务的治理经验 |
| **Amazon 从单体到微服务** | 两个披萨团队、服务化拆分、最终一致性 | 康威定律的经典实践 |
| **Uber 的 Domain-Oriented 架构** | DDD 落地、限界上下文、平台化 | 从微服务到领域平台的演进 |
| **Stripe 的幂等性设计** | Idempotency Key、支付一致性 | 支付系统幂等设计的工业标准 |
| **Shopify 的事件驱动架构** | Event Sourcing、CQRS、Kafka | 电商平台的事件驱动转型 |
| **Wechat 的海量消息架构** | 因果一致性、消息序列号、异步处理 | 即时通讯的一致性方案 |

### 学习建议

```
推荐的阅读顺序:

  1. DDIA 第 1-4 章 — 数据模型和存储引擎基础
  2. Building Microservices 第 1-5 章 — 微服务拆分和通信
  3. DDIA 第 5-9 章 — 分布式系统核心（复制、分区、事务、一致性）
  4. Microservices Patterns — Saga、CQRS、API Gateway 细节
  5. ByteByteGo System Design Interview — 综合练习

每读完一章:
  - 回顾 Optima 的架构，想"这个概念在我们系统中对应什么？"
  - 画图：用 Mermaid 或手绘画出对应的架构图
  - 写 ADR（Architecture Decision Record）：记录一个你会做不同选择的决策
```

---

## 本章小结

```
核心认知升级:

  ✅ 微服务拆分不是越细越好 — 按限界上下文拆，用决策清单判断
  ✅ API 设计做到 REST Level 2 就够 — 把精力放在一致性和版本管理上
  ✅ 事件驱动不是替代同步 — 是补充，用在长任务和解耦场景
  ✅ Saga 是分布式事务的务实替代 — 编排型适合复杂流程
  ✅ API Gateway 是演进出来的 — 不是一开始就要上
  ✅ BFF 要看客户端差异 — 差异不大就不需要
  ✅ CAP 不是三选二 — 是分区时的 C vs A 选择
  ✅ 幂等是支付系统的生命线 — 幂等键 + 去重必须做
  ✅ 一致性是光谱不是二选一 — 不同数据用不同级别
  ✅ YAGNI 是架构师的纪律 — 不到需要时不引入复杂模式
```
