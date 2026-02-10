# 08 - 数据库工程

> 从写 SQL 到理解存储引擎：让数据库不再是黑箱

---

## 我们现在在哪

```
Optima 的数据库现状：

✅ 做得好的:
  - 共享 RDS PostgreSQL，多数据库隔离（optima_auth / optima_commerce / optima_chat 等）
  - 每个服务独立数据库用户和权限（auth_user / commerce_user / chat_user）
  - ORM 统一使用 Prisma/TypeORM，schema 版本化管理
  - RDS 自动快照 + GP3 存储

⚠️ 可以更好的:
  - 没人看过 EXPLAIN ANALYZE（SQL 慢了就加 limit 或换逻辑）
  - 索引全靠 ORM 自动生成，没有根据查询模式手动优化
  - 没有连接池中间件（PgBouncer），连接数随服务扩容线性增长
  - 没有慢查询监控（RDS Performance Insights 开了但没人看）
  - 迁移脚本没有考虑零停机（直接 ALTER TABLE ADD COLUMN NOT NULL）
  - 100GB GP3 存储没有容量规划，不知道什么时候会满
```

数据库是后端服务最核心的依赖。ORM 帮你隐藏了 SQL，但也隐藏了性能陷阱。这章的目标是让你**理解 ORM 背后发生了什么**，在数据库出问题时有能力自己排查。

---

## 1. PostgreSQL 索引原理

### 为什么需要索引

没有索引时，PostgreSQL 必须扫描整张表的每一行（Sequential Scan）。当表有 100 万行时，即使只要 1 条结果，也要读完全部数据。

```
没有索引:
┌──────────────────────────────────────┐
│  Table: users (1,000,000 rows)       │
│  SELECT * FROM users WHERE email =   │
│  'alice@example.com'                 │
│                                      │
│  → 逐行扫描 1,000,000 行            │
│  → 磁盘 I/O: 读取所有数据页          │
│  → 时间: 数百毫秒到数秒              │
└──────────────────────────────────────┘

有索引:
┌──────────────────────────────────────┐
│  Index: idx_users_email (B-tree)     │
│  SELECT * FROM users WHERE email =   │
│  'alice@example.com'                 │
│                                      │
│  → 在 B-tree 中查找: 3-4 次比较      │
│  → 磁盘 I/O: 读取 3-4 个索引页 + 1   │
│    数据页                             │
│  → 时间: 毫秒级                      │
└──────────────────────────────────────┘
```

### B-tree 索引（默认）

PostgreSQL 创建索引时默认使用 B-tree。它适用于**等值查询**和**范围查询**。

```sql
-- 创建 B-tree 索引（以下两种等价）
CREATE INDEX idx_users_email ON users (email);
CREATE INDEX idx_users_email ON users USING btree (email);

-- 适合 B-tree 的查询模式
SELECT * FROM users WHERE email = 'alice@example.com';     -- 等值
SELECT * FROM orders WHERE created_at > '2025-01-01';      -- 范围
SELECT * FROM products WHERE price BETWEEN 10 AND 100;     -- 范围
SELECT * FROM users ORDER BY created_at DESC LIMIT 20;     -- 排序
```

**B-tree 的结构**:

```
                    [M]                    ← 根节点
                   /   \
              [D, H]   [R, X]             ← 内部节点
             / | \     / | \
          [A-C][D-G][H-L][M-Q][R-W][X-Z]  ← 叶子节点（指向实际数据行）

查找 email = 'alice@...' 的过程:
1. 根节点: 'A' < 'M' → 走左边
2. 内部节点: 'A' < 'D' → 走最左边
3. 叶子节点: 在 [A-C] 中找到目标行的指针
4. 通过指针读取实际数据页

树高通常 3-4 层，所以任何查询最多 3-4 次磁盘 I/O
```

**复合索引**（多列索引）:

```sql
-- Optima commerce: 按商户查询订单，按创建时间排序
CREATE INDEX idx_orders_merchant_created
  ON orders (merchant_id, created_at DESC);

-- ✅ 能利用这个索引的查询
SELECT * FROM orders WHERE merchant_id = 'xxx' ORDER BY created_at DESC;
SELECT * FROM orders WHERE merchant_id = 'xxx' AND created_at > '2025-01-01';

-- ❌ 不能利用这个索引（跳过了第一列）
SELECT * FROM orders WHERE created_at > '2025-01-01';
-- 原因: B-tree 复合索引遵循"最左前缀"原则
-- 就像电话簿按 (姓, 名) 排序，你不能只按"名"查找
```

### GIN 索引（全文搜索 / JSONB）

GIN（Generalized Inverted Index）是**倒排索引**，适合查询"包含某个元素"的场景。

```sql
-- 场景 1: JSONB 字段查询
-- Optima commerce 的产品有 metadata JSONB 字段
CREATE INDEX idx_products_metadata ON products USING gin (metadata);

-- 查询包含特定属性的产品
SELECT * FROM products WHERE metadata @> '{"color": "red"}';
SELECT * FROM products WHERE metadata ? 'size';

-- 场景 2: 全文搜索
-- 产品名称搜索（比 LIKE '%keyword%' 快得多）
CREATE INDEX idx_products_name_search
  ON products USING gin (to_tsvector('english', name));

SELECT * FROM products
WHERE to_tsvector('english', name) @@ to_tsquery('english', 'wireless & headphone');

-- 场景 3: 数组字段
CREATE INDEX idx_products_tags ON products USING gin (tags);
SELECT * FROM products WHERE tags @> ARRAY['sale', 'new'];
```

**GIN vs B-tree 的区别**:

```
B-tree: 键 → 行位置（一对一 / 一对少）
  email: alice@... → Row #42
  email: bob@...   → Row #88

GIN (倒排索引): 元素 → 包含它的所有行（一对多）
  "red"   → Row #1, #5, #23, #89, ...
  "blue"  → Row #2, #5, #34, ...
  "large" → Row #1, #34, #89, ...

查询 metadata @> '{"color": "red"}':
  → 在倒排索引中找 "red" → 返回 Row #1, #5, #23, #89
```

### GiST 索引（地理空间 / 范围类型）

GiST（Generalized Search Tree）适合**几何数据**和**范围数据**。

```sql
-- 场景: 附近商家搜索（如果未来做 LBS 功能）
CREATE EXTENSION IF NOT EXISTS postgis;

CREATE INDEX idx_stores_location
  ON stores USING gist (location);

-- 查找某坐标 5km 内的商家
SELECT * FROM stores
WHERE ST_DWithin(
  location,
  ST_MakePoint(103.8198, 1.3521)::geography,  -- 新加坡坐标
  5000  -- 5000 米
);

-- 场景: 时间范围重叠查询（预约系统）
CREATE INDEX idx_bookings_period
  ON bookings USING gist (tsrange(start_time, end_time));

SELECT * FROM bookings
WHERE tsrange(start_time, end_time) && tsrange('2025-03-01', '2025-03-02');
```

### 部分索引（Partial Index）

只为满足条件的行建索引，节省空间和写入开销。

```sql
-- Optima 场景: 大部分订单是已完成的，我们只需要快速查询活跃订单
CREATE INDEX idx_orders_active
  ON orders (merchant_id, created_at)
  WHERE status IN ('pending', 'processing', 'shipped');

-- 这个索引只包含活跃订单（可能只有总量的 5%）
-- 比全量索引小 20 倍，更新也更快

-- 另一个场景: 唯一约束但允许 NULL
CREATE UNIQUE INDEX idx_users_email_unique
  ON users (email)
  WHERE deleted_at IS NULL;
-- 软删除的用户不参与唯一检查，新用户可以注册同样的 email
```

### 表达式索引（Expression Index）

对计算结果建索引。

```sql
-- 不区分大小写的 email 查询
CREATE INDEX idx_users_email_lower ON users (lower(email));
SELECT * FROM users WHERE lower(email) = lower('Alice@Example.com');

-- 按日期（去掉时间部分）统计
CREATE INDEX idx_orders_date ON orders (date(created_at));
SELECT date(created_at), count(*)
FROM orders
GROUP BY date(created_at);

-- JSONB 中的特定字段
CREATE INDEX idx_products_brand
  ON products ((metadata->>'brand'));
SELECT * FROM products WHERE metadata->>'brand' = 'Apple';
```

### 索引选择速查

| 查询模式 | 索引类型 | 示例 |
|---------|---------|------|
| `WHERE col = value` | B-tree | 精确匹配 |
| `WHERE col > value` / `ORDER BY` | B-tree | 范围 / 排序 |
| `WHERE jsonb_col @> '{...}'` | GIN | JSONB 包含 |
| `WHERE col @@ to_tsquery(...)` | GIN | 全文搜索 |
| `WHERE array_col @> ARRAY[...]` | GIN | 数组包含 |
| `ST_DWithin(geom, ...)` | GiST | 地理空间 |
| 范围重叠 `&&` | GiST | 时间区间 |
| 只索引部分数据 | Partial Index | 活跃记录 |
| 函数计算后匹配 | Expression Index | `lower(email)` |

---

## 2. EXPLAIN ANALYZE 实战

### 读懂执行计划

`EXPLAIN ANALYZE` 是 PostgreSQL 最重要的诊断工具。它告诉你一条 SQL **实际上**是怎么执行的。

```sql
EXPLAIN ANALYZE
SELECT o.*, u.email
FROM orders o
JOIN users u ON o.user_id = u.id
WHERE o.merchant_id = 'merchant_123'
  AND o.status = 'pending'
ORDER BY o.created_at DESC
LIMIT 20;
```

输出示例:

```
Limit  (cost=45.23..45.28 rows=20 width=256) (actual time=0.892..0.898 rows=20 loops=1)
  →  Sort  (cost=45.23..45.73 rows=200 width=256) (actual time=0.891..0.894 rows=20 loops=1)
        Sort Key: o.created_at DESC
        Sort Method: top-N heapsort  Memory: 35kB
        →  Nested Loop  (cost=0.85..40.50 rows=200 width=256) (actual time=0.035..0.680 rows=187 loops=1)
              →  Index Scan using idx_orders_merchant_status on orders o
                    (cost=0.42..15.30 rows=200 width=200) (actual time=0.020..0.185 rows=187 loops=1)
                    Index Cond: (merchant_id = 'merchant_123' AND status = 'pending')
              →  Index Scan using users_pkey on users u
                    (cost=0.43..0.13 rows=1 width=56) (actual time=0.002..0.002 rows=1 loops=187)
                    Index Cond: (id = o.user_id)
Planning Time: 0.215 ms
Execution Time: 0.952 ms
```

**怎么读**:

```
关键指标:
  cost=0.42..15.30   → 估算成本（优化器用于选择计划，不是真实时间）
  actual time=0.020..0.185  → 实际耗时（毫秒），这才是你关心的
  rows=200 (估算) vs rows=187 (实际)  → 差距大说明统计信息过时
  loops=187  → 这个节点执行了 187 次（嵌套循环的内层）

读取顺序: 从最内层（缩进最深）往外读
  1. Index Scan on orders → 用索引找到 187 条 pending 订单
  2. Index Scan on users → 对每条订单，用主键找用户（187 次）
  3. Sort → 按 created_at 排序
  4. Limit → 取前 20 条
```

### 扫描方式对比

```
Sequential Scan（全表扫描）
┌─────────────────────────────────────────────────┐
│ Seq Scan on orders                              │
│   Filter: (status = 'pending')                  │
│   Rows Removed by Filter: 980000                │
│   actual time=0.012..1250.000 rows=20000        │
│                                                 │
│ 读取 1,000,000 行，过滤掉 980,000 行            │
│ → 当过滤比例 > 90% 时，说明该加索引了           │
└─────────────────────────────────────────────────┘

Index Scan（索引扫描）
┌─────────────────────────────────────────────────┐
│ Index Scan using idx_orders_status on orders    │
│   Index Cond: (status = 'pending')              │
│   actual time=0.020..5.000 rows=20000           │
│                                                 │
│ 通过索引直接定位到 20,000 行，不读多余数据       │
│ → 随机 I/O（跳着读磁盘页）                      │
└─────────────────────────────────────────────────┘

Index Only Scan（仅索引扫描，最快）
┌─────────────────────────────────────────────────┐
│ Index Only Scan using idx_orders_covering       │
│   Index Cond: (status = 'pending')              │
│   Heap Fetches: 0                               │
│   actual time=0.015..2.000 rows=20000           │
│                                                 │
│ 索引中已包含所有需要的列，不需要回表             │
│ → Heap Fetches: 0 说明完全不读数据表             │
└─────────────────────────────────────────────────┘

Bitmap Index Scan + Bitmap Heap Scan（折中方案）
┌─────────────────────────────────────────────────┐
│ Bitmap Heap Scan on orders                      │
│   Recheck Cond: (status = 'pending')            │
│   →  Bitmap Index Scan using idx_orders_status  │
│      Index Cond: (status = 'pending')           │
│                                                 │
│ 先用索引收集所有匹配行的位置，排序后批量读取      │
│ → 减少随机 I/O，适合匹配行较多时                 │
└─────────────────────────────────────────────────┘
```

### Join 策略对比

```
Nested Loop（嵌套循环）
  适合: 外表行少（如 LIMIT 后只有 20 行）
  复杂度: O(N × M)，但 M 每次走索引所以很快

  for each row in orders (20 rows):
      index lookup in users (1 row) → 20 次索引查找

Hash Join（哈希连接）
  适合: 两个大表 JOIN，无合适索引
  复杂度: O(N + M)

  1. 将小表（users）构建为内存哈希表
  2. 扫描大表（orders），用 user_id 去哈希表查找
  注意: 哈希表需要内存，work_mem 太小会溢出到磁盘

Merge Join（归并连接）
  适合: 两表都按 JOIN 键排序（或有索引）
  复杂度: O(N log N + M log M)，但如果已排序则 O(N + M)

  两个有序序列同时推进，像拉链一样合并
```

### 常见性能陷阱

**1. 隐式类型转换导致索引失效**:

```sql
-- ❌ merchant_id 是 VARCHAR，但传了 INTEGER
SELECT * FROM orders WHERE merchant_id = 12345;
-- PostgreSQL 会: WHERE merchant_id::integer = 12345
-- 整张表每行都要做类型转换 → Seq Scan

-- ✅ 类型匹配
SELECT * FROM orders WHERE merchant_id = '12345';
```

**2. LIKE 前缀通配符**:

```sql
-- ❌ 前缀通配符无法使用 B-tree 索引
SELECT * FROM products WHERE name LIKE '%headphone%';
-- → Seq Scan（B-tree 只能匹配前缀）

-- ✅ 前缀匹配可以用索引
SELECT * FROM products WHERE name LIKE 'wireless%';

-- ✅ 或者用 GIN + pg_trgm 扩展
CREATE EXTENSION pg_trgm;
CREATE INDEX idx_products_name_trgm ON products USING gin (name gin_trgm_ops);
SELECT * FROM products WHERE name LIKE '%headphone%';  -- 现在走 GIN 索引
```

**3. OR 条件导致索引失效**:

```sql
-- ❌ OR 可能导致 Seq Scan
SELECT * FROM orders WHERE merchant_id = 'xxx' OR status = 'pending';

-- ✅ 改写为 UNION ALL（每个子查询独立走索引）
SELECT * FROM orders WHERE merchant_id = 'xxx'
UNION ALL
SELECT * FROM orders WHERE status = 'pending' AND merchant_id != 'xxx';
```

**4. 统计信息过时**:

```sql
-- 执行计划估算 rows=1，实际 rows=50000 → 选错了 Nested Loop 而不是 Hash Join
-- 解决: 更新统计信息
ANALYZE orders;

-- 或者 RDS 上开启 auto-analyze（默认已开启，但阈值可能不够）
-- 大批量 INSERT/UPDATE 后手动 ANALYZE 一下
```

---

## 3. 事务隔离级别与 MVCC

### 事务的 ACID

```
A - Atomicity（原子性）:  事务中的操作要么全成功，要么全回滚
C - Consistency（一致性）: 事务结束后数据库处于有效状态
I - Isolation（隔离性）:  并发事务互不影响 ← 这节重点
D - Durability（持久性）:  提交后的数据不会丢失
```

### PostgreSQL 的隔离级别

PostgreSQL 支持三个隔离级别（不支持 Read Uncommitted，会自动升级为 Read Committed）:

```
级别                    脏读    不可重复读    幻读     序列化异常    性能
Read Committed (默认)    ✗       ✓           ✓        ✓           最好
Repeatable Read          ✗       ✗           ✗*       ✓           中等
Serializable             ✗       ✗           ✗        ✗           最差

✗ = 不会发生   ✓ = 可能发生
* PostgreSQL 的 Repeatable Read 基于 MVCC，实际上也防止了幻读
```

**Read Committed 的行为**（默认，Optima 所有服务都在用）:

```sql
-- 事务 A                           -- 事务 B
BEGIN;
SELECT balance FROM accounts
WHERE id = 1;
-- 结果: 1000
                                    BEGIN;
                                    UPDATE accounts SET balance = 500
                                    WHERE id = 1;
                                    COMMIT;

SELECT balance FROM accounts
WHERE id = 1;
-- 结果: 500  ← 同一事务内两次读取结果不同！
-- 这就是"不可重复读"
COMMIT;
```

**什么时候需要更高隔离级别**:

```sql
-- 场景: 库存扣减（Optima commerce）
-- 两个并发请求同时购买最后一件商品

-- 事务 A                           -- 事务 B
BEGIN;
SELECT stock FROM products
WHERE id = 'SKU001';
-- 结果: 1 (还有库存)
                                    BEGIN;
                                    SELECT stock FROM products
                                    WHERE id = 'SKU001';
                                    -- 结果: 1 (还有库存)

UPDATE products SET stock = 0
WHERE id = 'SKU001';
COMMIT;  -- ✅ 成功
                                    UPDATE products SET stock = 0
                                    WHERE id = 'SKU001';
                                    COMMIT;  -- ✅ 也成功了！
                                    -- 超卖: 卖了 2 件但只有 1 件

-- 解决方案 1: 使用行锁（推荐）
BEGIN;
SELECT stock FROM products
WHERE id = 'SKU001'
FOR UPDATE;  -- 加排他锁，其他事务在此行等待
-- stock = 1
UPDATE products SET stock = stock - 1 WHERE id = 'SKU001';
COMMIT;

-- 解决方案 2: 乐观锁（ORM 常用）
UPDATE products SET stock = stock - 1
WHERE id = 'SKU001' AND stock > 0;
-- 返回 affected rows = 0 时表示库存不足
```

### MVCC 原理

PostgreSQL 通过 MVCC（Multi-Version Concurrency Control）实现事务隔离，**读写互不阻塞**。

```
MVCC 的核心思想: 每行数据保留多个版本

┌──────────────────────────────────────────────┐
│ users 表 (id=1)                              │
│                                              │
│ Version 1: {name: "Alice", xmin: 100,        │
│             xmax: 150}                       │
│ Version 2: {name: "Alice Wang", xmin: 150,   │
│             xmax: ∞}                         │
│                                              │
│ xmin = 创建这个版本的事务 ID                   │
│ xmax = 删除（或更新）这个版本的事务 ID          │
│ xmax = ∞ 表示当前版本                         │
└──────────────────────────────────────────────┘

事务可见性规则:
  事务 ID = 160 看到哪个版本？
  - Version 1: xmax=150 < 160，已被删除 → 不可见
  - Version 2: xmin=150 < 160 且 xmax=∞ → 可见 ✓

  事务 ID = 120 看到哪个版本？（如果是 Repeatable Read，从 ID=120 开始的快照）
  - Version 1: xmin=100 < 120 且 xmax=150 > 120 → 可见 ✓
  - Version 2: xmin=150 > 120 → 不可见（在快照之后创建的）
```

**MVCC 的副作用 — 表膨胀（Table Bloat）**:

```
UPDATE 不是原地修改，而是: 标记旧版本删除 + 插入新版本
DELETE 也不是真的删除，只是标记

这些"死元组"(dead tuples) 会占用磁盘空间
→ 需要 VACUUM 来清理

VACUUM:        回收死元组空间（不锁表，可以正常读写）
VACUUM FULL:   重写整张表（锁表，慎用！生产环境避免）
AUTOVACUUM:    PostgreSQL 自动运行 VACUUM（RDS 默认开启）

-- 查看表膨胀情况
SELECT relname, n_dead_tup, n_live_tup,
       round(n_dead_tup::numeric / nullif(n_live_tup, 0) * 100, 1) AS dead_ratio
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;
```

### 死锁检测

```sql
-- 死锁场景
-- 事务 A                              -- 事务 B
BEGIN;
UPDATE accounts SET balance = 100      BEGIN;
WHERE id = 1;  -- 锁住 id=1
                                       UPDATE accounts SET balance = 200
                                       WHERE id = 2;  -- 锁住 id=2

UPDATE accounts SET balance = 300
WHERE id = 2;  -- 等待 id=2 的锁...
                                       UPDATE accounts SET balance = 400
                                       WHERE id = 1;  -- 等待 id=1 的锁...

-- 死锁！两个事务互相等待
-- PostgreSQL 自动检测死锁（deadlock_timeout 默认 1s）
-- 选择一个事务回滚，另一个继续

-- 预防死锁: 所有事务按相同顺序访问资源
-- ✅ 两个事务都先锁 id=1，再锁 id=2
```

---

## 4. 连接池管理

### 为什么需要连接池

每个 PostgreSQL 连接都是一个**独立进程**（不是线程），消耗约 5-10MB 内存。

```
没有连接池:
┌──────────┐     ┌──────────────────────┐
│ user-auth│────→│                      │
│ (10 conn)│     │                      │
├──────────┤     │  PostgreSQL          │
│ commerce │────→│  (RDS db.t3.medium)  │
│ (10 conn)│     │                      │
├──────────┤     │  max_connections=83   │
│ mcp-host │────→│  (t3.medium 默认)    │
│ (10 conn)│     │                      │
├──────────┤     │  30 + 30 + 30 + 30   │
│ chat     │────→│  = 120 连接 > 83     │
│ (10 conn)│     │  → 连接被拒绝！       │
└──────────┘     └──────────────────────┘

问题:
- 每个 ECS task 开 10 个连接
- 4 个服务 × 3 个 task（auto-scaling）= 120 个连接
- db.t3.medium 默认 max_connections = 83
- 还没算 Stage 环境共享同一个 RDS！
```

### PgBouncer 架构

```
有 PgBouncer:
┌──────────┐     ┌─────────────┐     ┌────────────────┐
│ user-auth│     │             │     │                │
│ (10 conn)│────→│             │     │                │
├──────────┤     │  PgBouncer  │────→│  PostgreSQL    │
│ commerce │────→│             │     │  实际只用 20    │
│ (10 conn)│     │  接受 200   │     │  个连接        │
├──────────┤     │  个客户端   │     │                │
│ mcp-host │────→│  连接       │     │                │
│ (10 conn)│     │             │     │                │
├──────────┤     │             │     │                │
│ chat     │────→│             │     │                │
│ (10 conn)│     └─────────────┘     └────────────────┘
└──────────┘
```

### 连接池模式

```
Transaction Pooling（推荐）:
  - 事务结束后连接归还给池
  - 不同客户端可以复用同一个 PostgreSQL 连接
  - 限制: 不能使用 SET / PREPARE / LISTEN / NOTIFY 等会话级功能
  - 适合: 大多数 Web 应用（Optima 的所有服务都适用）

Session Pooling:
  - 客户端断开后连接才归还
  - 支持所有 PostgreSQL 功能
  - 连接复用率低
  - 适合: 需要会话级功能的应用（如使用了 PREPARE STATEMENT）

Statement Pooling:
  - 每个 SQL 语句执行后连接就归还
  - 不支持多语句事务
  - 很少使用
```

### 连接数计算

```
PostgreSQL 连接数公式:

  max_connections = (可用内存 MB) / (每连接开销 MB)

  db.t3.medium (4GB RAM):
    操作系统 + PG 共享缓存: ~1.5GB
    可用于连接: ~2.5GB
    每连接开销: ~10MB (work_mem + 进程开销)
    理论最大: 250，但留余量 → RDS 默认 83

合理的连接数规划:

  RDS max_connections: 83 (db.t3.medium 默认)
  预留给管理员: 3 (RDS 内部 + DBA 连接)
  可用: 80

  分配:
  ┌──────────────────────────────────────┐
  │ Prod 环境:                           │
  │   user-auth:    15 连接              │
  │   commerce:     20 连接              │
  │   mcp-host:     15 连接              │
  │   chat:         15 连接              │
  │   小计:         65 连接              │
  │                                      │
  │ Stage 环境 (共享同一 RDS):            │
  │   所有服务合计:  15 连接              │
  │                                      │
  │ 总计: 80 连接 ✓                      │
  └──────────────────────────────────────┘
```

### ORM 连接池配置

```typescript
// Prisma - datasource 配置
// schema.prisma
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
  // connection_limit 控制连接池大小
  // 公式: (CPU 核心数 × 2) + 磁盘数 (一般 2-5 对于 Web 应用)
}

// DATABASE_URL 中控制:
// postgresql://user:pass@host:5432/db?connection_limit=5&pool_timeout=10

// TypeORM - DataSource 配置
const dataSource = new DataSource({
  type: 'postgres',
  host: process.env.DB_HOST,
  poolSize: 5,                    // 连接池大小
  extra: {
    max: 5,                       // pg 驱动的最大连接数
    idleTimeoutMillis: 30000,     // 空闲连接超时
    connectionTimeoutMillis: 5000, // 连接超时
  },
});
```

---

## 5. 数据库迁移策略

### 零停机迁移（Expand-Contract Pattern）

直接执行 `ALTER TABLE ADD COLUMN NOT NULL` 会**锁表**，对于大表可能阻塞几分钟。

```
零停机迁移的核心思想: 分两步走

Expand（扩展）: 添加新结构，兼容旧代码
  ↓ 部署新代码
Contract（收缩）: 清理旧结构

示例: 给 orders 表添加 NOT NULL 的 shipping_method 列

❌ 危险的做法（一步到位）:
  ALTER TABLE orders ADD COLUMN shipping_method VARCHAR(50) NOT NULL DEFAULT 'standard';
  -- 如果表有 100 万行，PostgreSQL 需要重写每一行来添加默认值
  -- PG 11+ 对简单默认值优化了（不需要重写），但 NOT NULL 约束仍需检查所有行

✅ 安全的做法（分步）:

  Step 1 (迁移): 添加可空列
    ALTER TABLE orders ADD COLUMN shipping_method VARCHAR(50);
    -- 瞬间完成，不锁表，不重写数据

  Step 2 (代码): 部署新代码，写入时填充新列
    INSERT INTO orders (..., shipping_method) VALUES (..., 'standard');

  Step 3 (回填): 后台填充历史数据
    -- 分批更新，避免长事务
    UPDATE orders SET shipping_method = 'standard'
    WHERE shipping_method IS NULL AND id BETWEEN 1 AND 10000;
    -- 重复执行直到所有行都有值

  Step 4 (迁移): 添加 NOT NULL 约束
    ALTER TABLE orders ALTER COLUMN shipping_method SET NOT NULL;
    -- 需要扫描全表验证，但不重写数据

  Step 5 (迁移): 添加默认值
    ALTER TABLE orders ALTER COLUMN shipping_method SET DEFAULT 'standard';
```

### 危险操作清单

| 操作 | 风险 | 安全替代 |
|------|------|---------|
| `ALTER TABLE ... ADD COLUMN ... NOT NULL` | 锁表（大表） | 先加可空列 → 回填 → 加约束 |
| `ALTER TABLE ... DROP COLUMN` | 不可逆 | 先在代码中停止使用 → 下个版本再删列 |
| `ALTER TABLE ... ALTER TYPE` | 重写全表 | 新建列 → 迁移数据 → 删旧列 |
| `CREATE INDEX` | 锁表写入 | `CREATE INDEX CONCURRENTLY`（不锁表） |
| `ALTER TABLE ... RENAME COLUMN` | 旧代码立即崩溃 | 先新建列 → 代码读新列 → 再删旧列 |
| `DROP TABLE` | 不可逆 | 先 RENAME → 观察一段时间 → 再 DROP |

### Prisma vs TypeORM 迁移对比

```
Prisma Migrate:
  ✅ 声明式: 你定义目标状态，Prisma 自动生成迁移 SQL
  ✅ 迁移文件可读性好（纯 SQL）
  ✅ 开发和生产使用不同命令（dev vs deploy）
  ⚠️ 不支持 CREATE INDEX CONCURRENTLY
  ⚠️ 需要 shadow database（开发时）

  # 开发: 检测 schema 变更，生成迁移
  npx prisma migrate dev --name add_shipping_method

  # 生产: 只执行迁移（不会自动生成）
  npx prisma migrate deploy

TypeORM:
  ✅ 迁移文件是 TypeScript（可以写复杂逻辑）
  ✅ 支持自定义 SQL
  ⚠️ 命令式: 你需要自己写 UP/DOWN 逻辑
  ⚠️ synchronize: true 在生产环境很危险（自动修改 schema）

  // 生成迁移（对比实体和数据库）
  npx typeorm migration:generate -n AddShippingMethod
  // 执行迁移
  npx typeorm migration:run
```

### 迁移最佳实践

```
1. 生产环境永远不要用 synchronize: true（TypeORM）或 db push（Prisma）
2. 所有迁移必须可回滚（写好 DOWN 方法）
3. 大表变更前在 Stage 环境测试（Optima 的 Stage-ECS 环境）
4. CREATE INDEX 永远用 CONCURRENTLY
5. 迁移脚本和代码部署分开：先迁移 → 再部署新代码
6. 保持向后兼容：新版代码要能读旧 schema，旧代码要能读新 schema
```

---

## 6. 读写分离

### PostgreSQL 流复制（Streaming Replication）

```
写请求 → Primary（主库）
              │
              │ WAL (Write-Ahead Log) 流式传输
              ▼
          Replica（只读副本）← 读请求

WAL 是什么？
  - PostgreSQL 先把变更写入 WAL（预写日志），再写入数据文件
  - WAL 保证崩溃恢复: 即使进程崩溃，重启后从 WAL 重放
  - 流复制: 主库的 WAL 实时发送给副本，副本重放 WAL 来同步数据
```

### RDS Read Replica

```
Optima 当前架构（单实例）:
┌──────────┐     ┌──────────────────────┐
│ 所有服务  │────→│  RDS Primary         │
│          │←────│  (读 + 写)           │
└──────────┘     └──────────────────────┘

读写分离架构（未来）:
┌──────────┐  写 →  ┌──────────────────┐
│ 所有服务  │───────→│  RDS Primary     │
│          │        │  (只处理写)       │
│          │        └──────┬───────────┘
│          │               │ 流复制
│          │  读 →  ┌──────▼───────────┐
│          │←──────│  RDS Read Replica │
│          │       │  (只处理读)        │
└──────────┘       └──────────────────┘

RDS 创建只读副本:
  aws rds create-db-instance-read-replica \
    --db-instance-identifier optima-prod-read \
    --source-db-instance-identifier optima-prod-postgres \
    --db-instance-class db.t3.medium
```

### 复制延迟处理

```
复制延迟（Replication Lag）是读写分离的核心挑战:

  时间线:
  T=0ms   用户提交订单 → 写入 Primary
  T=5ms   Primary 发送 WAL 给 Replica
  T=10ms  Replica 开始重放 WAL
  T=15ms  Replica 重放完成，数据可读

  如果在 T=3ms 时读 Replica → 读不到刚提交的订单！

应对策略:

  1. 写后读走主库（Read-Your-Writes Consistency）
     用户刚执行写操作后，短时间内的读请求走 Primary

     // 伪代码
     async function getOrder(orderId: string, userId: string) {
       const recentWrite = await cache.get(`write:${userId}`);
       if (recentWrite && Date.now() - recentWrite < 5000) {
         return primaryDB.query('SELECT * FROM orders WHERE id = $1', [orderId]);
       }
       return replicaDB.query('SELECT * FROM orders WHERE id = $1', [orderId]);
     }

  2. 同步复制（牺牲写入性能）
     -- 确保至少一个副本确认收到 WAL 后才返回成功
     ALTER SYSTEM SET synchronous_standby_names = 'replica1';
     -- 代价: 写入延迟增加（需要等副本确认）

  3. 监控复制延迟
     -- 在 Replica 上查询延迟
     SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;
     -- 正常: < 100ms
     -- 告警: > 1s
```

### 什么时候需要读写分离

```
Optima 当前需要吗？大概率不需要。

判断依据:
  - 数据库 CPU < 50%？→ 不需要
  - 读写比 < 10:1？→ 不需要
  - 查询延迟 < 100ms？→ 不需要

当前 db.t3.medium 的能力:
  - 2 vCPU, 4GB RAM
  - 支持约 500-1000 QPS（取决于查询复杂度）
  - Optima 当前 QPS 远低于这个水平

什么时候考虑:
  - RDS CPU 持续 > 70%
  - 慢查询优化后仍然有性能问题
  - 读请求占比 > 80%

先做的事（成本更低）:
  1. 优化慢查询（EXPLAIN ANALYZE）
  2. 加适当的索引
  3. 引入 Redis 缓存热点数据（已有 ElastiCache）
  4. 升级实例（t3.medium → t3.large，成本翻倍但简单）
```

---

## 7. 备份与恢复

### RDS 自动快照

```
Optima 的 RDS 备份配置:

  自动快照:
    - 保留期: 7 天（RDS 默认）
    - 备份窗口: 每天自动执行
    - 存储: S3（AWS 管理，不占用户 S3 配额）
    - 类型: 增量快照（只备份变更的数据块）

  手动快照:
    aws rds create-db-snapshot \
      --db-instance-identifier optima-prod-postgres \
      --db-snapshot-identifier optima-prod-manual-20250301
```

### PITR（时间点恢复）

```
场景: 有人误执行了 DELETE FROM users（没有 WHERE）

时间线:
  09:00  正常运行
  09:15  误操作: DELETE FROM users
  09:20  发现问题

PITR 原理:
  RDS 每 5 分钟上传 WAL 到 S3
  恢复 = 最近的快照 + 重放 WAL 到指定时间点

恢复步骤:
  # 恢复到 09:14（误操作前 1 分钟）
  aws rds restore-db-instance-to-point-in-time \
    --source-db-instance-identifier optima-prod-postgres \
    --target-db-instance-identifier optima-prod-restored \
    --restore-time 2025-03-01T09:14:00Z

  # 这会创建一个新的 RDS 实例（不影响原实例）
  # 然后从恢复的实例中导出需要的数据:
  pg_dump -h restored-instance.xxx.rds.amazonaws.com \
    -U admin -d optima_auth -t users \
    > users_backup.sql

  # 导入到原实例:
  psql -h original-instance.xxx.rds.amazonaws.com \
    -U admin -d optima_auth \
    < users_backup.sql
```

### 逻辑备份 vs 物理备份

```
逻辑备份（pg_dump）:
  ✅ 可以备份单个数据库 / 单个表
  ✅ 输出是 SQL 文本或自定义格式，可读
  ✅ 可以跨 PostgreSQL 版本恢复
  ✅ 可以选择性恢复
  ❌ 备份和恢复速度慢（大数据库）
  ❌ 备份期间不保证一致性快照（除非加 --serializable-deferrable）

  # 备份 Optima 的 commerce 数据库
  pg_dump -h optima-prod-postgres.xxx.rds.amazonaws.com \
    -U commerce_user -d optima_commerce \
    -Fc -f optima_commerce_$(date +%Y%m%d).dump

  # 恢复
  pg_restore -h target-host -U commerce_user \
    -d optima_commerce \
    optima_commerce_20250301.dump

物理备份（RDS 快照）:
  ✅ 速度快（块级别复制）
  ✅ 一致性快照
  ✅ PITR 支持
  ❌ 只能恢复整个实例（不能恢复单个数据库）
  ❌ 不能跨大版本恢复
  ❌ 恢复 = 创建新实例（需要修改连接配置）
```

### 备份策略建议

```
Optima 的分层备份策略:

  第一层: RDS 自动快照（已有）
    - 保留 7 天
    - 自动 PITR
    - 零运维成本

  第二层: 每日逻辑备份（建议添加）
    - 每天 pg_dump 关键数据库到 S3
    - 保留 30 天
    - 可选择性恢复单个表
    - 脚本:

    #!/bin/bash
    DATABASES=(optima_auth optima_commerce optima_chat optima_mcp)
    DATE=$(date +%Y%m%d)
    for DB in "${DATABASES[@]}"; do
      pg_dump -h $RDS_HOST -U admin -d $DB -Fc \
        -f /tmp/${DB}_${DATE}.dump
      aws s3 cp /tmp/${DB}_${DATE}.dump \
        s3://optima-prod-storage/backups/daily/${DB}_${DATE}.dump
      rm /tmp/${DB}_${DATE}.dump
    done

  第三层: 重大变更前手动快照
    - 数据库迁移前
    - 大批量数据更新前
    - 架构变更前
```

---

## 8. 分库分表思路

### 什么时候才需要分片

```
分片（Sharding）是最后手段，不是第一选择。

90% 的应用永远不需要分片。Optima 当前和可预见的未来都不需要。

判断阶梯:

  1. 单表 < 1000 万行？ → 优化索引就够了
  2. 单表 < 1 亿行？ → 分区表（Table Partitioning）
  3. 单表 > 1 亿行 + 写入瓶颈？→ 考虑分片
  4. 单机存储不够？→ 考虑分片

Optima 的情况:
  - 100GB GP3 存储
  - 最大的表（orders）估计 < 100 万行
  - 还远远不到需要分片的程度

在分片之前，先把这些做了:
  1. 查询优化（索引 + EXPLAIN ANALYZE）
  2. 读写分离
  3. 缓存热点数据（Redis）
  4. 表分区（按时间分区 orders 表）
  5. 升级实例规格
  6. 归档历史数据
```

### 水平分片策略

```
水平分片: 同一张表的数据分散到多个数据库

分片键（Shard Key）选择:

  ✅ 好的分片键: merchant_id
    - 同一个商户的数据在同一个分片
    - 大多数查询都带 merchant_id（天然过滤）
    - 分布相对均匀

  ❌ 差的分片键: created_at
    - 最新数据全在一个分片（热点）
    - 旧分片基本空闲
    - 跨分片查询困难

  ❌ 差的分片键: order_id
    - 随机分布，无法利用数据局部性
    - 按 merchant 查询需要查所有分片

分片路由:

  取模法: shard_id = hash(merchant_id) % shard_count
    简单但扩容困难（需要重新分配数据）

  一致性哈希: 扩容时只迁移少量数据
    复杂但弹性好

  范围分片: merchant_id A-M → shard1, N-Z → shard2
    简单但容易不均匀
```

### PostgreSQL 表分区

在需要分片之前，**表分区**能解决大部分问题。

```sql
-- 按月分区 orders 表
CREATE TABLE orders (
    id          BIGSERIAL,
    merchant_id VARCHAR(50),
    status      VARCHAR(20),
    total       DECIMAL(10,2),
    created_at  TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (id, created_at)  -- 分区键必须包含在主键中
) PARTITION BY RANGE (created_at);

-- 创建月分区
CREATE TABLE orders_2025_01 PARTITION OF orders
  FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');
CREATE TABLE orders_2025_02 PARTITION OF orders
  FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');
-- ...

-- 查询时 PostgreSQL 自动只扫描相关分区
SELECT * FROM orders
WHERE created_at >= '2025-03-01' AND created_at < '2025-04-01';
-- → 只扫描 orders_2025_03 分区

-- 归档: 直接 detach 旧分区
ALTER TABLE orders DETACH PARTITION orders_2024_01;
-- orders_2024_01 变成独立表，可以单独备份后删除
```

### Citus 和 RDS Proxy 简介

```
Citus（分布式 PostgreSQL 扩展）:
  - 把 PostgreSQL 变成分布式数据库
  - 对应用透明: SQL 语法不变
  - 自动分片 + 跨分片查询
  - Azure 提供托管版（Cosmos DB for PostgreSQL）
  - AWS 上需要自建（EC2 上安装 Citus 扩展）

  适用场景:
  - 多租户 SaaS（按 tenant_id 分片）← Optima 如果需要分片，Citus 是好选择
  - 实时分析（并行查询多个分片）

RDS Proxy:
  - AWS 托管的连接池（替代自建 PgBouncer）
  - 自动故障转移（主库故障时自动切换到备库）
  - 与 IAM 集成（不需要在连接串中硬编码密码）
  - 成本: 按 vCPU 计费，比自建 PgBouncer 贵

  适用场景:
  - Lambda + RDS（Lambda 并发高，连接数暴增）
  - 需要自动故障转移

  Optima 暂时不需要:
  - ECS 服务连接数可控
  - 没有 Lambda 函数连接数据库
  - PgBouncer（如果需要的话）更经济
```

---

## 容量规划：Optima 的 100GB GP3

```
当前 RDS 存储: 100GB GP3

GP3 性能:
  基线 IOPS: 3000（免费）
  基线吞吐: 125 MB/s（免费）
  可扩展到: 16000 IOPS / 1000 MB/s（按需付费）

容量估算:

  PostgreSQL 系统开销:     ~2GB
  WAL 文件（未归档）:       ~1-2GB

  各数据库估算:
  ┌────────────────┬────────┬────────────┐
  │ 数据库          │ 当前    │ 年增长预估  │
  ├────────────────┼────────┼────────────┤
  │ optima_auth    │ ~500MB │ ~200MB/年   │
  │ optima_commerce│ ~2GB   │ ~5GB/年     │
  │ optima_chat    │ ~3GB   │ ~10GB/年    │
  │ optima_mcp     │ ~500MB │ ~1GB/年     │
  │ Stage 数据库    │ ~1GB   │ ~2GB/年     │
  │ Infisical      │ ~200MB │ ~100MB/年   │
  ├────────────────┼────────┼────────────┤
  │ 合计           │ ~7GB   │ ~18GB/年    │
  └────────────────┴────────┴────────────┘

  100GB 够用约 5 年（不考虑 VACUUM 和索引膨胀）
  实际上 50-60% 使用率时就应该扩容（~60GB 时告警）

监控:
  -- 查看各数据库大小
  SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
  FROM pg_database
  WHERE datistemplate = false
  ORDER BY pg_database_size(datname) DESC;

  -- 查看最大的表
  SELECT schemaname, tablename,
         pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
         pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS data_size,
         pg_size_pretty(pg_indexes_size(schemaname||'.'||tablename)) AS index_size
  FROM pg_tables
  WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
  ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
  LIMIT 20;
```

---

## 实践路线

### 立即可做

1. **在 Stage 环境跑一次 EXPLAIN ANALYZE**: 找出最慢的 5 条 SQL
2. **检查缺失索引**: 查看 `pg_stat_user_tables` 中 `seq_scan` 远大于 `idx_scan` 的表
3. **查看表膨胀**: 检查 dead tuples 比例
4. **审计 ORM 配置**: 确认 Prisma/TypeORM 的连接池大小合理

```sql
-- 找缺失索引的表
SELECT relname, seq_scan, idx_scan,
       seq_scan - idx_scan AS excess_seq_scan,
       pg_size_pretty(pg_relation_size(relid)) AS table_size
FROM pg_stat_user_tables
WHERE seq_scan > idx_scan
  AND pg_relation_size(relid) > 1048576  -- > 1MB 的表
ORDER BY seq_scan - idx_scan DESC;

-- 找慢查询（需要开启 pg_stat_statements 扩展）
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT query, calls, mean_exec_time, total_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```

### 短期（1-2 周）

5. **开启 RDS Performance Insights**: 在 AWS Console 中开启，监控慢查询
6. **审计迁移脚本**: 确认所有 `CREATE INDEX` 都用了 `CONCURRENTLY`
7. **制定连接数预算**: 根据上面的公式计算各服务的合理连接数

### 中期（1-2 月）

8. **添加逻辑备份**: 每日 `pg_dump` 到 S3
9. **建立容量监控告警**: 存储使用率 > 60% 时告警
10. **评估 PgBouncer**: 如果服务扩容到 3+ task 时考虑引入

---

## 推荐资源

| 资源 | 类型 | 时间 | 说明 |
|------|------|------|------|
| **[The Art of PostgreSQL](https://theartofpostgresql.com/)** | 书 | 1-2 周 | **最高优先级**，从 SQL 到高级特性，大量实战示例 |
| **[PostgreSQL Internals](https://postgrespro.com/community/books/internals)** | 书 | 2-3 周 | 深入存储引擎、MVCC、WAL，理解"为什么"而非"怎么用" |
| [Use The Index, Luke](https://use-the-index-luke.com/) | 在线书 | 3-5 天 | 索引原理的最佳免费教程，从 B-tree 到执行计划 |
| **[PostgreSQL 官方文档 - Indexes](https://www.postgresql.org/docs/current/indexes.html)** | 文档 | 2h | 各种索引类型的权威说明 |
| [PostgreSQL 官方文档 - EXPLAIN](https://www.postgresql.org/docs/current/using-explain.html) | 文档 | 1h | 读懂执行计划的官方指南 |
| [PostgreSQL 官方文档 - MVCC](https://www.postgresql.org/docs/current/mvcc.html) | 文档 | 1h | 事务隔离和并发控制 |
| [DDIA 第 3 章 (Storage and Retrieval)](https://dataintensive.net/) | 书 | 1 天 | 从 LSM-Tree 到 B-tree，理解存储引擎的设计选择 |
| [DDIA 第 7 章 (Transactions)](https://dataintensive.net/) | 书 | 1 天 | 事务隔离级别的深度解析 |
| [PgBouncer 文档](https://www.pgbouncer.org/) | 文档 | 1h | 连接池的配置和模式选择 |
| [Citus 文档](https://docs.citusdata.com/) | 文档 | 2h | 了解分布式 PostgreSQL 的思路 |

### 实践练习

```
1. 本地跑 EXPLAIN ANALYZE
   - 用 Docker 启动 PostgreSQL: docker run -p 5432:5432 -e POSTGRES_PASSWORD=test postgres:15
   - 创建一个 100 万行的测试表
   - 对比有索引和没索引的查询性能
   - 观察 Seq Scan → Index Scan 的变化

2. 模拟死锁
   - 开两个 psql 会话
   - 按不同顺序 UPDATE 两行
   - 观察 PostgreSQL 如何检测和解决死锁

3. 模拟 PITR
   - 在 Stage RDS 上做一次手动快照
   - 插入测试数据
   - 从快照恢复到插入前的时间点
   - 验证数据确实回到了过去的状态

4. 查看 Optima 数据库现状
   - 连接 Stage RDS
   - 运行本文中的"找缺失索引"和"表膨胀"查询
   - 记录发现的问题
```
