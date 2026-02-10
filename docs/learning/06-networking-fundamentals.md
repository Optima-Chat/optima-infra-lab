# 06 - 网络基础：从 HTTP 请求到负载均衡

> 每个 API 调用背后都是一连串精密协作的协议。理解它们，才能在出问题时知道该看哪一层。

---

## 我们现在在哪

当前 Optima 项目的网络架构：

```
✅ 做得好的:
  - ALB 统一入口，按域名路由到不同服务
  - HTTPS 全站加密（ACM 证书 + ALB 终止）
  - Route53 管理 optima.shop / optima.onl 两个域名
  - ECS Service Discovery（Cloud Map 内部 DNS）
  - WebSocket 支持（Session Gateway 长连接）

⚠️ 可以更好的:
  - 不清楚一个请求从浏览器到 ECS Task 经过了哪些环节
  - ALB Listener Rules 是"能跑就行"，不理解优先级和匹配逻辑
  - WebSocket 断线重连是试出来的，不理解协议层面发生了什么
  - 没有系统性的网络排查手段（出问题靠猜）
  - 没有 CDN（CloudFront），所有请求直达 ALB
```

**本文目标**: 把你每天都在用但未必理解的网络知识，从协议层面讲清楚。

---

## 1. TCP/IP 协议栈四层模型

### 一个请求的完整旅程

当用户访问 `https://api.optima.shop/products` 时，数据包经过四层协议栈：

```
┌─────────────────────────────────────────────────────────────┐
│  应用层 (Application Layer)                                  │
│  HTTP/2 请求: GET /products Host: api.optima.shop            │
│  + TLS 1.3 加密                                             │
├─────────────────────────────────────────────────────────────┤
│  传输层 (Transport Layer)                                    │
│  TCP 连接: 客户端:54321 → ALB:443                            │
│  三次握手 → 数据传输 → 四次挥手                                │
├─────────────────────────────────────────────────────────────┤
│  网络层 (Internet Layer)                                     │
│  IP 包: 客户端 IP → ALB 弹性 IP                               │
│  路由表决定下一跳                                              │
├─────────────────────────────────────────────────────────────┤
│  链路层 (Link Layer)                                         │
│  以太网帧: MAC 地址寻址                                       │
│  WiFi / 光纤 / 海底光缆                                      │
└─────────────────────────────────────────────────────────────┘
```

### 每一层在 Optima 中的体现

| 层 | 协议 | 在 Optima 中 | 出问题时的表现 |
|---|------|------------|--------------|
| 应用层 | HTTP/TLS | ALB 解析 Host header 路由到对应 Target Group | 404/502/503 错误 |
| 传输层 | TCP | ALB 与 ECS Task 之间的 TCP 连接、健康检查 | 连接超时、RST |
| 网络层 | IP | VPC 子网路由、安全组规则 | 网络不通、超时 |
| 链路层 | Ethernet | AWS 底层网络（透明，你无需关心） | 极少出问题 |

### TCP 三次握手

为什么是三次，不是两次？因为双方都需要确认对方的初始序列号。

```
客户端                                     ALB (443)
  │                                          │
  │──── SYN (seq=100) ──────────────────────→│  1. "我想建立连接，我的序列号从 100 开始"
  │                                          │
  │←─── SYN-ACK (seq=300, ack=101) ─────────│  2. "收到，我的序列号从 300 开始，期待你的 101"
  │                                          │
  │──── ACK (ack=301) ──────────────────────→│  3. "收到，期待你的 301"
  │                                          │
  │         连接建立，开始 TLS 握手             │
```

**为什么要关心这个？**

- ALB 的 `idle_timeout`（默认 60s）控制 TCP 连接空闲多久后断开
- ECS 健康检查的 `interval` 和 `timeout` 基于 TCP 连接行为
- WebSocket 心跳本质上是在防止 TCP 空闲超时

### TCP 四次挥手

```
客户端                                      服务端
  │                                          │
  │──── FIN ────────────────────────────────→│  1. "我发完了"
  │←─── ACK ─────────────────────────────────│  2. "知道了，我可能还有数据要发"
  │←─── FIN ─────────────────────────────────│  3. "我也发完了"
  │──── ACK ────────────────────────────────→│  4. "收到，连接关闭"
  │                                          │
  │    客户端进入 TIME_WAIT（等待 2MSL）        │
```

**Optima 场景**: ALB 的 `deregistration_delay`（默认 300s）就是给旧 ECS Task 时间完成挥手，让已有请求处理完毕，而不是粗暴地 RST 断开连接。

---

## 2. DNS 解析全过程

### 从域名到 IP

当浏览器访问 `auth.optima.shop` 时，DNS 解析过程：

```
浏览器                本地 DNS 缓存           运营商 DNS            根 DNS            .shop TLD DNS         Route53
  │                      │                    │                   │                    │                    │
  │─ auth.optima.shop? ─→│                    │                   │                    │                    │
  │                      │                    │                   │                    │                    │
  │  (缓存未命中)         │── 递归查询 ────────→│                   │                    │                    │
  │                      │                    │── .shop 在哪？ ──→│                    │                    │
  │                      │                    │←── 去问 x.nic.shop ──────────────────→│                    │
  │                      │                    │                   │                    │                    │
  │                      │                    │── optima.shop 在哪？ ─────────────────→│                    │
  │                      │                    │←── 去问 ns-xxx.awsdns-xx.com ─────────────────────────────→│
  │                      │                    │                   │                    │                    │
  │                      │                    │── auth.optima.shop 的 A 记录？ ────────────────────────────→│
  │                      │                    │←── A 记录: 13.215.xxx.xxx (ALB IP)  TTL=60 ───────────────│
  │                      │                    │                   │                    │                    │
  │←──── 13.215.xxx.xxx ────────────────────│                   │                    │                    │
```

### DNS 记录类型

| 类型 | 用途 | Optima 中的例子 |
|------|------|---------------|
| A | 域名 → IPv4 地址 | `auth.optima.shop` → ALB IP |
| AAAA | 域名 → IPv6 地址 | 暂未使用 |
| CNAME | 域名 → 另一个域名 | `auth.optima.shop` → `optima-prod-alb-xxx.ap-southeast-1.elb.amazonaws.com` |
| ALIAS/A+Alias | AWS 特有，类似 CNAME 但支持 Zone Apex | `optima.shop` → ALB（CNAME 不能用在裸域） |
| MX | 邮件服务器 | 邮件路由（如果有） |
| TXT | 文本信息 | SPF、域名验证 |
| NS | 域名服务器 | `optima.shop` → Route53 的 NS 服务器 |

### Route53 在 Optima 中的角色

```
Route53 Hosted Zone: optima.shop
├── auth.optima.shop      → ALIAS → optima-prod-alb (ALB)
├── api.optima.shop       → ALIAS → optima-prod-alb (ALB)
├── mcp.optima.shop       → ALIAS → optima-prod-alb (ALB)
├── ai.optima.shop        → ALIAS → optima-prod-alb (ALB)
└── ...

Route53 Hosted Zone: optima.onl
├── auth.stage.optima.onl → ALIAS → optima-prod-alb (ALB，同一个)
├── api.stage.optima.onl  → ALIAS → optima-prod-alb
└── ...
```

**关键点**: 所有域名都指向同一个 ALB。ALB 通过 HTTP Host header 区分请求应该转发到哪个 Target Group。DNS 只负责"找到 ALB 的 IP"，路由逻辑在 ALB 层完成。

### TTL 和缓存

```
TTL (Time To Live) = DNS 记录的缓存时间

TTL=60   → 每分钟重新解析一次。适合可能变化的记录（如 ALB IP）
TTL=3600 → 每小时解析一次。适合稳定的记录
TTL=86400 → 每天解析一次。适合几乎不变的记录（如 MX）

⚠️ 陷阱:
  - 降低 TTL 不是即时生效的，旧的高 TTL 缓存可能还在各级 DNS 中
  - 计划迁移前，应提前 24h 把 TTL 降到 60s
  - Route53 ALIAS 记录的 TTL 由 AWS 自动管理（通常 60s）
```

---

## 3. HTTP/1.1 vs HTTP/2 vs HTTP/3

### HTTP/1.1：一问一答

```
连接 1: GET /api/products       → 等待响应 → GET /api/cart       → 等待响应
连接 2: GET /static/style.css   → 等待响应 → GET /static/app.js  → 等待响应
连接 3: GET /images/logo.png    → 等待响应
连接 4: GET /images/banner.jpg  → 等待响应

问题:
  - 队头阻塞 (Head-of-Line Blocking): 前一个请求没返回，后一个只能等
  - 浏览器限制每个域名 6 个并发连接
  - 每个请求都带完整的 Header（重复的 Cookie、User-Agent 等）
```

### HTTP/2：多路复用

```
单个 TCP 连接上:
  Stream 1: GET /api/products    ──→ ←── 响应数据帧
  Stream 2: GET /api/cart        ──→ ←── 响应数据帧
  Stream 3: GET /static/style.css ─→ ←── 响应数据帧
  Stream 4: GET /images/logo.png ──→ ←── 响应数据帧

  所有 Stream 在同一个连接上交错传输，互不阻塞

改进:
  ✅ 多路复用: 一个连接上并行多个请求/响应
  ✅ Header 压缩 (HPACK): 只传差异部分
  ✅ 服务端推送: 主动推送客户端可能需要的资源
  ✅ 二进制分帧: 更高效的数据传输

⚠️ 仍有问题:
  - TCP 层的队头阻塞: 一个包丢失 → 所有 Stream 都等待重传
  - 这是 TCP 协议本身的限制
```

### HTTP/3：QUIC 革命

```
HTTP/3 = HTTP-over-QUIC（不再使用 TCP）

QUIC 基于 UDP，但在应用层实现了:
  - 可靠传输（类似 TCP 的确认和重传）
  - 拥塞控制
  - TLS 1.3（内置，不是分层的）
  - 独立的 Stream（互不影响）

┌─────────────────────┐     ┌─────────────────────┐
│      HTTP/2         │     │      HTTP/3         │
├─────────────────────┤     ├─────────────────────┤
│      TLS 1.2+       │     │      QUIC           │
├─────────────────────┤     │  (内置 TLS 1.3)      │
│      TCP            │     ├─────────────────────┤
├─────────────────────┤     │      UDP            │
│      IP             │     ├─────────────────────┤
└─────────────────────┘     │      IP             │
                            └─────────────────────┘

HTTP/3 优势:
  ✅ 无队头阻塞: Stream A 丢包不影响 Stream B
  ✅ 0-RTT 连接恢复: 之前连过的服务器，首次请求就能带数据
  ✅ 连接迁移: 切换 WiFi/4G 不会断连（基于 Connection ID，不是 IP+Port）
```

### 在 Optima 中的情况

```
客户端 → ALB: HTTP/2 (或 HTTP/1.1，取决于客户端)
ALB → ECS Task: HTTP/1.1 (ALB 的后端连接默认用 HTTP/1.1)

ALB 做了协议转换:
  - 前端（面向客户端）: 支持 HTTP/2
  - 后端（面向 ECS Task）: 降级到 HTTP/1.1

这意味着:
  - 客户端到 ALB 享受 HTTP/2 的多路复用
  - ALB 到 ECS Task 每个请求一个连接（但 ALB 有连接池优化）
  - 如果需要 ALB 到后端也用 HTTP/2，需要在 Target Group 中配置 protocolVersion
```

---

## 4. TLS/SSL 握手过程

### 为什么需要 TLS

```
没有 TLS:
  浏览器 ──── GET /api/login { password: "123456" } ──── ALB
                    ↑ 中间人可以看到明文

有 TLS:
  浏览器 ──── [加密的不可读数据] ──── ALB
                    ↑ 中间人看不懂
```

### TLS 1.3 握手（简化版）

```
客户端                                               ALB
  │                                                    │
  │──── ClientHello ──────────────────────────────────→│
  │     - 支持的密码套件列表                              │
  │     - 客户端随机数                                   │
  │     - SNI: api.optima.shop                         │
  │     - 支持的协议: h2, http/1.1 (ALPN)               │
  │                                                    │
  │←─── ServerHello + Certificate + Finished ──────────│
  │     - 选定的密码套件                                 │
  │     - 服务端随机数                                   │
  │     - 证书链: api.optima.shop → Amazon CA → Root CA │
  │     - 服务端密钥交换参数                              │
  │                                                    │
  │──── Finished ─────────────────────────────────────→│
  │     - 客户端密钥交换参数                              │
  │                                                    │
  │         双方计算出相同的会话密钥，开始加密通信            │
  │                                                    │
  │←───→ [加密的 HTTP/2 数据] ←───→                     │

TLS 1.3 只需 1-RTT（TLS 1.2 需要 2-RTT）
```

### 关键概念

**SNI (Server Name Indication)**:

```
一个 ALB 上托管多个域名:
  - auth.optima.shop
  - api.optima.shop
  - ai.optima.shop

客户端在 ClientHello 中发送 SNI，告诉 ALB "我要访问哪个域名"
ALB 根据 SNI 返回对应的证书

⚠️ SNI 是明文的（在加密建立之前发送）
   → ECH (Encrypted Client Hello) 解决这个问题，但还不普及
```

**ALPN (Application-Layer Protocol Negotiation)**:

```
客户端: "我支持 h2 和 http/1.1"
服务端: "那我们用 h2"

这样在 TLS 握手阶段就确定了应用层协议，不需要额外的升级协商
```

**证书链验证**:

```
服务端证书 (api.optima.shop)
  └── 签发者: Amazon RSA 2048 M03
       └── 签发者: Amazon Root CA 1
            └── 签发者: Starfield Services Root CA (浏览器内置信任)

验证过程:
  1. 浏览器拿到证书链
  2. 从叶子证书往上验证每一级签名
  3. 直到找到浏览器信任的根证书
  4. 检查证书是否过期、是否被吊销、域名是否匹配
```

### ACM 证书管理（Optima 实际使用）

```
AWS Certificate Manager (ACM):
  - 免费的公共 TLS 证书
  - 自动续期（不需要手动操作）
  - 直接关联到 ALB（证书不需要部署到 ECS Task 上）

Optima 的证书配置:
  ┌──────────────────────────────────────────┐
  │  ACM 证书: *.optima.shop                 │
  │  覆盖: auth.optima.shop                  │
  │        api.optima.shop                   │
  │        mcp.optima.shop 等                │
  ├──────────────────────────────────────────┤
  │  ACM 证书: *.optima.onl                  │
  │  覆盖: *.stage.optima.onl               │
  │        secrets.optima.onl 等             │
  └──────────────────────────────────────────┘

  两张通配符证书都绑定在同一个 ALB 的 HTTPS (443) Listener 上

HTTPS 终止 (TLS Termination):
  客户端 ──[HTTPS]──→ ALB ──[HTTP]──→ ECS Task
                       ↑
                  TLS 在这里解密
                  ECS Task 收到的是明文 HTTP

好处:
  - ECS Task 不需要管理证书
  - 集中管理 TLS，简化服务代码
  - ALB 硬件加速 TLS 处理，性能更好
```

---

## 5. 负载均衡深入

### L4 vs L7 负载均衡

```
L4 负载均衡 (NLB - Network Load Balancer):
  工作在传输层（TCP/UDP）
  只看 IP + 端口，不理解 HTTP
  性能极高，延迟极低

  适用场景:
  - 非 HTTP 协议（gRPC、数据库连接、游戏服务器）
  - 极致性能需求（百万级并发连接）
  - 需要保留客户端 IP（透传）

L7 负载均衡 (ALB - Application Load Balancer):
  工作在应用层（HTTP/HTTPS）
  理解 HTTP 请求内容（URL、Header、Cookie）
  可以做内容路由

  适用场景:
  - 基于域名/路径路由（Optima 的场景）
  - WebSocket 支持
  - HTTPS 终止
  - 需要请求级别的负载均衡

Optima 选择 ALB 的原因:
  - 需要按域名路由到不同服务
  - 需要 HTTPS 终止
  - 需要 WebSocket 支持
  - 请求量在 ALB 的能力范围内
```

### 负载均衡算法

```
1. 轮询 (Round Robin)
   请求 1 → Task A
   请求 2 → Task B
   请求 3 → Task C
   请求 4 → Task A  (循环)

   优点: 简单、均匀
   缺点: 不考虑各 Task 的负载差异
   适用: 无状态服务，各实例配置相同

2. 加权轮询 (Weighted Round Robin)
   Task A (权重 3): 请求 1, 2, 3
   Task B (权重 1): 请求 4
   Task C (权重 1): 请求 5

   适用: 实例配置不同（如新旧混合部署）

3. 最少连接 (Least Connections)
   Task A: 10 个活跃连接
   Task B: 3 个活跃连接  ← 新请求分配到这里
   Task C: 7 个活跃连接

   优点: 自动适应各 Task 的处理速度差异
   适用: 请求处理时间差异大的场景

4. 一致性哈希 (Consistent Hashing)
   hash(用户 ID) % N → 固定路由到某个 Task

   优点: 同一用户总是打到同一个实例（缓存友好）
   缺点: 实例增减时需要 rehash
   适用: 有状态场景（会话亲和、本地缓存）
```

**ALB 使用的算法**: 默认是轮询。ALB 还支持 Least Outstanding Requests（类似最少连接）。可在 Target Group 属性中配置。

### ALB Listener Rules 详解

ALB 的路由逻辑全靠 Listener Rules：

```
HTTPS:443 Listener
├── Rule 1 (优先级 10): Host = auth.optima.shop     → Target Group: user-auth-prod
├── Rule 2 (优先级 20): Host = api.optima.shop      → Target Group: commerce-backend-prod
├── Rule 3 (优先级 30): Host = mcp.optima.shop      → Target Group: mcp-host-prod
├── Rule 4 (优先级 40): Host = ai.optima.shop       → Target Group: agentic-chat-prod
├── Rule 5 (优先级 50): Host = auth.stage.optima.onl → Target Group: user-auth-stage
├── ...
└── Default Rule:                                    → 返回 404

每条 Rule 可以匹配:
  - Host header (域名)
  - Path (/api/*, /admin/*)
  - HTTP method (GET, POST)
  - Query string
  - Source IP
  - HTTP header

Action 类型:
  - Forward: 转发到 Target Group
  - Redirect: 301/302 重定向
  - Fixed Response: 直接返回固定内容（如 404 页面）
  - Authenticate: 集成 Cognito 或 OIDC
```

**Terraform 中的 ALB Rule 配置**:

```hcl
# infrastructure/optima-terraform 中的模式
resource "aws_lb_listener_rule" "user_auth" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  condition {
    host_header {
      values = ["auth.optima.shop"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.user_auth.arn
  }
}
```

### 健康检查

```
ALB 对每个 Target Group 做健康检查:

配置:
  - path: /health
  - interval: 30s          → 每 30 秒检查一次
  - timeout: 5s            → 5 秒没响应视为失败
  - healthy_threshold: 2   → 连续 2 次成功 → 标记健康
  - unhealthy_threshold: 3 → 连续 3 次失败 → 标记不健康

不健康的 Target:
  - ALB 停止向其发送新请求
  - ECS 可能触发 Task 重启（如果配置了 ECS 健康检查）

常见问题:
  ❌ 服务启动慢 → health_check_grace_period 设太短 → 服务还没起来就被判不健康
  ❌ /health 路径需要认证 → 健康检查被 401 拒绝 → 所有 Target 都不健康 → 502
  ❌ 健康检查太频繁 → 产生大量无意义的日志和负载
```

---

## 6. WebSocket 协议

### 为什么需要 WebSocket

```
HTTP 模型: 请求-响应（客户端主动，服务端被动）
  客户端: "有新消息吗？"  服务端: "没有"
  客户端: "有新消息吗？"  服务端: "没有"
  客户端: "有新消息吗？"  服务端: "有一条！"
  → 轮询 (Polling): 浪费带宽和服务器资源

WebSocket 模型: 双向实时通信
  客户端 ←→ 服务端 (全双工)
  服务端可以主动推送数据给客户端
  → 适合聊天、实时数据、AI 流式响应
```

### WebSocket 握手升级

WebSocket 连接从一个 HTTP 请求开始，然后"升级"为 WebSocket：

```
客户端 → 服务端:
  GET /ws/chat HTTP/1.1
  Host: ai.optima.shop
  Connection: Upgrade
  Upgrade: websocket
  Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
  Sec-WebSocket-Version: 13
  Sec-WebSocket-Protocol: chat

服务端 → 客户端:
  HTTP/1.1 101 Switching Protocols
  Connection: Upgrade
  Upgrade: websocket
  Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=

  ↓ 从这里开始，不再是 HTTP，而是 WebSocket 帧协议 ↓

客户端 ←→ 服务端: WebSocket 帧 (二进制)
```

### WebSocket 帧格式

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-------+-+-------------+-------------------------------+
|F|R|R|R| opcode|M| Payload len |    Extended payload length    |
|I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
|N|V|V|V|       |S|             |                               |
| |1|2|3|       |K|             |                               |
+-+-+-+-+-------+-+-------------+-------------------------------+

opcode:
  0x1 = Text (JSON 消息)
  0x2 = Binary
  0x8 = Close
  0x9 = Ping
  0xA = Pong
```

### 心跳机制

```
为什么需要心跳:
  1. TCP keepalive 间隔太长（默认 2 小时），中间设备可能已经断开连接
  2. NAT 网关、防火墙会清理空闲连接（通常 5-10 分钟）
  3. ALB idle_timeout 默认 60 秒
  4. 客户端需要知道连接是否还活着

Session Gateway 的心跳设计:

  客户端                    Session Gateway
    │                            │
    │──── ping (每 30s) ────────→│
    │←─── pong ──────────────────│
    │                            │
    │   (如果 60s 没收到 pong)     │
    │   → 判定连接断开             │
    │   → 触发重连逻辑             │

ALB 配置要点:
  - idle_timeout 必须 > 心跳间隔
  - 如果心跳 30s，idle_timeout 至少 60s
  - ALB 原生支持 WebSocket，不需要额外配置
    （只要 HTTP Upgrade 请求能到达后端，ALB 就会保持连接）
```

### 断线重连

```
断线原因:
  1. 网络切换（WiFi → 4G）
  2. ALB idle timeout
  3. ECS Task 重启（部署更新）
  4. 服务端主动关闭（资源清理）

重连策略 (Exponential Backoff + Jitter):

  第 1 次重连: 等 1s + random(0-500ms)
  第 2 次重连: 等 2s + random(0-500ms)
  第 3 次重连: 等 4s + random(0-500ms)
  第 4 次重连: 等 8s + random(0-500ms)
  ...
  最大等待: 30s

  ⚠️ 为什么要 Jitter (随机偏移)?
  → 防止"惊群效应": 服务重启后所有客户端同时重连，瞬间打满

代码示例:

  function reconnect(attempt: number) {
    const baseDelay = Math.min(1000 * Math.pow(2, attempt), 30000);
    const jitter = Math.random() * 500;
    setTimeout(() => {
      ws = new WebSocket(url);
      ws.onopen = () => { attempt = 0; }; // 重置计数
      ws.onclose = () => { reconnect(attempt + 1); };
    }, baseDelay + jitter);
  }
```

### ALB 对 WebSocket 的特殊处理

```
ALB 处理 WebSocket 的关键行为:

1. 升级请求: ALB 将 Upgrade 请求转发到 Target，之后保持 TCP 连接
2. 粘性: WebSocket 连接天然是粘性的（升级后一直连到同一个 Target）
3. idle_timeout: 只计算没有数据帧的时间（ping/pong 也算数据帧）
4. 部署更新:
   - 新请求/新连接 → 走新 Task
   - 已有 WebSocket 连接 → 继续在旧 Task 上
   - deregistration_delay 期间旧 Task 不接受新连接
   - 到期后强制断开（客户端应重连到新 Task）

Optima 的 Session Gateway:
  - 部署时现有的 AI 对话不会中断
  - 旧连接自然结束后，新连接自动路由到新 Task
  - 如果需要强制迁移，服务端发送 Close 帧 + 客户端自动重连
```

---

## 7. CDN 原理

### 为什么需要 CDN

```
没有 CDN:
  新加坡用户 ──(2ms)──→ ALB (ap-southeast-1)  ✅ 快
  北美用户 ──(200ms)──→ ALB (ap-southeast-1)   ❌ 慢（跨太平洋）
  欧洲用户 ──(300ms)──→ ALB (ap-southeast-1)   ❌ 更慢

有 CDN (CloudFront):
  新加坡用户 ──(2ms)──→ SIN 边缘节点 ──(缓存命中)──→ 直接返回
  北美用户 ──(5ms)──→ IAD 边缘节点 ──(缓存命中)──→ 直接返回
  欧洲用户 ──(5ms)──→ FRA 边缘节点 ──(缓存命中)──→ 直接返回

  缓存未命中时: 边缘节点 → Origin (ALB) → 缓存 → 返回
```

### CloudFront 架构

```
用户 → DNS (CNAME → xxx.cloudfront.net)
     → 最近的 Edge Location (全球 400+)
     → 缓存命中? → 直接返回
     → 缓存未命中 → Regional Edge Cache (区域缓存，减少回源)
                  → 缓存命中? → 返回并缓存到 Edge
                  → 缓存未命中 → Origin (ALB / S3)
                               → 返回并缓存到各级

Origin Shield (可选，进一步减少回源):
  所有 Edge → Origin Shield (单一缓存层) → Origin
  好处: Origin 只收到一次请求，即使全球 100 个 Edge 同时请求
```

### 缓存策略

```
什么该缓存:
  ✅ 静态资源: JS/CSS/图片/字体 (Cache-Control: max-age=31536000)
  ✅ 公共 API 响应: 商品列表 (Cache-Control: max-age=60)
  ✅ API 文档页面

什么不该缓存:
  ❌ 用户特定数据: /api/me, /api/cart
  ❌ 认证相关: /api/login, /api/token
  ❌ WebSocket 连接
  ❌ 包含 Set-Cookie 的响应

缓存键 (Cache Key):
  默认: URL (Host + Path + Query String)
  可自定义: 加入特定 Header、Cookie

  例: GET /api/products?page=1&lang=zh
  缓存键: api.optima.shop/api/products?lang=zh&page=1

失效策略:
  1. TTL 过期: 最常用，设置合理的 max-age
  2. 主动失效: CloudFront Invalidation (发布新版时清除旧缓存)
  3. 版本化 URL: style.abc123.css (文件内容变 → URL 变 → 自动用新缓存)
```

### 对 Optima 的建议

```
短期可以加 CDN 的:
  1. optima-store (Next.js) 的静态资源 → CloudFront + S3
  2. 商品图片 → CloudFront + S3 (optima-prod-commerce-assets)

暂时不需要 CDN 的:
  1. API 请求（动态数据，缓存收益低）
  2. WebSocket（不可缓存）
  3. 管理后台（用户少，不需要全球加速）
```

---

## 8. 网络排查工具

### curl 调试

最常用的 HTTP 调试工具：

```bash
# 基本请求
curl https://auth.optima.shop/health

# 看完整的请求/响应头
curl -v https://auth.optima.shop/health

# 看时间分布（DNS / TCP / TLS / 首字节）
curl -w "\
    DNS解析:  %{time_namelookup}s\n\
    TCP连接:  %{time_connect}s\n\
    TLS握手:  %{time_appconnect}s\n\
    首字节:   %{time_starttransfer}s\n\
    总时间:   %{time_total}s\n\
    HTTP状态: %{http_code}\n" \
  -o /dev/null -s https://api.optima.shop/health

# 输出示例:
#   DNS解析:  0.012s
#   TCP连接:  0.045s    (TCP 握手耗时 = 0.045 - 0.012 = 0.033s)
#   TLS握手:  0.120s    (TLS 握手耗时 = 0.120 - 0.045 = 0.075s)
#   首字节:   0.250s    (服务端处理时间 = 0.250 - 0.120 = 0.130s)
#   总时间:   0.260s

# 指定 HTTP 版本
curl --http2 -v https://api.optima.shop/health
curl --http1.1 -v https://api.optima.shop/health

# 测试 WebSocket 升级
curl -v -H "Connection: Upgrade" \
     -H "Upgrade: websocket" \
     -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
     -H "Sec-WebSocket-Version: 13" \
     https://ai.optima.shop/ws
```

### DNS 查询工具

```bash
# nslookup - 简单查询
nslookup auth.optima.shop
# 输出: Non-authoritative answer: auth.optima.shop → 13.215.x.x

# dig - 详细查询（推荐）
dig auth.optima.shop

# 查看完整解析链
dig +trace auth.optima.shop

# 查特定记录类型
dig auth.optima.shop A        # IPv4
dig auth.optima.shop AAAA     # IPv6
dig auth.optima.shop CNAME    # 别名
dig optima.shop NS            # 域名服务器
dig optima.shop MX            # 邮件服务器

# 查 TTL
dig auth.optima.shop | grep -A1 "ANSWER SECTION"
# auth.optima.shop.    60    IN    A    13.215.x.x
#                      ^^ TTL = 60秒

# 指定 DNS 服务器查询
dig @8.8.8.8 auth.optima.shop       # 用 Google DNS
dig @1.1.1.1 auth.optima.shop       # 用 Cloudflare DNS

# 检查 Route53 是否生效
dig @ns-xxx.awsdns-xx.com auth.optima.shop  # 直接问权威 DNS
```

### tcpdump - 抓包分析

```bash
# 抓取到某个 IP 的所有包
sudo tcpdump -i eth0 host 13.215.x.x

# 只看 TCP 握手 (SYN/SYN-ACK/ACK)
sudo tcpdump -i eth0 'tcp[tcpflags] & (tcp-syn|tcp-ack) != 0' -n

# 抓取某个端口
sudo tcpdump -i eth0 port 443

# 保存到文件（用 Wireshark 分析）
sudo tcpdump -i eth0 -w /tmp/capture.pcap host api.optima.shop

# 在 ECS Task 中抓包（需要 exec 进容器）
# 通常不需要，用 ALB access log 替代
```

### MTR - 路由追踪

```bash
# 综合 traceroute + ping 的工具
mtr api.optima.shop

# 输出示例:
#  Host                    Loss%  Snt   Last   Avg  Best  Wrst
#  1. 192.168.1.1           0.0%   10    1.2   1.5   0.8   3.2
#  2. 10.0.0.1              0.0%   10    5.3   5.1   4.8   6.2
#  3. 203.0.113.1           0.0%   10   12.4  12.8  11.2  15.3
#  ...
# 10. 13.215.x.x            0.0%   10   45.2  44.8  43.1  48.7

# 看什么:
#   - Loss% > 0: 某一跳有丢包，可能是网络问题
#   - Avg 突然跳高: 某一跳延迟大，可能是国际链路
#   - 最后一跳的 Avg: 整体延迟
```

### 常见排查场景

```
场景 1: 502 Bad Gateway
  可能原因:
  ├── ALB → Target 连接失败（Task 没启动 / 端口错误 / 安全组阻拦）
  ├── Target 返回了非法 HTTP 响应
  └── Target 健康检查全挂了

  排查步骤:
  1. aws elbv2 describe-target-health → 看 Target 健康状态
  2. ALB access log → 看 target_processing_time 是否为 -1
  3. ECS Task 日志 → 看服务是否正常运行

场景 2: 504 Gateway Timeout
  可能原因:
  ├── Target 处理时间超过 ALB idle_timeout
  ├── 后端服务卡住（数据库慢查询、外部 API 超时）
  └── TCP 连接建立超时（安全组/NACL 阻拦）

  排查步骤:
  1. curl -w 查看时间分布，确认卡在哪个阶段
  2. ECS Task 日志 → 看请求处理时间
  3. 如果是特定请求 → 看数据库慢查询日志

场景 3: WebSocket 频繁断开
  可能原因:
  ├── ALB idle_timeout < 心跳间隔
  ├── 客户端网络不稳定
  ├── ECS Task 被替换（滚动更新）
  └── 服务端内存不足导致进程重启

  排查步骤:
  1. 对比 ALB idle_timeout 和心跳间隔
  2. 客户端日志 → close code 和 reason
  3. ECS 事件 → 是否有 Task 被替换

场景 4: DNS 解析不到 / 解析到旧 IP
  排查步骤:
  1. dig +trace auth.optima.shop → 看解析链哪个环节出问题
  2. dig @8.8.8.8 vs dig @ns-xxx.awsdns → 对比公共 DNS 和权威 DNS
  3. 如果权威 DNS 正确但公共 DNS 不对 → 等 TTL 过期，或者降低 TTL 后重新配置
```

---

## 串起来：一个完整请求的旅程

把上面所有知识串起来，看一个真实请求在 Optima 中的完整路径：

```
用户在浏览器输入 https://api.optima.shop/products

1. DNS 解析
   浏览器 → DNS 缓存 → 运营商 DNS → Route53
   → 得到 ALB IP: 13.215.x.x

2. TCP 三次握手
   浏览器:54321 → SYN → ALB:443
   ALB → SYN-ACK → 浏览器
   浏览器 → ACK → ALB

3. TLS 1.3 握手 (1-RTT)
   浏览器 → ClientHello (SNI: api.optima.shop, ALPN: h2)
   ALB → ServerHello + 证书 (*.optima.shop, ACM 签发) + Finished
   浏览器验证证书链 → 计算会话密钥 → Finished

4. HTTP/2 请求
   浏览器 → HEADERS 帧: GET /products Host: api.optima.shop
   (在已加密的连接上)

5. ALB 路由
   ALB 检查 Listener Rules:
     Host = api.optima.shop → 匹配 Rule: forward to commerce-backend-prod TG

   ALB 选择 Target:
     轮询 → commerce-backend Task (10.0.1.x:8200)

6. ALB → ECS Task
   ALB → HTTP/1.1 GET /products → Task:8200 (TLS 已终止，内部用明文)
   (ALB 添加 X-Forwarded-For, X-Forwarded-Proto 头)

7. 应用处理
   Express/Fastify → 路由 → 查数据库 → JSON 响应

8. 响应返回
   Task → HTTP 200 [{...}] → ALB → HTTP/2 DATA 帧 → 浏览器
   (ALB 可能压缩响应，添加安全头)

9. 浏览器渲染
   解析 JSON → 渲染商品列表

总时间: ~200-500ms (取决于用户位置和数据库查询)
```

---

## 推荐资源

### 经典书籍

| 书名 | 作者 | 说明 |
|------|------|------|
| **TCP/IP Illustrated, Vol. 1** (《TCP/IP 详解 卷1》) | W. Richard Stevens | TCP/IP 协议族的圣经，图文并茂。重点读 TCP 和 HTTP 章节 |
| **HTTP: The Definitive Guide** (《HTTP 权威指南》) | David Gourley | HTTP 协议全面参考。不需要从头读，当工具书查 |
| **High Performance Browser Networking** | Ilya Grigorik | 浏览器网络性能优化。涵盖 TCP/TLS/HTTP2/WebSocket，强烈推荐 |
| **Computer Networking: A Top-Down Approach** (《计算机网络：自顶向下方法》) | Kurose & Ross | 网络入门教材。如果对协议栈感到陌生，从这本开始 |

### 在线资源

| 资源 | 类型 | 说明 |
|------|------|------|
| [High Performance Browser Networking](https://hpbn.co/) | 在线书 | Ilya Grigorik 的书免费在线版，覆盖 HTTP/2、WebSocket、TLS |
| [How DNS Works](https://howdns.works/) | 漫画 | 用漫画解释 DNS 解析过程，10 分钟读完 |
| [Cloudflare Learning Center](https://www.cloudflare.com/learning/) | 文档 | Cloudflare 的科普系列，覆盖 DNS/CDN/TLS/DDoS，写得非常好 |
| [HTTP/3 Explained](https://http3-explained.haxx.se/) | 在线书 | curl 作者写的 HTTP/3 和 QUIC 入门 |
| [AWS ALB 文档](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/) | 文档 | ALB 的官方文档，重点看 Listener Rules 和 Target Groups |
| [Julia Evans 的 Networking Zines](https://wizardzines.com/) | 图解 | 用手绘漫画解释网络概念，直观有趣 |

### 实践练习

| 练习 | 预计时间 | 学到什么 |
|------|---------|---------|
| 用 `curl -w` 测量 Optima 各服务的响应时间分布 | 30min | DNS/TCP/TLS/应用处理各环节耗时 |
| 用 `dig +trace` 追踪 `auth.optima.shop` 的完整 DNS 解析链 | 15min | DNS 递归查询和缓存 |
| 在浏览器 DevTools → Network 中观察 HTTP/2 多路复用 | 20min | 连接复用、帧交错 |
| 用 `wscat` 或 Node.js 脚本手动建立 WebSocket 连接并发心跳 | 30min | WebSocket 握手升级、帧收发 |
| 修改 ALB idle_timeout，观察 WebSocket 断开行为 | 30min | TCP 空闲超时机制 |
| 在 ALB access log 中分析一个 502 错误的原因 | 30min | ALB 日志字段含义、Target 状态判断 |
| 用 `openssl s_client` 查看 Optima 的证书链 | 15min | TLS 证书验证过程 |

```bash
# 查看证书链的命令
openssl s_client -connect api.optima.shop:443 -servername api.optima.shop < /dev/null 2>/dev/null | openssl x509 -text -noout | grep -E "Issuer|Subject|Not Before|Not After"
```
