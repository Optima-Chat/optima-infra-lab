# 03 - 负载测试与容量规划

> 学会用数据而非直觉做架构决策

---

## 我们现在在哪

Phase 3 的预热池设计中：

```
config = {
  minSize: 3,            // ← 这个数字怎么来的？
  maxSize: 10,           // ← 这个呢？
  replenishThreshold: 2, // ← 还有这个？
}
```

答案是：拍脑袋。

我们不知道：
- 系统能承受多少并发用户
- 瓶颈在哪里（CPU？内存？ECS API 限流？WebSocket 连接数？）
- 在什么负载下 P99 延迟会超过 SLO

没有负载测试，所有容量决策都是猜测。

---

## 核心概念

### Testing Pyramid（测试金字塔）

```
        /\
       /  \       E2E Tests（少量，慢，贵）
      /    \      → 完整用户流程，浏览器级别
     /──────\
    /        \    Integration Tests（适量）
   /          \   → 服务间调用，API 级别
  /────────────\
 /              \ Unit Tests（大量，快，便宜）
/________________\→ 单个函数/类
```

你目前有：
- Unit Tests: `.test.ts` 文件不少 ✅
- Integration Tests: `scripts/ai-shell/test-*.sh` ✅
- E2E Tests: optima-e2e-tests 项目存在 ⚠️（成熟度未知）
- **Load Tests: 完全没有** ❌
- **Chaos Tests: 完全没有** ❌

### Load Test vs Stress Test vs Soak Test

| 类型 | 目的 | 时长 | 负载 |
|------|------|------|------|
| **Load Test** | 验证系统在预期负载下的表现 | 5-15 分钟 | 正常流量 |
| **Stress Test** | 找到系统的极限 | 15-30 分钟 | 逐渐增加到崩溃 |
| **Soak Test** | 检测长时间运行的问题（内存泄漏等）| 数小时 | 持续中等负载 |
| **Spike Test** | 验证突发流量的处理能力 | 5-10 分钟 | 突然飙升 |

**我们最需要的**: Load Test（正常表现）+ Stress Test（找极限）。

---

## 工具选择：k6

**为什么选 k6**:
- 用 JavaScript/TypeScript 写测试脚本（你已经熟悉）
- 支持 WebSocket 协议（我们的核心通信方式）
- 输出结构化指标（P50/P90/P99）
- 开源免费，CLI 工具无需额外基础设施
- Grafana Labs 维护，社区活跃

**安装**:

```bash
# macOS
brew install k6

# Linux
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D68
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | \
  sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install k6

# Docker
docker run --rm -i grafana/k6 run - <script.js
```

---

## 实战：AI Shell 负载测试

### 测试 1: Session 创建延迟

```javascript
// k6-session-create.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';

// 自定义指标
const sessionCreateDuration = new Trend('session_create_duration');
const sessionCreateErrors = new Counter('session_create_errors');

export const options = {
  // 阶梯式增加负载
  stages: [
    { duration: '1m', target: 5 },   // 1 分钟内增加到 5 个并发用户
    { duration: '3m', target: 5 },   // 保持 5 个并发 3 分钟
    { duration: '1m', target: 10 },  // 增加到 10 个并发
    { duration: '3m', target: 10 },  // 保持 10 个并发 3 分钟
    { duration: '1m', target: 0 },   // 降到 0（冷却）
  ],
  thresholds: {
    'session_create_duration': ['p(99)<10000'],  // P99 < 10s
    'session_create_errors': ['count<5'],         // 错误 < 5 次
  },
};

const BASE_URL = __ENV.API_URL || 'https://shell.optima.shop';
const TOKEN = __ENV.TOKEN;

export default function () {
  // 1. 创建 session
  const start = Date.now();
  const createRes = http.post(`${BASE_URL}/api/sessions`, null, {
    headers: { 'Authorization': `Bearer ${TOKEN}` },
  });

  if (createRes.status === 201) {
    sessionCreateDuration.add(Date.now() - start);
    const session = JSON.parse(createRes.body);
    check(createRes, { 'session created': (r) => r.status === 201 });

    // 清理: 删除 session
    sleep(1);
    http.del(`${BASE_URL}/api/sessions/${session.id}`, null, {
      headers: { 'Authorization': `Bearer ${TOKEN}` },
    });
  } else {
    sessionCreateErrors.add(1);
  }

  sleep(2); // 模拟用户操作间隔
}
```

### 测试 2: WebSocket 消息延迟

```javascript
// k6-ws-message.js
import ws from 'k6/ws';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const messageRoundtrip = new Trend('message_roundtrip');

export const options = {
  stages: [
    { duration: '2m', target: 3 },   // 3 个并发 WebSocket 连接
    { duration: '5m', target: 3 },
    { duration: '1m', target: 0 },
  ],
};

const WS_URL = __ENV.WS_URL || 'wss://shell.optima.shop';
const TOKEN = __ENV.TOKEN;

export default function () {
  const url = `${WS_URL}?token=${TOKEN}`;

  const res = ws.connect(url, {}, function (socket) {
    socket.on('open', () => {
      // 等待 session ready
      socket.setTimeout(function () {
        const sendTime = Date.now();

        // 发送消息
        socket.send(JSON.stringify({
          type: 'message',
          message: 'echo hello',  // 简单命令，测试延迟
        }));

        socket.on('message', (data) => {
          const msg = JSON.parse(data);
          if (msg.type === 'text' || msg.type === 'complete') {
            messageRoundtrip.add(Date.now() - sendTime);
            socket.close();
          }
        });
      }, 10000); // 等 10s 让 session 就绪
    });

    socket.on('error', (e) => {
      console.error('WS error:', e);
    });

    socket.setTimeout(function () {
      socket.close();
    }, 60000); // 最多 60s
  });

  check(res, { 'ws connected': (r) => r && r.status === 101 });
}
```

### 运行测试

```bash
# 先生成测试 token
source scripts/ai-shell/test-env.sh

# 运行负载测试
k6 run --env API_URL=$API_URL --env TOKEN=$TOKEN k6-session-create.js

# 查看结果
# k6 会输出类似：
#   session_create_duration
#     p(50): 3200ms
#     p(90): 5800ms
#     p(99): 12500ms
#   session_create_errors: 2
```

---

## 如何解读结果

### 关键指标

```
✓ http_req_duration ........... p(50)=120ms p(90)=280ms p(99)=1.2s
✗ session_create_duration ..... p(50)=3.2s  p(90)=5.8s  p(99)=12.5s
  ├── p(99) > 10s threshold  → FAIL
✓ session_create_errors ....... count=2 < 5
```

- **P50**: 一半的请求快于这个值（"正常体验"）
- **P90**: 90% 的请求快于这个值（"大多数用户的体验"）
- **P99**: 99% 的请求快于这个值（"最差体验"，你应该关注这个）
- **为什么不看平均值**: 平均值会被少量极端值拉偏，P99 更能反映真实的用户体验

### 瓶颈定位

如果 P99 不达标，需要结合 Phase 1 的 lifecycle 埋点找到瓶颈：

```
session_create_duration P99 = 12.5s，拆解：
  access_point_ms      P99 = 2.0s   ← 有时候 EFS API 慢？
  register_taskdef_ms  P99 = 0.8s   ← 正常
  run_task_ms          P99 = 0.3s   ← 正常
  pending_to_running   P99 = 6.5s   ← 瓶颈！EC2 容量不足？
  wait_connection_ms   P99 = 2.9s   ← 偏高
```

找到瓶颈后，优化才有方向。

---

## 容量规划

### 从测试数据到配置决策

```
假设测试得到：
  - 单个 EC2 t3.large 稳定支撑 15 个并发 session
  - 超过 15 个后 P99 急剧上升
  - 每个 session 平均持续 8 分钟
  - 高峰时段每小时 30 个新 session

计算：
  峰值并发 = 30 sessions/hour × 8 min / 60 min = 4 个并发
  安全系数 2x = 8 个并发
  单台容量 15 → 1 台 EC2 够用

  预热池大小：
  新 session 到达率 = 30/hour = 0.5/min
  预热 task 生命周期 = 5 min（超时回收）
  最小池大小 = 到达率 × 冷启动时间 = 0.5/min × 0.1min = 0.05 ≈ 1
  安全系数 3x = 3 个 ← 现在这个数字有依据了
```

### 没有测试数据时的经验法则

如果暂时跑不了负载测试，这些经验数据可以参考：

| 资源 | 单 session 占用 | t3.large 容量 |
|------|----------------|---------------|
| 内存 | ~200-500MB（含 optima-agent） | 8GB → 约 16 个 session |
| CPU | ~0.2 vCPU（空闲时） | 2 vCPU → 约 10 个 session |
| WebSocket 连接 | 2 个（客户端 + task） | 系统限制 ~65k |
| EFS 并发挂载 | 1 个 | 无限制 |

**瓶颈通常在内存**，因为每个 optima-agent 进程（Node.js）会占用较多内存。

---

## Chaos Engineering 基础

**理念**: 主动注入故障，验证系统在异常条件下的行为。

### 手动 Chaos（立即可做）

在 Stage 环境手动模拟故障场景：

```bash
# 1. 杀掉一个运行中的 ECS task
aws ecs stop-task --cluster optima-stage-cluster --task <taskArn> --reason "chaos test"
# 验证: 用户是否收到错误通知？重连是否成功？

# 2. 模拟 EFS 延迟
# 在容器中: tc qdisc add dev eth0 root netem delay 2000ms
# 验证: session 创建是否在 timeout 内完成？

# 3. 模拟 EC2 容量不足
# 把 ASG desired 设为 0，所有 RunTask 会失败
# 验证: 用户是否看到明确的错误信息？

# 4. 快速断开重连 10 次
# 验证: 不会创建 10 个 task？资源正确清理？
```

### 自动化 Chaos（后续）

- **AWS Fault Injection Service (FIS)**: 可以自动注入 ECS task 终止、网络延迟等故障
- **Netflix Chaos Monkey**: 随机杀 pod/task
- 对我们的规模，手动 + 脚本化就够了

---

## 实践路线

### 立即可做（1 天）

1. 安装 k6
2. 写一个最简单的 HTTP 测试（session 创建），跑一次
3. 记录基线数据：P50/P90/P99

### 短期（Phase 1 完成后）

4. 结合 lifecycle 埋点，拆解 session 创建延迟的各阶段
5. 写 WebSocket 测试，测量消息往返延迟
6. 手动在 Stage 做一次 Chaos 测试（杀 task、断网）

### 中期（Phase 3 之前）

7. Stress Test: 逐渐增加并发，找到系统极限
8. 用测试数据计算预热池大小和 EC2 容量
9. 设定 SLO，把负载测试作为发布前的 gate

---

## 推荐资源

| 资源 | 类型 | 时间 | 说明 |
|------|------|------|------|
| [k6 Getting Started](https://grafana.com/docs/k6/latest/) | 文档 | 2h | 快速上手，包含 WebSocket 示例 |
| [k6 WebSocket 测试指南](https://grafana.com/docs/k6/latest/javascript-api/k6-ws/) | 文档 | 1h | 我们核心需要的 |
| [Google SRE Book Ch18: Load Balancing](https://sre.google/sre-book/load-balancing-frontend/) | 书 | 2h | 理解容量规划的原理 |
| [Principles of Chaos Engineering](https://principlesofchaos.org/) | 网站 | 30min | Chaos Engineering 的宣言 |
| [AWS Fault Injection Service](https://aws.amazon.com/fis/) | 文档 | 按需 | 当我们需要自动化 Chaos 时 |
