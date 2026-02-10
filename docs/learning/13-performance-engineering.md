# 13 - 性能工程

> 从"感觉慢"到数据驱动的优化

---

## 我们现在在哪

```
用户反馈："AI 回复好慢啊"
开发者："是慢了一点…… 我优化一下"

问题在于：
  - 慢在哪？是 API 调用慢、数据库查询慢、还是前端渲染慢？
  - 慢了多少？P50 500ms 还是 P99 5s？
  - 优化后快了多少？没有基线就没有对比
```

Optima 项目中的真实场景：

| 服务 | 潜在瓶颈 | 当前状况 |
|------|---------|---------|
| user-auth | JWT 验证、用户查询 | 没测过延迟分布 |
| commerce-backend | 商品列表查询、库存扣减 | 复杂 SQL 可能有 N+1 |
| mcp-host | 多 MCP 工具编排 | 多次 HTTP 转发叠加 |
| agentic-chat | LLM API 调用 | 外部依赖延迟高但不可控 |
| 共享 RDS | 连接池竞争 | 多服务共享一个 PostgreSQL |
| 共享 Redis | 缓存命中率未知 | Database 0-3 隔离但无监控 |

性能工程不是"感觉慢就加缓存"，而是：**测量 → 定位 → 优化 → 验证**。

---

## 第一部分：性能分析方法论

### USE Method

Brendan Gregg 提出的 **USE Method**，适用于分析**基础设施资源**（CPU、内存、磁盘、网络）：

- **U**tilization（利用率）: 资源忙碌的时间比例
- **S**aturation（饱和度）: 排队等待资源的工作量
- **E**rrors（错误）: 资源错误事件数

```
对 Optima ECS 容器（user-auth 配置 256MB / 0.25vCPU）:

┌──────────┬─────────────────────────┬────────────────────────────┬────────────────────┐
│ 资源     │ Utilization             │ Saturation                 │ Errors             │
├──────────┼─────────────────────────┼────────────────────────────┼────────────────────┤
│ CPU      │ ECS CPUUtilization      │ 运行队列长度 > vCPU 数     │ -                  │
│ 内存     │ ECS MemoryUtilization   │ OOM Kill 次数              │ OOM 事件           │
│ 网络     │ NetworkIn/Out           │ TCP 重传率                  │ 连接拒绝数         │
│ 磁盘 I/O │ EBS ReadOps/WriteOps    │ I/O await 时间              │ EBS 错误           │
│ 连接池   │ 活跃连接 / 最大连接      │ 等待获取连接的请求数         │ 连接超时           │
└──────────┴─────────────────────────┴────────────────────────────┴────────────────────┘
```

**关键洞察**: user-auth 容器只有 256MB 内存和 0.25 vCPU。如果 Utilization 经常超过 70%，Service Auto Scaling 会扩容——但你要先知道这个数据。

### RED Method

Tom Wilkie 提出的 **RED Method**，适用于分析**面向用户的服务**：

- **R**ate（速率）: 每秒请求数
- **E**rrors（错误）: 每秒失败请求数
- **D**uration（延迟）: 请求耗时分布

```
对 Optima 核心 API:

┌──────────────────────────┬────────────────┬──────────────┬───────────────────┐
│ 端点                      │ Rate (req/s)  │ Error Rate   │ Duration (P99)    │
├──────────────────────────┼────────────────┼──────────────┼───────────────────┤
│ POST /auth/login         │ ?              │ ?            │ ?                 │
│ GET  /products           │ ?              │ ?            │ ?                 │
│ POST /chat/messages      │ ?              │ ?            │ ?                 │
│ POST /mcp/invoke         │ ?              │ ?            │ ?                 │
└──────────────────────────┴────────────────┴──────────────┴───────────────────┘

（全是问号——因为我们还没有 Metrics 收集）
```

### 四大黄金指标（Google SRE）

Google SRE Book 定义的四大黄金指标，与 RED/USE 有重叠但更全面：

1. **Latency（延迟）**: 成功请求和失败请求分开统计。失败请求可能很快返回（500），拉低平均延迟造成假象
2. **Traffic（流量）**: 系统的需求量。HTTP 请求/秒，WebSocket 消息/秒
3. **Errors（错误率）**: 失败请求的比例。包括显式失败（5xx）和隐式失败（200 但内容错误）
4. **Saturation（饱和度）**: 系统"多满了"。最先达到上限的资源就是瓶颈

```
三种方法论的关系:

USE Method ──→ 基础设施视角（CPU、内存、磁盘、网络）
RED Method ──→ 服务视角（Rate、Error、Duration）
四大黄金指标 ──→ 综合视角（合并了两者 + 加了 Saturation）

实际使用: 先用 RED 看服务表现 → 用 USE 定位资源瓶颈 → 用黄金指标做 SLO 告警
```

---

## 第二部分：CPU 性能分析

### 火焰图（Flame Graph）

火焰图由 Brendan Gregg 发明，用于可视化 CPU 时间花费在哪些函数调用栈上。

```
原理:

1. 采样: 每秒中断程序 N 次（如 99 次），记录当时的调用栈
2. 聚合: 统计每个调用栈出现的次数
3. 可视化: x 轴是函数名（按字母排序），y 轴是调用深度，宽度是采样占比

┌──────────────────────────────────────────────────────┐
│                      root                            │
├─────────────────────────┬────────────────────────────┤
│    handleRequest (60%)  │     eventLoop (40%)        │
├──────────┬──────────────┤                            │
│ dbQuery  │ serialize    │                            │
│  (35%)   │   (25%)      │                            │
├──────────┤              │                            │
│ pgClient │              │                            │
│  (30%)   │              │                            │
└──────────┴──────────────┴────────────────────────────┘

看到 pgClient 占了 30% → 数据库查询是 CPU 瓶颈
```

**关键理解**: 火焰图上宽的函数 ≠ 该函数本身慢，而是该函数（含子调用）占的总采样时间多。

### perf 工具基础（Linux）

`perf` 是 Linux 内核自带的性能分析工具：

```bash
# 记录 CPU 采样（对 PID 为 1234 的进程采样 30 秒）
perf record -F 99 -p 1234 -g -- sleep 30

# 查看报告
perf report

# 生成火焰图（需要 brendangregg/FlameGraph 工具）
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
```

**在 ECS 容器中**: 容器里通常没有 `perf`，但可以用 Node.js 自带的 profiler。

### Node.js CPU Profiling

**方法 1: --prof（V8 内置 profiler）**

```bash
# 启动时开启 profiling
node --prof app.js

# 停止后生成 isolate-xxx.log
# 解析日志
node --prof-process isolate-0x*.log > profile.txt
```

```
输出示例:

[Summary]:
   ticks  total  nonlib   name
    523   52.3%   58.7%  JavaScript
    234   23.4%   26.3%  C++
    134   13.4%   15.0%  GC              ← GC 占了 13%，需要关注
     99    9.9%          Shared libraries

[JavaScript]:
   ticks  total  nonlib   name
    189   18.9%   21.2%  JSON.parse       ← JSON 解析是热点
     87    8.7%    9.8%  pbkdf2           ← 密码哈希（预期的）
     56    5.6%    6.3%  RegExp           ← 正则表达式
```

**方法 2: --inspect（Chrome DevTools 连接）**

```bash
# 启动带调试端口的服务
node --inspect=0.0.0.0:9229 app.js

# 然后在 Chrome 打开 chrome://inspect
# → 点击 inspect → Performance 标签 → 录制 → 做一些操作 → 停止
# 可以看到火焰图、函数耗时、GC 暂停等
```

**方法 3: 编程式 profiling（生产环境推荐）**

```typescript
import { Session } from 'inspector';
import { writeFileSync } from 'fs';

async function cpuProfile(durationMs: number): Promise<void> {
  const session = new Session();
  session.connect();

  session.post('Profiler.enable');
  session.post('Profiler.start');

  await new Promise(resolve => setTimeout(resolve, durationMs));

  session.post('Profiler.stop', (err, { profile }) => {
    writeFileSync(
      `/tmp/cpu-profile-${Date.now()}.cpuprofile`,
      JSON.stringify(profile)
    );
    // 可上传到 S3，在 Chrome DevTools 中加载
  });
}

// 注册一个 API 端点用于按需触发（仅限内部访问）
// GET /debug/cpu-profile?duration=10000
```

**对 Optima 的建议**: 每个核心服务加一个 `/debug/cpu-profile` 端点（仅内网可访问），排查时按需触发，避免一直开着的性能开销。

---

## 第三部分：内存分析

### 内存泄漏检测

内存泄漏在 Node.js 中常见于以下场景：

```
常见泄漏模式:

1. 事件监听器未移除
   emitter.on('data', handler)   // 注册
   // 忘记 emitter.off('data', handler) 或 emitter.removeAllListeners()

2. 闭包引用大对象
   function processRequest(req) {
     const bigData = loadBigData();  // 10MB
     return () => bigData.length;    // 闭包持有 bigData 引用
   }

3. 全局 Map/Set 无限增长
   const sessionCache = new Map();   // 只 set 不 delete
   sessionCache.set(sessionId, data); // session 结束后没清理

4. 未清理的 setInterval
   const timer = setInterval(check, 1000);
   // 模块卸载时没 clearInterval(timer)
```

**对 Optima 的警示**: `mcp-host` 编排多个 MCP 工具时，如果每次调用创建事件监听器但不清理，连接数多了就会泄漏。

### Node.js 堆快照（Heap Snapshot）

```typescript
import v8 from 'v8';
import fs from 'fs';

function takeHeapSnapshot(): string {
  const filename = `/tmp/heap-${Date.now()}.heapsnapshot`;
  const stream = v8.writeHeapSnapshot(filename);
  return stream; // 返回文件路径
}

// 用法: 在 Chrome DevTools → Memory 标签中加载 .heapsnapshot 文件
// 对比两个时间点的快照，找到增长最快的对象 → 就是泄漏源
```

**三步定位法**:

```
1. 拍第一张快照 → 正常运行一段时间 → 拍第二张快照
2. Chrome DevTools 中选择 "Comparison" 视图
3. 按 "Size Delta" 排序 → 增长最多的就是疑似泄漏

常见发现:
  (string)              +5MB    ← 大量字符串没被 GC
  (array)               +2MB    ← 数组持续增长
  IncomingMessage       +500    ← HTTP 请求对象没释放
  Socket                +200    ← WebSocket 连接没关闭
```

### V8 GC 机制

```
V8 堆内存结构:

┌──────────────────────────────────────┐
│              New Space               │  ← 新对象分配在这里
│  ┌────────────────┬────────────────┐ │     Scavenge GC（频繁，快速，<5ms）
│  │   From Space   │   To Space     │ │
│  └────────────────┴────────────────┘ │
├──────────────────────────────────────┤
│              Old Space               │  ← 存活多次 GC 的对象晋升到这里
│                                      │     Mark-Sweep-Compact（不频繁，慢，可能 >100ms）
├──────────────────────────────────────┤
│           Large Object Space         │  ← 大于阈值的对象直接分配
├──────────────────────────────────────┤
│           Code Space                 │  ← JIT 编译后的机器码
└──────────────────────────────────────┘
```

**GC 对性能的影响**:

```
场景: user-auth 容器只有 256MB 内存

New Space 默认 16MB:
  - 如果请求处理创建大量临时对象，Scavenge 会频繁触发
  - 影响: 每次暂停 1-5ms，高频率下叠加影响延迟

Old Space:
  - 如果有内存泄漏，Old Space 逐渐填满
  - 触发 Mark-Sweep-Compact，暂停可能 50-200ms
  - 最终 OOM Kill → ECS 重启容器
```

**监控 GC 的方法**:

```bash
# 启动时加 --trace-gc
node --trace-gc app.js

# 输出:
# [4231:0x1] 12345 ms: Scavenge 12.3 (16.0) -> 4.5 (16.0) MB, 1.2 ms
# [4231:0x1] 23456 ms: Mark-sweep 45.6 (64.0) -> 30.2 (64.0) MB, 78.3 ms ← 78ms 暂停！
```

```typescript
// 编程式监控
import v8 from 'v8';

setInterval(() => {
  const heap = v8.getHeapStatistics();
  const usage = {
    heapUsedMB: Math.round(heap.used_heap_size / 1024 / 1024),
    heapTotalMB: Math.round(heap.total_heap_size / 1024 / 1024),
    heapLimitMB: Math.round(heap.heap_size_limit / 1024 / 1024),
    utilization: (heap.used_heap_size / heap.heap_size_limit * 100).toFixed(1) + '%',
  };
  console.log(JSON.stringify({ event: 'heap_stats', ...usage }));
}, 30_000); // 每 30 秒上报一次
```

---

## 第四部分：缓存策略

### Cache-Aside（旁路缓存）

最常用的缓存模式，也叫 Lazy Loading：

```
读取流程:

Client → App
  1. 查缓存 → 命中 → 返回
  2. 未命中 → 查数据库 → 写入缓存 → 返回

写入流程:

Client → App
  1. 写入数据库
  2. 删除缓存（注意: 是删除，不是更新）
```

```typescript
// Optima commerce-backend 商品查询示例
import Redis from 'ioredis';

const redis = new Redis({ db: 0 }); // Prod: Database 0

async function getProduct(productId: string): Promise<Product> {
  const cacheKey = `product:${productId}`;

  // 1. 查缓存
  const cached = await redis.get(cacheKey);
  if (cached) {
    return JSON.parse(cached);
  }

  // 2. 缓存未命中 → 查数据库
  const product = await db.query(
    'SELECT * FROM products WHERE id = $1', [productId]
  );

  // 3. 写入缓存，设置 TTL
  await redis.set(cacheKey, JSON.stringify(product), 'EX', 3600); // 1小时

  return product;
}

async function updateProduct(productId: string, data: Partial<Product>): Promise<void> {
  // 1. 更新数据库
  await db.query('UPDATE products SET ... WHERE id = $1', [productId]);

  // 2. 删除缓存（而不是更新，避免并发问题）
  await redis.del(`product:${productId}`);
}
```

**为什么删除而不是更新缓存**: 并发场景下，线程 A 更新数据库后写缓存，线程 B 在 A 之后更新数据库但先写了缓存，结果缓存里是旧值。删除则安全——下次读取时自然重建。

### Write-Through（直写）

```
写入流程:

Client → App → Cache → Database
  应用写缓存，缓存同步写数据库

读取流程:

Client → App → Cache（永远命中）
```

```typescript
// Write-Through 示例（使用缓存库封装）
class WriteThroughCache {
  async set(key: string, value: any): Promise<void> {
    // 原子性地同时写入缓存和数据库
    await Promise.all([
      this.redis.set(key, JSON.stringify(value)),
      this.db.upsert(key, value),
    ]);
  }

  async get(key: string): Promise<any> {
    // 缓存一定有数据（除非首次启动）
    return JSON.parse(await this.redis.get(key));
  }
}
```

**适用场景**: 读多写少、一致性要求高。缺点是写入延迟增加（要同时写两处）。

### Write-Behind（写回/异步写入）

```
写入流程:

Client → App → Cache → (异步) → Database
  应用写缓存，缓存批量/延迟写回数据库

优势: 写入极快（只写缓存），数据库压力小
风险: 缓存宕机数据丢失
```

**适用场景**: 写入频繁且允许少量数据丢失（如计数器、用户行为日志）。

### 缓存三大问题

```
┌──────────────────────────────────────────────────────────────────┐
│                        缓存雪崩                                   │
│                                                                  │
│ 大量缓存同时过期 → 请求全部打到数据库 → 数据库崩溃                    │
│                                                                  │
│ 对策:                                                             │
│   1. TTL 加随机偏移: expire = baseTTL + random(0, 300)            │
│   2. 分批预热: 不要在同一时间写入大量同 TTL 的缓存                    │
│   3. 限流降级: 数据库前加限流器                                      │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                        缓存穿透                                   │
│                                                                  │
│ 查询不存在的数据 → 缓存永远 miss → 每次都查数据库                    │
│ 恶意攻击: 大量随机 ID 请求，全部穿透                                 │
│                                                                  │
│ 对策:                                                             │
│   1. 缓存空值: 不存在也缓存（TTL 短一点，如 60s）                    │
│   2. 布隆过滤器: 先过滤掉一定不存在的 ID                             │
│   3. 参数校验: ID 格式不对直接拦截                                   │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│                        缓存击穿                                   │
│                                                                  │
│ 热点 key 过期的瞬间，大量并发请求同时查数据库                          │
│ 与雪崩的区别: 雪崩是大量 key，击穿是单个热点 key                      │
│                                                                  │
│ 对策:                                                             │
│   1. 互斥锁: 只让一个请求去查数据库，其他等待                         │
│   2. 逻辑过期: 不设物理 TTL，由业务代码判断是否过期并异步刷新           │
│   3. 热点 key 永不过期                                              │
└──────────────────────────────────────────────────────────────────┘
```

**互斥锁防击穿的实现**:

```typescript
async function getProductWithLock(productId: string): Promise<Product> {
  const cacheKey = `product:${productId}`;
  const lockKey = `lock:product:${productId}`;

  // 1. 查缓存
  const cached = await redis.get(cacheKey);
  if (cached) return JSON.parse(cached);

  // 2. 尝试获取锁（SET NX EX: 不存在才设置，10秒过期）
  const locked = await redis.set(lockKey, '1', 'EX', 10, 'NX');

  if (locked) {
    try {
      // 3. 获取锁成功 → 查数据库 → 写缓存
      const product = await db.query('SELECT * FROM products WHERE id = $1', [productId]);
      await redis.set(cacheKey, JSON.stringify(product), 'EX', 3600);
      return product;
    } finally {
      await redis.del(lockKey);
    }
  } else {
    // 4. 获取锁失败 → 短暂等待后重试（其他线程正在重建缓存）
    await new Promise(r => setTimeout(r, 100));
    return getProductWithLock(productId);
  }
}
```

---

## 第五部分：Redis 使用模式

### 数据结构选择

Optima 共享 Redis 通过 Database 编号隔离（Prod: DB 0-1, Stage: DB 2, Stage-ECS: DB 3）。选对数据结构直接影响内存占用和查询效率。

```
┌─────────────┬──────────────────────────────────┬──────────────────────────────────┐
│ 数据结构     │ 适用场景                          │ Optima 示例                      │
├─────────────┼──────────────────────────────────┼──────────────────────────────────┤
│ String      │ 简单 K-V、缓存序列化对象           │ 缓存商品详情 JSON                 │
│ Hash        │ 对象的部分字段更新                  │ 用户 session 信息                 │
│ List        │ 队列、最近 N 条记录                │ 最近浏览的商品列表                 │
│ Set         │ 去重、交集/并集                    │ 用户标签、权限集合                 │
│ Sorted Set  │ 排行榜、带分数的有序数据           │ 商品销量排行、限时活动倒计时         │
│ Stream      │ 消息队列（类似 Kafka）             │ 事件流、异步任务分发                │
└─────────────┴──────────────────────────────────┴──────────────────────────────────┘
```

**String vs Hash 的选择**:

```typescript
// ❌ 每次修改都要读取整个对象、反序列化、修改、序列化、写回
await redis.set('user:123', JSON.stringify({ name: 'Alice', visits: 100 }));
const user = JSON.parse(await redis.get('user:123'));
user.visits++;
await redis.set('user:123', JSON.stringify(user));

// ✅ 用 Hash，直接修改单个字段
await redis.hset('user:123', { name: 'Alice', visits: '100' });
await redis.hincrby('user:123', 'visits', 1); // 原子递增，无需读取整个对象
```

**Sorted Set 做排行榜**:

```typescript
// 商品销量排行榜
await redis.zadd('ranking:sales', productSales, productId);

// 获取 Top 10
const top10 = await redis.zrevrange('ranking:sales', 0, 9, 'WITHSCORES');
// → ['product-A', '1500', 'product-B', '1200', ...]
```

### 过期策略

Redis 使用两种策略删除过期 key：

```
1. 惰性删除: 访问 key 时检查是否过期，过期则删除
   优点: 不占用额外 CPU
   缺点: 大量 key 过期但没人访问 → 内存浪费

2. 定期删除: 每 100ms 随机检查一批 key
   默认每次检查 20 个 key
   如果超过 25% 已过期，立即再检查 20 个
   最多占用 25% CPU 时间

两种策略互补: 定期清理 + 访问时兜底
```

### 内存淘汰策略

当 Redis 内存达到 `maxmemory` 限制时的淘汰策略：

```
┌───────────────────────┬───────────────────────────────────────────────────────┐
│ 策略                   │ 说明                                                 │
├───────────────────────┼───────────────────────────────────────────────────────┤
│ noeviction            │ 不淘汰，内存满了直接报错（默认）                         │
│ allkeys-lru           │ 从所有 key 中淘汰最近最少使用的 ← 通用缓存推荐          │
│ volatile-lru          │ 只从设了 TTL 的 key 中淘汰 LRU                         │
│ allkeys-lfu           │ 从所有 key 中淘汰最不经常使用的（Redis 4.0+）           │
│ volatile-ttl          │ 从设了 TTL 的 key 中淘汰最快过期的                      │
│ allkeys-random        │ 随机淘汰                                              │
└───────────────────────┴───────────────────────────────────────────────────────┘

Optima 建议: allkeys-lru（所有 key 都可以被淘汰，最近最少用的先走）
```

### Pipeline 和 Lua 脚本

**Pipeline**: 批量发送命令，减少网络往返。

```typescript
// ❌ 10 次网络往返
for (const id of productIds) {
  await redis.get(`product:${id}`);  // 每次一个 RTT
}

// ✅ 1 次网络往返
const pipeline = redis.pipeline();
for (const id of productIds) {
  pipeline.get(`product:${id}`);
}
const results = await pipeline.exec(); // 所有结果一次返回
```

**Lua 脚本**: 在 Redis 服务端原子执行多个命令。

```typescript
// 限流器: 令牌桶算法
const rateLimitScript = `
  local key = KEYS[1]
  local limit = tonumber(ARGV[1])
  local window = tonumber(ARGV[2])

  local current = redis.call('INCR', key)
  if current == 1 then
    redis.call('EXPIRE', key, window)
  end

  if current > limit then
    return 0  -- 被限流
  end
  return 1    -- 放行
`;

// 每个用户每分钟最多 100 次请求
const allowed = await redis.eval(
  rateLimitScript, 1,
  `ratelimit:${userId}`, 100, 60
);
```

**Lua 脚本的优势**: 所有命令原子执行，不会被其他命令插入，解决了 check-then-act 的竞态问题。

---

## 第六部分：连接池调优

### 数据库连接池大小计算

连接池不是越大越好。PostgreSQL 官方建议的公式：

```
pool_size = ((core_count * 2) + effective_spindle_count)

对 RDS db.t3.medium (2 vCPU, SSD):
  pool_size = (2 * 2) + 1 = 5

但这是单个应用的建议。Optima 多服务共享一个 RDS:
```

```
Optima 共享 RDS 连接规划:

RDS db.t3.medium → max_connections 默认约 80
每个服务的合理连接池:

┌─────────────────────┬───────────────┬────────────────────────────────┐
│ 服务                 │ 建议 pool_size │ 原因                          │
├─────────────────────┼───────────────┼────────────────────────────────┤
│ user-auth           │ 5             │ 简单查询，延迟低                │
│ commerce-backend    │ 10            │ 复杂查询，事务较多              │
│ mcp-host            │ 3             │ 很少直接查数据库                │
│ agentic-chat        │ 5             │ 会话历史查询                    │
│ 预留                │ ~57           │ 给 Stage 和管理工具             │
├─────────────────────┼───────────────┼────────────────────────────────┤
│ 总计                │ 23 (Prod)     │ 留足余量给临时连接和监控工具      │
└─────────────────────┴───────────────┴────────────────────────────────┘
```

**Node.js 中的连接池配置**:

```typescript
// 使用 pg (node-postgres)
import { Pool } from 'pg';

const pool = new Pool({
  host: 'optima-prod-postgres.ctg866o0ehac.ap-southeast-1.rds.amazonaws.com',
  port: 5432,
  database: 'optima_auth',
  user: 'auth_user',
  max: 5,                  // 最大连接数
  min: 1,                  // 最小空闲连接
  idleTimeoutMillis: 30000, // 空闲连接 30s 后释放
  connectionTimeoutMillis: 5000, // 获取连接超时 5s
  // 关键: 不要设 statement_timeout 为 0（无限制）
  statement_timeout: 10000, // SQL 执行超时 10s
});

// 监控连接池状态
setInterval(() => {
  console.log(JSON.stringify({
    event: 'pool_stats',
    total: pool.totalCount,       // 总连接数
    idle: pool.idleCount,         // 空闲连接数
    waiting: pool.waitingCount,   // 等待获取连接的请求数 ← 这个 >0 就要扩池
  }));
}, 10_000);
```

### HTTP Keep-Alive

Node.js 默认不复用 HTTP 连接。`mcp-host` 调用多个 MCP 工具时，每次 HTTP 请求都新建 TCP 连接：

```typescript
// ❌ 默认: 每次请求新建连接
import fetch from 'node-fetch';
await fetch('http://comfy-mcp-ecs.optima-stage.local:8000/generate', ...);
// 三次握手 → 请求 → 响应 → 四次挥手 → 再来一次

// ✅ 使用 Keep-Alive Agent 复用连接
import http from 'http';
import https from 'https';

const httpAgent = new http.Agent({
  keepAlive: true,        // 复用连接
  keepAliveMsecs: 30000,  // 保持 30s
  maxSockets: 50,         // 每个 host 最大 50 个连接
  maxFreeSockets: 10,     // 最多保留 10 个空闲连接
});

await fetch('http://comfy-mcp-ecs.optima-stage.local:8000/generate', {
  agent: httpAgent,
});
```

**实际影响**: 在 ECS 内部通信（Cloud Map DNS）中，Keep-Alive 可以减少 10-30ms 的连接建立延迟。对高频调用场景（mcp-host 编排多工具）效果显著。

### Redis 连接池

```typescript
// ioredis 默认就是连接池模式（单连接复用 + Pipeline）
// 如果需要更高并发，使用 Cluster 模式或多个实例
import Redis from 'ioredis';

const redis = new Redis({
  host: 'your-redis-endpoint',
  port: 6379,
  db: 0,                    // Prod: Database 0
  maxRetriesPerRequest: 3,  // 每个命令最多重试 3 次
  retryStrategy(times) {    // 连接断开后的重试策略
    if (times > 10) return null; // 10 次后放弃
    return Math.min(times * 200, 3000); // 指数退避
  },
  lazyConnect: true,         // 延迟连接，调用时才连
  enableReadyCheck: true,    // 连接后检查 Redis 是否 ready
});
```

---

## 第七部分：N+1 查询问题

### ORM 的懒加载陷阱

```typescript
// 假设使用 TypeORM / Prisma
// 查询 10 个订单及其关联的用户信息

// ❌ N+1 问题: 1 次查订单 + 10 次查用户 = 11 次 SQL
const orders = await orderRepo.find(); // SELECT * FROM orders → 10 条
for (const order of orders) {
  const user = await userRepo.findOne(order.userId);
  // SELECT * FROM users WHERE id = ? → 执行 10 次！
}

// ❌ 即使用 ORM 的关联加载，如果配置了 lazy loading:
const orders = await orderRepo.find();
for (const order of orders) {
  console.log(order.user.name); // 触发懒加载，每次一个 SQL
}
```

```
数据库日志（N+1 产生了 11 条 SQL）:

Query: SELECT * FROM orders
Query: SELECT * FROM users WHERE id = 'user-1'
Query: SELECT * FROM users WHERE id = 'user-2'
Query: SELECT * FROM users WHERE id = 'user-3'
... 还有 7 条 ...
```

### 解决方案

**方案 1: Eager Loading（预加载）**

```typescript
// ✅ TypeORM: 使用 relations 或 leftJoinAndSelect
const orders = await orderRepo.find({
  relations: ['user'],  // 自动 JOIN
});
// 只产生 1 条 SQL: SELECT ... FROM orders LEFT JOIN users ON ...

// ✅ Prisma: include
const orders = await prisma.order.findMany({
  include: { user: true },
});
// 产生 2 条 SQL: SELECT * FROM orders; SELECT * FROM users WHERE id IN (...)
```

**方案 2: DataLoader 模式**

当你不能简单用 JOIN 解决时（如 GraphQL resolver、跨服务调用）：

```typescript
import DataLoader from 'dataloader';

// 创建批量加载器
const userLoader = new DataLoader<string, User>(async (userIds) => {
  // 一次查询所有需要的用户
  const users = await db.query(
    'SELECT * FROM users WHERE id = ANY($1)',
    [userIds]
  );

  // 按请求顺序排列结果
  const userMap = new Map(users.map(u => [u.id, u]));
  return userIds.map(id => userMap.get(id) || null);
});

// 使用: 看起来是逐个加载，实际上会批量合并
const orders = await orderRepo.find();
const ordersWithUsers = await Promise.all(
  orders.map(async order => ({
    ...order,
    user: await userLoader.load(order.userId),
    // DataLoader 会把同一事件循环 tick 中的所有 load() 合并为一次批量查询
  }))
);

// 实际 SQL: SELECT * FROM orders; SELECT * FROM users WHERE id = ANY(['user-1', 'user-2', ...])
// 只有 2 条 SQL，而不是 11 条
```

### SQL JOIN vs 多次查询的权衡

```
JOIN 适合:
  ✅ 数据在同一个数据库
  ✅ 结果集不大（< 1000 行）
  ✅ 关联关系简单（1:1 或 1:N）

多次查询 + DataLoader 适合:
  ✅ 数据跨服务/跨数据库
  ✅ 结果集很大（JOIN 会产生笛卡尔积）
  ✅ 需要缓存中间结果
  ✅ GraphQL resolver 场景

对 Optima 的建议:
  - commerce-backend 内部: 用 JOIN
  - mcp-host 调用 user-auth: 用 DataLoader（跨服务）
  - agentic-chat 查会话历史: 用 JOIN + 分页
```

---

## 第八部分：异步处理模式

### 消息队列

当操作不需要同步返回结果时，用消息队列解耦：

```
同步处理:
  用户下单 → 扣库存 → 创建订单 → 发通知 → 返回
  总延迟 = 扣库存(50ms) + 创建订单(80ms) + 发通知(200ms) = 330ms

异步处理:
  用户下单 → 扣库存 → 创建订单 → 发消息到队列 → 返回
  总延迟 = 扣库存(50ms) + 创建订单(80ms) + 入队(5ms) = 135ms
  通知由 Worker 异步处理
```

**AWS SQS 示例（Optima 适用）**:

```typescript
import { SQSClient, SendMessageCommand, ReceiveMessageCommand } from '@aws-sdk/client-sqs';

const sqs = new SQSClient({ region: 'ap-southeast-1' });
const QUEUE_URL = 'https://sqs.ap-southeast-1.amazonaws.com/585891120210/order-notifications';

// 生产者: 下单后发消息
async function publishOrderCreated(order: Order): Promise<void> {
  await sqs.send(new SendMessageCommand({
    QueueUrl: QUEUE_URL,
    MessageBody: JSON.stringify({
      type: 'order.created',
      orderId: order.id,
      userId: order.userId,
      timestamp: Date.now(),
    }),
  }));
}

// 消费者: Worker 轮询处理
async function processMessages(): Promise<void> {
  while (true) {
    const response = await sqs.send(new ReceiveMessageCommand({
      QueueUrl: QUEUE_URL,
      MaxNumberOfMessages: 10,  // 批量拉取
      WaitTimeSeconds: 20,      // 长轮询，减少空请求
    }));

    for (const message of response.Messages || []) {
      const event = JSON.parse(message.Body);
      await sendNotification(event);
      // 处理成功后删除消息
      await sqs.send(new DeleteMessageCommand({
        QueueUrl: QUEUE_URL,
        ReceiptHandle: message.ReceiptHandle,
      }));
    }
  }
}
```

**Redis Stream 作为轻量级队列**:

```typescript
// 生产者
await redis.xadd('stream:orders', '*',
  'type', 'order.created',
  'orderId', order.id,
  'userId', order.userId,
);

// 消费者（消费者组模式，支持多 Worker 并行消费）
await redis.xgroup('CREATE', 'stream:orders', 'notification-workers', '0', 'MKSTREAM');

// Worker 读取
const messages = await redis.xreadgroup(
  'GROUP', 'notification-workers', 'worker-1',
  'COUNT', 10,
  'BLOCK', 5000,  // 阻塞 5s 等待新消息
  'STREAMS', 'stream:orders', '>'
);
```

### Worker 模式

```
┌────────────┐     ┌───────────────┐     ┌────────────────┐
│  Web API   │────→│ Message Queue │────→│   Worker(s)    │
│ (Node.js)  │     │ (SQS/Redis)   │     │   (Node.js)    │
└────────────┘     └───────────────┘     └────────────────┘
  快速返回            缓冲 + 持久化          按自己的速度处理

优势:
  1. API 响应快
  2. Worker 可独立扩缩容
  3. 失败可重试
  4. 流量尖峰被队列平滑
```

### 背压（Backpressure）

当生产者速度 > 消费者速度时，消息堆积会导致内存溢出或延迟飙升：

```
背压的三种应对策略:

1. 丢弃（Drop）:
   - 丢弃最新的消息（tail drop）
   - 或丢弃最旧的消息（head drop）
   - 适用: 实时数据流，旧数据无意义

2. 缓冲（Buffer）:
   - 队列设置最大长度
   - 满了之后拒绝新消息，让生产者重试
   - 适用: 可靠性要求高

3. 控制生产者速率（Rate Limit）:
   - 返回 429 Too Many Requests
   - 生产者感知到压力后减速
   - 适用: API 网关层
```

```typescript
// Node.js Stream 的背压处理
import { Transform } from 'stream';

const processor = new Transform({
  highWaterMark: 16 * 1024, // 16KB 缓冲区
  transform(chunk, encoding, callback) {
    const processed = expensiveProcessing(chunk);
    // 如果下游消费慢，Node.js 自动暂停上游读取
    callback(null, processed);
  },
});

// 正确使用 pipe（自动处理背压）
readableStream.pipe(processor).pipe(writableStream);

// ❌ 错误做法（忽略背压）
readableStream.on('data', (chunk) => {
  writableStream.write(chunk); // 不检查返回值，可能内存溢出
});
```

---

## 第九部分：CDN 缓存策略

### Cache-Control 头详解

```
Cache-Control 指令:

┌──────────────────────┬───────────────────────────────────────────────────────┐
│ 指令                  │ 说明                                                 │
├──────────────────────┼───────────────────────────────────────────────────────┤
│ public               │ 任何缓存（CDN、浏览器）都可以缓存                       │
│ private              │ 只有浏览器可以缓存，CDN 不可以                          │
│ no-cache             │ 可以缓存，但每次使用前必须向源站验证                     │
│ no-store             │ 完全不缓存                                             │
│ max-age=N            │ 缓存 N 秒（从响应时间算起）                             │
│ s-maxage=N           │ CDN/代理缓存 N 秒（覆盖 max-age，浏览器忽略此指令）      │
│ stale-while-revalidate=N │ 过期后 N 秒内先返回旧缓存，同时后台刷新              │
│ immutable            │ 内容永远不会变（配合哈希文件名使用）                      │
└──────────────────────┴───────────────────────────────────────────────────────┘
```

**Optima 前端资源的缓存策略**:

```
对 optima-store (Next.js) 通过 CloudFront 分发:

/_next/static/*     → Cache-Control: public, max-age=31536000, immutable
                      文件名含 hash，内容不变，缓存一年

/api/*              → Cache-Control: no-store
                      API 响应不缓存

/images/products/*  → Cache-Control: public, max-age=86400, s-maxage=604800
                      浏览器缓存 1 天，CDN 缓存 7 天

/                   → Cache-Control: public, max-age=0, s-maxage=3600,
                                     stale-while-revalidate=86400
                      CDN 缓存 1 小时，过期后先返回旧页面，后台刷新
```

### ETag / Last-Modified

```
条件请求流程:

第一次请求:
  Client → GET /products/123
  Server → 200 OK
           ETag: "abc123"
           Last-Modified: Mon, 01 Jan 2026 00:00:00 GMT
           Body: {...}

第二次请求（带条件头）:
  Client → GET /products/123
           If-None-Match: "abc123"
           If-Modified-Since: Mon, 01 Jan 2026 00:00:00 GMT
  Server → 304 Not Modified（无 Body）
           省了传输 Body 的带宽
```

```typescript
// Express 中间件: ETag + 条件请求
import express from 'express';
import crypto from 'crypto';

app.get('/api/products/:id', async (req, res) => {
  const product = await getProduct(req.params.id);
  const body = JSON.stringify(product);

  // 生成 ETag
  const etag = crypto.createHash('md5').update(body).digest('hex');

  // 检查条件请求
  if (req.headers['if-none-match'] === etag) {
    return res.status(304).end();
  }

  res.set('ETag', etag);
  res.set('Cache-Control', 'public, max-age=0, must-revalidate');
  res.json(product);
});
```

### CloudFront 缓存行为

```
CloudFront 缓存层级:

用户请求 → CloudFront Edge (全球 400+ 节点)
  ├─ Edge Cache HIT → 直接返回（延迟 < 20ms）
  ├─ Edge Cache MISS → Regional Edge Cache
  │   ├─ Regional HIT → 返回（延迟 < 50ms）
  │   └─ Regional MISS → 回源 ALB → 后端服务
  │                      （延迟 = 回源 + 处理时间）
  └─ 缓存 Key: URL + 指定的 Header/Cookie/QueryString

Optima 的 CloudFront 配置要点:
  1. 前端静态资源 → 长缓存 + 哈希文件名
  2. API → 不缓存（Pass-through to ALB）
  3. 图片资源 → CloudFront 缓存 + S3 源
  4. 不要把 Cookie/Authorization 纳入缓存 Key（否则每个用户都 MISS）
```

---

## 第十部分：Node.js 性能特质

### 事件循环阶段

```
Node.js 事件循环的 6 个阶段:

  ┌──────────────────────────────────────────┐
  │            ┌─────────────────┐           │
  │            │    timers        │ ← setTimeout/setInterval 回调
  │            └────────┬────────┘           │
  │            ┌────────▼────────┐           │
  │            │  pending callbacks│ ← 系统级回调（TCP 错误等）
  │            └────────┬────────┘           │
  │            ┌────────▼────────┐           │
  │            │   idle, prepare  │ ← 内部使用
  │            └────────┬────────┘           │
  │            ┌────────▼────────┐           │
  │  ──────→   │      poll        │ ← I/O 回调（网络、文件）
  │            └────────┬────────┘     这里花最多时间
  │            ┌────────▼────────┐           │
  │            │     check        │ ← setImmediate 回调
  │            └────────┬────────┘           │
  │            ┌────────▼────────┐           │
  │            │  close callbacks  │ ← socket.on('close') 等
  │            └────────┬────────┘           │
  │                     │                    │
  │                     └────────────────────│
  └──────────────────────────────────────────┘

关键: 每个阶段执行完该阶段队列中所有回调后，才进入下一阶段
```

**process.nextTick 和 microtask 队列**:

```
在每个阶段切换之间，Node.js 会先清空:
  1. process.nextTick 队列
  2. Promise microtask 队列

这意味着:
  process.nextTick(() => { ... });  // 在当前阶段结束后立即执行
  Promise.resolve().then(() => { ... }); // 也是，但优先级低于 nextTick

⚠️ 警告: 递归 nextTick 会饿死事件循环
  function bad() {
    process.nextTick(bad); // I/O 回调永远不会执行！
  }
```

### 避免阻塞事件循环

```typescript
// ❌ 阻塞事件循环的操作（在主线程）

// 1. 同步文件操作
import fs from 'fs';
const data = fs.readFileSync('/big-file.json'); // 阻塞！

// 2. 大量 JSON 解析
const bigObj = JSON.parse(hugeString); // 100MB JSON → 阻塞数秒

// 3. 复杂正则
const result = /^(a+)+$/.test(longString); // 灾难性回溯（ReDoS）

// 4. 密集计算
function fibonacci(n: number): number {
  if (n <= 1) return n;
  return fibonacci(n - 1) + fibonacci(n - 2); // CPU 密集
}
```

```typescript
// ✅ 正确做法

// 1. 异步文件操作
import fs from 'fs/promises';
const data = await fs.readFile('/big-file.json');

// 2. 流式 JSON 解析
import { parser } from 'stream-json';
import { streamValues } from 'stream-json/streamers/StreamValues';

fs.createReadStream('/big-file.json')
  .pipe(parser())
  .pipe(streamValues())
  .on('data', ({ value }) => {
    // 每个值逐个处理，不阻塞事件循环
  });

// 3. 分批处理大数组
async function processInBatches<T>(
  items: T[],
  batchSize: number,
  fn: (item: T) => Promise<void>
): Promise<void> {
  for (let i = 0; i < items.length; i += batchSize) {
    const batch = items.slice(i, i + batchSize);
    await Promise.all(batch.map(fn));
    // 每批之间让出事件循环
    await new Promise(resolve => setImmediate(resolve));
  }
}
```

### Worker Threads

对于 CPU 密集任务，使用 Worker Threads 移到单独线程：

```typescript
// main.ts
import { Worker } from 'worker_threads';

function runInWorker(data: any): Promise<any> {
  return new Promise((resolve, reject) => {
    const worker = new Worker('./heavy-task.js', {
      workerData: data,
    });
    worker.on('message', resolve);
    worker.on('error', reject);
  });
}

// 处理请求时
app.post('/api/generate-report', async (req, res) => {
  // CPU 密集的报告生成在 Worker 线程执行
  const report = await runInWorker(req.body);
  res.json(report); // 主线程不阻塞
});
```

```typescript
// heavy-task.js（Worker 线程）
import { workerData, parentPort } from 'worker_threads';

const result = expensiveComputation(workerData);
parentPort.postMessage(result);
```

**Worker Threads 的适用场景**:
- 图片/PDF 处理
- 大量数据聚合计算
- 加解密操作
- **不适合 I/O 密集任务**（Node.js 的异步 I/O 已经足够）

### Cluster 模式

在 ECS 容器中充分利用多核（虽然 Optima 目前分配的是 0.25 vCPU）：

```typescript
import cluster from 'cluster';
import os from 'os';

if (cluster.isPrimary) {
  const numWorkers = parseInt(process.env.WEB_CONCURRENCY || '1')
    || os.cpus().length;

  console.log(`Primary ${process.pid} starting ${numWorkers} workers`);

  for (let i = 0; i < numWorkers; i++) {
    cluster.fork();
  }

  cluster.on('exit', (worker, code) => {
    console.log(`Worker ${worker.process.pid} exited (code: ${code})`);
    cluster.fork(); // 自动重启
  });
} else {
  // 每个 Worker 运行独立的 HTTP 服务
  app.listen(8000);
  console.log(`Worker ${process.pid} started`);
}
```

**对 Optima 的实际意义**: 当 ECS Service Auto Scaling 把 user-auth 扩到 4 个 Task 时，4 个 Task × 0.25 vCPU = 1 vCPU 的总算力。这本质上是 Cluster 模式的容器化版本——每个 Task 是一个 "Worker"，ALB 做负载均衡。

```
ECS 容器模式 vs Cluster 模式:

单容器 Cluster (不推荐):
  Container (1 vCPU)
    ├─ Primary
    ├─ Worker 1
    ├─ Worker 2
    └─ Worker 3
  内存不隔离，一个 Worker OOM 影响所有

多容器 ECS (推荐，Optima 当前方案):
  Task 1 (0.25 vCPU) ← 独立容器
  Task 2 (0.25 vCPU) ← 独立容器
  Task 3 (0.25 vCPU) ← 独立容器
  Task 4 (0.25 vCPU) ← 独立容器
  隔离好，弹性伸缩方便
```

---

## 事件循环延迟监控

```typescript
// 监控事件循环是否被阻塞
import { monitorEventLoopDelay } from 'perf_hooks';

const histogram = monitorEventLoopDelay({ resolution: 20 }); // 20ms 精度
histogram.enable();

setInterval(() => {
  console.log(JSON.stringify({
    event: 'event_loop_delay',
    min: histogram.min / 1e6,        // 纳秒 → 毫秒
    max: histogram.max / 1e6,
    mean: histogram.mean / 1e6,
    p99: histogram.percentile(99) / 1e6,
  }));
  histogram.reset();
}, 30_000);

// 正常: mean < 5ms, p99 < 50ms
// 异常: mean > 50ms → 事件循环被阻塞，需排查
```

---

## 推荐资源

### 经典书籍

| 书名 | 作者 | 重点 |
|------|------|------|
| **Systems Performance** (2nd Ed.) | Brendan Gregg | 性能工程圣经。USE Method 原创者。从内核到应用全覆盖 |
| **BPF Performance Tools** | Brendan Gregg | Linux 性能观测的现代工具链（eBPF/bpftrace） |
| **High Performance Browser Networking** | Ilya Grigorik | 网络层性能优化（TCP、TLS、HTTP/2、WebSocket） |
| **Designing Data-Intensive Applications** | Martin Kleppmann | 数据系统架构，第三章"存储与检索"讲透了缓存和索引 |
| **Database Internals** | Alex Petrov | 深入理解数据库存储引擎、B-Tree、LSM-Tree |

### Node.js 性能优化

| 资源 | 类型 | 说明 |
|------|------|------|
| [Node.js 官方 Diagnostics Guide](https://nodejs.org/en/guides/diagnostics) | 文档 | 官方诊断指南（CPU、内存、事件循环） |
| [Clinic.js](https://clinicjs.org/) | 工具 | Node.js 性能诊断套件（Doctor + Bubbleprof + Flame） |
| [0x](https://github.com/davidmarkclements/0x) | 工具 | 一键生成 Node.js 火焰图 |
| [autocannon](https://github.com/mcollina/autocannon) | 工具 | Node.js HTTP 压测工具（比 ab/wrk 更易用） |
| [Node.js Best Practices — Performance](https://github.com/goldbergyoni/nodebestpractices#6-performance-best-practices) | 文档 | 社区总结的性能最佳实践 |

### 工具

| 工具 | 用途 |
|------|------|
| [Flame Graph Tools](https://github.com/brendangregg/FlameGraph) | 生成火焰图的脚本集 |
| [pgbadger](https://github.com/darold/pgbadger) | PostgreSQL 慢查询日志分析 |
| [redis-cli --latency](https://redis.io/docs/management/optimization/latency/) | Redis 延迟诊断 |
| [k6](https://k6.io/) | 负载测试工具（见 03 号文档） |
| [AWS CloudWatch Container Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html) | ECS 容器级监控 |

### 实践建议

```
学习路径:

第一周: 方法论 + 工具
  1. 读 Brendan Gregg 的 USE Method 文章（1h）
  2. 给一个 Optima 服务加 event loop 延迟监控（2h）
  3. 用 Clinic.js 跑一次本地 profiling（2h）

第二周: 缓存 + 数据库
  1. 给 commerce-backend 的高频查询加 Cache-Aside（4h）
  2. 用 EXPLAIN ANALYZE 分析前 10 条最慢的 SQL（2h）
  3. 检查是否有 N+1 查询（2h）

第三周: 深入 Node.js
  1. 读 Node.js 事件循环官方文档（1h）
  2. 用 --inspect 抓一次 CPU Profile（2h）
  3. 拍一次 Heap Snapshot，检查内存分布（2h）

持续:
  - 每个服务加 /debug/health 端点上报连接池状态
  - 每次上线前跑 k6 对比基线
  - 把 P99 延迟加入 CloudWatch Dashboard
```
