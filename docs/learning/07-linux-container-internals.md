# 07 - Linux 与容器底层原理

> 容器不是轻量级虚拟机——它是被限制了视野和资源的 Linux 进程

---

## 我们现在在哪

```
Optima 的容器使用现状：

✅ 能用的:
  - Docker Compose (Prod) / ECS Task Definition (Stage-ECS) 部署服务
  - 多阶段构建（user-auth、mcp-host 等 Node.js 服务）
  - ECR 镜像推送 + ECS 滚动更新
  - TaskDef 中配置了 CPU/Memory 限制

⚠️ 不清楚底层的:
  - 为什么容器里 PID 1 挂了整个容器就停了？
  - 为什么 ECS Task 的 Memory 限制是硬限制而 CPU 是软限制？
  - 为什么 Docker 镜像有"层"？改了一行代码为什么要重新 npm install？
  - SIGTERM 发给容器后到底发生了什么？ECS 的 stopTimeout 是怎么工作的？
  - 为什么 Node.js 的 event loop 在容器里有时表现异常？
```

这一章不是教你怎么写 Dockerfile（你已经会了），而是让你**理解容器的本质**——它只是 Linux 内核提供的隔离和限制机制的组合。理解了这个，你就能解释上面所有问题。

---

## 1. Linux 进程模型

### 你已经知道的

进程是运行中的程序。`node index.js` 会创建一个进程。

### 你需要深入理解的

#### fork/exec 模型

Linux 创建新进程只有一种方式：**fork**。

```
父进程 (PID 100)
  │
  ├── fork() ──→ 子进程 (PID 101)    ← 完整复制父进程的内存空间
  │                 │
  │                 └── exec("node")  ← 用 node 程序替换自身
  │
  └── 继续执行
```

**为什么这很重要**: Docker 的 `CMD` 和 `ENTRYPOINT` 最终都是通过 fork/exec 来启动你的应用的。理解这个模型，才能理解后面的 PID 1 问题。

#### 进程树

Linux 的所有进程构成一棵树，根节点是 PID 1（init 进程）：

```
PID 1 (init/systemd)
├── PID 100 (sshd)
│   └── PID 200 (bash)
│       └── PID 300 (node index.js)
│           ├── PID 301 (worker thread)
│           └── PID 302 (worker thread)
├── PID 110 (dockerd)
│   └── PID 400 (containerd-shim)
│       └── PID 500 (node server.js)  ← 容器内的 PID 1
└── PID 120 (cron)
```

#### PID 1 问题——容器中的 init 进程

**在宿主机上**: PID 1 是 systemd/init，它有两个特殊职责：
1. **收割僵尸进程**: 当子进程退出后，父进程需要调用 `wait()` 读取子进程的退出状态，否则子进程变成 zombie。如果父进程先退出，孤儿进程会被 PID 1 收养并负责收割。
2. **信号转发**: PID 1 不会被未注册的信号终止（`SIGTERM` 默认被忽略）。

**在容器中**: 你的应用进程直接就是 PID 1：

```dockerfile
# user-auth 的 Dockerfile
CMD ["node", "dist/index.js"]
# node 进程在容器内是 PID 1
```

**问题 1 — 僵尸进程**:

如果你的 Node.js 服务 spawn 了子进程（比如 AI Shell 中的 `optima-agent` 通过 shell 工具执行命令），这些子进程退出后如果没有被正确 `wait()`，就会变成 zombie。普通进程不会自动收割不是自己 fork 的子进程。

```bash
# 在容器内查看僵尸进程
$ ps aux | grep Z
USER  PID  STAT  COMMAND
root  42   Z     [sh] <defunct>   ← 僵尸进程
root  58   Z     [sh] <defunct>
```

**问题 2 — 信号处理**:

Node.js 作为 PID 1 时，`SIGTERM` 的默认行为（终止进程）**不会生效**，因为 PID 1 对未注册的信号有特殊豁免。你必须显式注册信号处理：

```typescript
// 必须在代码中显式处理 SIGTERM
process.on('SIGTERM', () => {
  console.log('收到 SIGTERM，开始优雅停机...');
  server.close(() => {
    process.exit(0);
  });
});
```

**解决方案 — tini**:

使用轻量级 init 进程 `tini` 作为 PID 1，它负责信号转发和僵尸进程收割：

```dockerfile
# 方案 1: 使用 tini
RUN apk add --no-cache tini
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/index.js"]

# 方案 2: Docker 内置 --init 标志（docker run --init）
# ECS 不直接支持，但 tini 方案在任何环境都有效
```

**对应 Optima**: AI Shell 的 session-gateway 会 spawn 子进程（容器内的 agent task），如果没有正确处理 PID 1 职责，可能累积僵尸进程。ECS Task 的 `stopTimeout`（默认 30 秒）发送 SIGTERM 后，如果 PID 1 不处理信号，30 秒后 ECS 会发送 SIGKILL 强制杀死。

---

## 2. 文件描述符与 IO 模型

### 文件描述符 (File Descriptor)

Linux 中"一切皆文件"。每个进程打开的文件、socket、管道都通过一个整数（文件描述符 fd）来引用：

```
fd 0 → stdin  (标准输入)
fd 1 → stdout (标准输出)
fd 2 → stderr (标准错误)
fd 3 → TCP socket (监听 8000 端口)
fd 4 → 数据库连接
fd 5 → /var/log/app.log
...
```

**为什么这很重要**:

- `docker logs` 之所以能工作，是因为 Docker 捕获了容器进程的 fd 1 和 fd 2
- ECS CloudWatch Logs 驱动也是通过重定向 stdout/stderr 来收集日志的
- 如果你的 Node.js 服务用 `fs.writeFileSync()` 写日志文件而不是 `console.log()`，Docker/ECS 的日志系统就**抓不到**

**文件描述符上限**:

```bash
# 查看进程的 fd 上限
$ ulimit -n
1024    # 默认值，对高并发服务太小

# 每个 WebSocket 连接 = 1 个 fd
# session-gateway 如果同时有 500 个 WS 连接，就需要至少 500 个 fd
```

ECS Task 的默认 `ulimit` 配置可以在 Task Definition 中调整：

```json
{
  "containerDefinitions": [{
    "ulimits": [{
      "name": "nofile",
      "softLimit": 65536,
      "hardLimit": 65536
    }]
  }]
}
```

### IO 模型

理解 IO 模型是理解 Node.js 性能特性的基础。

#### 阻塞 IO (Blocking IO)

```
线程: ──请求数据──│等待内核准备数据......│拿到数据──处理──
                  ↑ 线程在这里卡住了
```

传统做法（如 Java Servlet）：每个请求一个线程，线程在等 IO 时被阻塞。500 个并发请求 = 500 个线程 = 大量内存。

#### 非阻塞 IO + IO 多路复用 (epoll)

```
单线程:
  ├── 注册 fd3 (客户端A的连接) 到 epoll
  ├── 注册 fd4 (客户端B的连接) 到 epoll
  ├── 注册 fd5 (数据库连接) 到 epoll
  │
  └── epoll_wait()  ← 阻塞在这里，等任何一个 fd 就绪
        │
        ├── fd3 就绪 → 处理客户端A的请求
        ├── fd5 就绪 → 读取数据库结果
        └── fd4 就绪 → 处理客户端B的请求
```

**epoll** 是 Linux 特有的 IO 多路复用机制，可以高效地监控成千上万个文件描述符。

#### Node.js Event Loop 的本质

Node.js 的 event loop 底层就是 **libuv + epoll**（Linux 上）：

```
┌──────────────────────────────────────────┐
│           Node.js Event Loop             │
│                                          │
│  ┌────────────────────────────────────┐  │
│  │ 1. Timers (setTimeout/setInterval) │  │
│  └──────────────┬─────────────────────┘  │
│  ┌──────────────┴─────────────────────┐  │
│  │ 2. I/O callbacks                   │  │
│  └──────────────┬─────────────────────┘  │
│  ┌──────────────┴─────────────────────┐  │
│  │ 3. Poll (epoll_wait)    ← 核心！    │  │
│  │    等待新的 IO 事件                  │  │
│  └──────────────┬─────────────────────┘  │
│  ┌──────────────┴─────────────────────┐  │
│  │ 4. Check (setImmediate)            │  │
│  └──────────────┬─────────────────────┘  │
│  ┌──────────────┴─────────────────────┐  │
│  │ 5. Close callbacks                 │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
```

**对 Optima 的启示**:

- session-gateway 处理 WebSocket 连接，每个连接是一个 fd，通过 epoll 实现高并发。**单个 Node.js 进程就能处理几千个并发 WS 连接**，不需要多线程。
- 但如果你在 event loop 中执行 CPU 密集操作（如大量 JSON 解析、加密计算），会**阻塞整个 event loop**，所有连接都会卡住。
- 这就是为什么 `optima-agent` 的 AI 推理不应该在 session-gateway 的主进程中执行，而是分离到独立的 ECS Task 中。

**容器中的陷阱 — CPU 限制与 event loop**:

```
宿主机: 4 核 CPU
容器限制: 0.25 vCPU (256 CPU units in ECS)

Node.js 看到的 CPU 核数: 4  ← 它看到的是宿主机的核数！
实际可用: 0.25 核

后果:
  - os.cpus().length 返回 4（错误信息）
  - 如果根据 CPU 核数启动 worker，会过度竞争
  - libuv 的线程池默认 4 个线程，在 0.25 vCPU 上可能过多
```

设置 `UV_THREADPOOL_SIZE` 环境变量来匹配实际可用 CPU：

```json
// ECS Task Definition
{
  "containerDefinitions": [{
    "environment": [
      { "name": "UV_THREADPOOL_SIZE", "value": "2" }
    ]
  }]
}
```

---

## 3. Linux Namespace — 隔离的实现

Namespace 是容器隔离的核心机制。它让容器内的进程**看到**一个独立的系统视图。

```
没有 Namespace:
  所有进程看到同一个进程列表、同一个网络栈、同一个文件系统

有了 Namespace:
  容器内的进程只看到自己的进程列表、自己的网络栈、自己的文件系统
  ← 但实际上它们都运行在同一个内核上
```

### 六大 Namespace

| Namespace | 隔离的资源 | 容器中的效果 |
|-----------|-----------|-------------|
| **PID** | 进程 ID 空间 | 容器内只看到自己的进程，PID 从 1 开始 |
| **NET** | 网络栈 | 容器有独立的网卡、IP、端口、路由表 |
| **MNT** | 挂载点 | 容器有独立的文件系统视图 |
| **UTS** | 主机名 | 容器有独立的 hostname |
| **IPC** | 进程间通信 | 容器有独立的共享内存、信号量 |
| **USER** | 用户/组 ID | 容器内的 root 可以映射为宿主机的普通用户 |

#### PID Namespace

```
宿主机视角:                         容器内视角:
PID 1    systemd                   PID 1    node server.js
PID 2200 containerd                PID 12   sh healthcheck.sh
PID 3100 node server.js  ────→
PID 3115 sh healthcheck.sh ──→
```

容器内的 PID 1 实际上是宿主机上的 PID 3100。这就是为什么 `docker top` 和容器内的 `ps` 看到不同的 PID。

#### NET Namespace

```
宿主机:                               容器:
┌─────────────────────┐              ┌──────────────────┐
│ eth0: 172.31.16.5   │              │ eth0: 172.17.0.2 │ ← 虚拟网卡
│ lo: 127.0.0.1       │              │ lo: 127.0.0.1    │
│                     │              │                  │
│ 端口 80 → Nginx     │    veth      │ 端口 8000 → node │
│ 端口 8000 → ?       │◄───pair────►│                  │
└─────────────────────┘              └──────────────────┘
                                     docker0 网桥连接
```

**为什么容器端口需要映射**: 容器有自己独立的网络栈，容器内监听 8000 端口和宿主机的 8000 端口**不是同一个**。`docker run -p 8080:8000` 就是在宿主机上创建 iptables 规则，把宿主机 8080 的流量转发到容器的 8000。

**对应 ECS**: ECS 的 `awsvpc` 网络模式给每个 Task 分配一个独立的 ENI（弹性网络接口），每个 Task 有自己的 IP 地址。这比 Docker 的端口映射更干净——不需要端口映射，直接用 Task IP + 容器端口访问。

#### MNT Namespace

容器有独立的文件系统挂载点视图。容器看到的 `/` 是 overlay 文件系统（后面会讲），而不是宿主机的 `/`。

```bash
# 宿主机上
$ ls /
bin  boot  dev  etc  home  ...  var

# 容器内
$ ls /
app  bin  dev  etc  home  lib  ...  var
# 这是镜像构建时打包的文件系统，和宿主机完全不同
```

但 Volume 挂载（`-v /host/path:/container/path`）会在 MNT namespace 中添加一个绑定挂载，让容器能访问宿主机的特定目录。ECS 中的 EFS 挂载也是同样的原理。

#### USER Namespace

```
宿主机:          容器内:
uid 1000  ←───→  uid 0 (root)
uid 1001  ←───→  uid 1000
```

容器内的 root (uid 0) 实际上是宿主机上的普通用户 (uid 1000)。这提供了额外的安全层——即使容器逃逸，攻击者也只是宿主机上的普通用户。

**注意**: Docker 默认**不启用** User Namespace。这意味着容器内的 root 就是宿主机的 root——这是一个重要的安全考量（参见 04-container-security.md）。

### 动手实验：用 unshare 创建 namespace

不需要 Docker，直接用 Linux 命令体验 namespace 隔离：

```bash
# 创建新的 PID + MNT namespace（需要 root）
$ sudo unshare --pid --mount --fork bash

# 挂载新的 /proc（否则 ps 看到的还是宿主机的进程）
$ mount -t proc proc /proc

# 现在查看进程
$ ps aux
USER  PID  ...  COMMAND
root    1  ...  bash     ← 只有自己！PID 从 1 开始
root    6  ...  ps aux

# 退出
$ exit
```

```bash
# 创建新的 NET namespace
$ sudo unshare --net bash

$ ip addr
1: lo: <LOOPBACK> ...        ← 只有 loopback，没有 eth0
# 这就是一个完全隔离的网络栈

$ exit
```

```bash
# 创建新的 UTS namespace（改 hostname）
$ sudo unshare --uts bash
$ hostname container-demo
$ hostname
container-demo               ← 不影响宿主机的 hostname
$ exit
```

**这就是容器的本质**: Docker/containerd 做的事情就是把这六个 namespace 组合起来，再加上 cgroups 和 overlay filesystem。

---

## 4. Cgroups v2 — 资源限制的实现

Namespace 解决"看到什么"的问题，Cgroups 解决"能用多少"的问题。

### Cgroups (Control Groups) 是什么

```
Linux 内核的资源限制机制：

进程 ──→ cgroup ──→ 资源控制器
                     ├── cpu: CPU 时间分配
                     ├── memory: 内存上限
                     ├── io: 磁盘 IO 带宽
                     ├── pids: 最大进程数
                     └── cpuset: 绑定到特定 CPU 核
```

### Cgroups v1 vs v2

```
v1 (旧):
  /sys/fs/cgroup/
  ├── cpu/
  │   └── docker/<容器ID>/
  ├── memory/
  │   └── docker/<容器ID>/
  └── blkio/
      └── docker/<容器ID>/
  每个资源控制器独立的层级树 → 配置分散，难以统一管理

v2 (新，推荐):
  /sys/fs/cgroup/
  └── system.slice/
      └── docker-<容器ID>.scope/
          ├── cpu.max         ← 所有控制器在同一目录
          ├── memory.max
          ├── memory.current
          └── io.max
  统一层级树 → 配置集中，支持跨资源协调
```

### CPU 限制

**关键概念**: CPU 限制在 cgroups 中是**按时间片分配**的，不是按核数分配的。

```
cpu.max = "25000 100000"
           │       └── 周期：100ms (100000μs)
           └── 配额：25ms

含义: 每 100ms 周期内，这个 cgroup 最多使用 25ms 的 CPU 时间
     = 0.25 vCPU
```

**ECS 中的 CPU 单位**:

```
ECS CPU 单位        = cgroups 配额      = 含义
256 (0.25 vCPU)     = 25ms/100ms       = 每 100ms 用 25ms CPU
512 (0.5 vCPU)      = 50ms/100ms       = 每 100ms 用 50ms CPU
1024 (1 vCPU)       = 100ms/100ms      = 每 100ms 用 100ms CPU
```

**软限制 vs 硬限制**:

ECS Task Definition 中的 CPU 有两种配置：

```json
{
  "containerDefinitions": [{
    "cpu": 256,           // 软限制 (cpu.shares) — 保证最低份额
                          // 如果宿主机有空闲 CPU，可以超出使用
    "resourceRequirements": [{
      "type": "CPU",
      "value": "0.25"     // Fargate 模式下是硬限制 (cpu.max)
    }]
  }]
}
```

**对应 Optima 的 Stage-ECS 配置**:

```
user-auth:       0.25 vCPU → 每 100ms 用 25ms CPU
mcp-host:        0.25 vCPU → 每 100ms 用 25ms CPU
agentic-chat:    0.25 vCPU → 每 100ms 用 25ms CPU

t3.medium 宿主机: 2 vCPU 总量
5 个核心服务 × 0.25 vCPU = 1.25 vCPU 保证
剩余 0.75 vCPU 可用于突发使用（cpu.shares 软限制时）
```

### 内存限制

```bash
# cgroups v2 中的内存控制
memory.max      = 268435456    # 硬上限 256MB
memory.current  = 134217728    # 当前使用 128MB
memory.swap.max = 0            # 禁用 swap（容器默认）
```

**内存限制是硬限制**: 超过 `memory.max` 后，内核会触发 OOM Killer，直接杀死容器内的进程。

```
内存使用轨迹:

256MB ┤ · · · · · · · · · · · · · · · · · · · memory.max (硬上限)
      │                              ╱ ← OOM Kill!
200MB ┤                          ╱╱╱╱
      │                      ╱╱╱╱
150MB ┤                  ╱╱╱╱
      │              ╱╱╱╱
100MB ┤          ╱╱╱╱
      │      ╱╱╱╱            ← 内存泄漏
50MB  ┤  ╱╱╱╱
      │╱╱
    0 ┼────────────────────────────────────── 时间
```

**对应 Optima 的 ECS Task**:

当你在 CloudWatch 看到 ECS Task 被 "Essential container exited" 停止，且退出码是 137 (128 + 9 = SIGKILL)，很可能就是 OOM Kill。

```bash
# 在 ECS Task 内检查内存限制
$ cat /sys/fs/cgroup/memory.max
268435456    # 256MB

# 检查当前使用
$ cat /sys/fs/cgroup/memory.current
```

**Node.js 特别注意**: Node.js 默认堆内存上限和容器的内存限制**不一致**。

```bash
# Node.js 20 默认堆上限大约是系统内存的 50%（但它看到的是宿主机内存）
# 宿主机 4GB → Node.js 默认堆上限 ~2GB
# 但容器只有 256MB → OOM Kill!

# 解决: 显式设置 --max-old-space-size
CMD ["node", "--max-old-space-size=200", "dist/index.js"]
# 留 56MB 给非堆内存（栈、native modules、fd 等）
```

### IO 限制

```bash
# cgroups v2 中的 IO 控制
io.max = "8:0 rbps=10485760 wbps=10485760"
#         │    │              └── 写入带宽 10MB/s
#         │    └── 读取带宽 10MB/s
#         └── 设备 major:minor
```

ECS 通常不直接配置 IO 限制，但理解这个机制有助于排查 IO 密集服务的性能问题。

### 动手实验：观察 cgroups

```bash
# 启动一个带资源限制的容器
$ docker run -d --name test --memory=128m --cpus=0.5 nginx

# 找到容器的 cgroup 路径
$ docker inspect test --format '{{.HostConfig.CgroupParent}}'

# 直接查看 cgroup 文件（cgroups v2）
$ CONTAINER_ID=$(docker inspect test --format '{{.Id}}')
$ cat /sys/fs/cgroup/system.slice/docker-${CONTAINER_ID}.scope/memory.max
134217728   # 128MB

$ cat /sys/fs/cgroup/system.slice/docker-${CONTAINER_ID}.scope/cpu.max
50000 100000   # 50ms/100ms = 0.5 CPU

# 清理
$ docker rm -f test
```

---

## 5. Union Filesystem — 镜像分层的秘密

### OverlayFS 原理

Docker 镜像不是一个整体文件，而是一系列**只读层**的叠加：

```
容器视角（merged view）:
┌──────────────────────────────────┐
│  /app/dist/index.js  (来自第5层) │
│  /app/node_modules/  (来自第4层) │
│  /app/package.json   (来自第3层) │
│  /usr/local/bin/node (来自第2层) │
│  /bin/sh, /lib/...   (来自第1层) │
└──────────────────────────────────┘

实际的存储结构:
┌──────────────────────────────────┐
│ 容器层 (upperdir) — 可读写       │ ← 运行时的写入操作在这里
├──────────────────────────────────┤
│ Layer 5: COPY dist/ → /app/dist │ ← 只读
├──────────────────────────────────┤
│ Layer 4: RUN npm install        │ ← 只读 (包含 node_modules)
├──────────────────────────────────┤
│ Layer 3: COPY package.json      │ ← 只读
├──────────────────────────────────┤
│ Layer 2: node:20-slim 应用层     │ ← 只读
├──────────────────────────────────┤
│ Layer 1: debian:bookworm-slim   │ ← 只读（base image）
└──────────────────────────────────┘
```

**OverlayFS 的工作机制**:

```
OverlayFS
├── lowerdir (只读层，可以多个叠加)
│     = 镜像的所有层
├── upperdir (读写层)
│     = 容器运行时的变更
├── workdir (内部使用)
└── merged (合并视图)
      = 容器内看到的文件系统
```

**读取文件**: 从上往下查找，返回第一个找到的版本。

**写入文件 (Copy-on-Write)**:
1. 如果文件在 upperdir（容器层）→ 直接写入
2. 如果文件在 lowerdir（镜像层）→ 先复制到 upperdir，再写入
3. 删除文件 → 在 upperdir 创建一个 "whiteout" 标记

```
删除文件的例子:

lowerdir:  /etc/nginx/nginx.conf  (存在)
upperdir:  /etc/nginx/.wh.nginx.conf  (whiteout 标记)
merged:    /etc/nginx/nginx.conf  (不可见 — 被删除了)
```

### 为什么层的顺序很重要

```dockerfile
# ❌ 低效的 Dockerfile — 改一行代码就要重新 npm install
FROM node:20-slim
WORKDIR /app
COPY . .                    # Layer 3: 所有文件（包括源代码）
RUN npm install             # Layer 4: 安装依赖
CMD ["node", "dist/index.js"]
```

```
修改 src/index.ts 后重新构建:
  Layer 1: node:20-slim          ← 缓存命中 ✅
  Layer 2: WORKDIR /app          ← 缓存命中 ✅
  Layer 3: COPY . .              ← 文件变了，缓存失效 ❌
  Layer 4: RUN npm install       ← 上层失效，被迫重建 ❌ (即使依赖没变!)
```

```dockerfile
# ✅ 优化的 Dockerfile — 利用分层缓存
FROM node:20-slim
WORKDIR /app
COPY package.json pnpm-lock.yaml ./   # Layer 3: 只有依赖描述文件
RUN npm install                       # Layer 4: 安装依赖
COPY . .                              # Layer 5: 源代码
CMD ["node", "dist/index.js"]
```

```
修改 src/index.ts 后重新构建:
  Layer 1: node:20-slim               ← 缓存命中 ✅
  Layer 2: WORKDIR /app               ← 缓存命中 ✅
  Layer 3: COPY package.json ...      ← 没变，缓存命中 ✅
  Layer 4: RUN npm install            ← 没变，缓存命中 ✅ (跳过!)
  Layer 5: COPY . .                   ← 文件变了，只重建这一层 ❌
```

**效果**: 修改代码后重新构建从几分钟缩短到几秒。

---

## 6. 容器运行时 — containerd、runc 和 OCI 规范

### 容器运行时的分层架构

```
用户接口层:
┌─────────────┐
│  docker CLI  │  ← 你输入 docker run 的地方
└──────┬──────┘
       │ REST API
       ▼
┌──────────────┐
│   dockerd     │  ← Docker 守护进程（高级运行时）
└──────┬──────┘
       │ gRPC
       ▼
容器运行时层:
┌──────────────┐
│  containerd   │  ← 容器生命周期管理（拉镜像、管理存储、创建容器）
└──────┬──────┘
       │ OCI Runtime Spec
       ▼
┌──────────────┐
│    runc       │  ← 低级运行时（实际调用 Linux 内核创建 namespace/cgroups）
└──────────────┘
       │
       ▼
┌──────────────┐
│ Linux Kernel  │  ← namespace + cgroups + overlayfs
└──────────────┘
```

**关键理解**:

- **runc**: OCI 标准的参考实现，负责根据 OCI Runtime Spec 创建容器（配置 namespace、cgroups、rootfs）。它是一个**一次性**的命令行工具——创建完容器就退出了。
- **containerd**: 管理容器的整个生命周期（create → start → stop → delete），管理镜像存储，提供 gRPC API。
- **dockerd**: Docker 特有的层，提供 docker CLI 需要的高级功能（构建镜像、网络、volume）。

**ECS 不需要 Docker**: ECS 的容器运行时直接用 containerd（通过 ECS Agent），绕过 dockerd。这就是为什么 ECS EC2 实例上你用 `docker ps` 可能看不到 ECS 启动的容器。

### OCI (Open Container Initiative) 规范

OCI 定义了两个核心规范：

1. **Image Spec**: 镜像格式（层、manifest、config）
2. **Runtime Spec**: 容器运行时配置（`config.json`）

```json
// OCI Runtime Spec 的 config.json（runc 使用这个来创建容器）
{
  "ociVersion": "1.0.2",
  "process": {
    "terminal": false,
    "user": { "uid": 1000, "gid": 1000 },
    "args": ["node", "dist/index.js"],
    "env": ["NODE_ENV=production"],
    "cwd": "/app"
  },
  "root": {
    "path": "rootfs",
    "readonly": true
  },
  "linux": {
    "namespaces": [
      { "type": "pid" },
      { "type": "network" },
      { "type": "mount" },
      { "type": "ipc" },
      { "type": "uts" }
    ],
    "resources": {
      "memory": { "limit": 268435456 },
      "cpu": { "quota": 25000, "period": 100000 }
    }
  }
}
```

**你看到了吗**: OCI config.json 就是把前面讲的 namespace + cgroups 配置打包成一个标准格式。这就是容器的全部"魔法"。

### containerd-shim 的作用

```
containerd
  └── containerd-shim (PID 2200)     ← 每个容器一个 shim
        └── runc create → 容器进程    ← runc 创建完就退出
              └── node server.js (PID 2300, 容器内 PID 1)
```

shim 存在的原因：
- **containerd 重启不影响容器**: shim 是独立进程，即使 containerd 升级重启，正在运行的容器不受影响
- **收集退出码**: 容器进程退出后，shim 收集退出码报告给 containerd
- **stdio 管理**: 容器的 stdin/stdout/stderr 通过 shim 中转

---

## 7. Docker 镜像最佳实践

### 多阶段构建 (Multi-stage Build)

**问题**: 构建时需要编译工具（TypeScript compiler、devDependencies），但运行时不需要。如果把构建工具打包进最终镜像，镜像体积会很大。

```dockerfile
# Optima Node.js 服务推荐的多阶段构建

# ===== 阶段 1: 安装依赖 =====
FROM node:20-slim AS deps
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN corepack enable pnpm && pnpm install --frozen-lockfile

# ===== 阶段 2: 构建 =====
FROM deps AS builder
COPY . .
RUN pnpm run build
# 此时 /app/dist/ 包含编译后的 JS

# ===== 阶段 3: 生产镜像 =====
FROM node:20-slim AS runner
WORKDIR /app

# 安全: 使用非 root 用户
RUN addgroup --system appgroup && \
    adduser --system --ingroup appgroup appuser

# 只复制运行时需要的文件
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./

# tini 作为 PID 1
RUN apt-get update && apt-get install -y --no-install-recommends tini && \
    rm -rf /var/lib/apt/lists/*

USER appuser
EXPOSE 8000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "--max-old-space-size=200", "dist/index.js"]
```

**镜像体积对比**:

```
不用多阶段构建:
  node:20           ~1.1 GB (包含 build-essential, python 等)
  + npm install     +200 MB (包含 devDependencies)
  + 源代码          +50 MB
  总计: ~1.35 GB

多阶段构建:
  node:20-slim      ~200 MB
  + node_modules    +80 MB (只有 production dependencies)
  + dist/           +5 MB (编译后的 JS)
  总计: ~285 MB   ← 缩小 79%
```

### 基础镜像选择

| 基础镜像 | 体积 | 特点 | 推荐场景 |
|---------|------|------|---------|
| `node:20` | ~1.1 GB | 完整 Debian + build tools | 需要编译 native 模块时的构建阶段 |
| `node:20-slim` | ~200 MB | 最小 Debian | **Optima 推荐** — 大多数服务 |
| `node:20-alpine` | ~130 MB | Alpine Linux (musl libc) | 体积最小但 musl 可能有兼容性问题 |
| `gcr.io/distroless/nodejs20` | ~120 MB | 无 shell、无包管理器 | 安全要求最高的生产环境 |

**推荐 `node:20-slim` 而非 `alpine` 的原因**:
- Alpine 使用 musl libc 而非 glibc，某些 native npm 包可能编译失败或行为不同
- Node.js 官方在 glibc 上做的测试更充分
- 体积差距 (70MB) 在实际部署中影响不大

### .dockerignore

缺少 `.dockerignore` 是镜像膨胀和构建缓存失效的常见原因：

```
# .dockerignore
node_modules
.git
.env
.env.*
dist
*.md
.vscode
.claude
tests
coverage
```

**为什么 `node_modules` 要在 `.dockerignore` 中**: `COPY . .` 时不应该复制本地的 `node_modules`（可能包含本地编译的 native 模块），应该在 Docker 构建过程中重新 `npm install`。

### 镜像安全扫描

```bash
# 使用 Trivy 扫描镜像
$ trivy image user-auth:latest

user-auth:latest (debian 12.4)
================================
Total: 12 (HIGH: 3, CRITICAL: 1)

┌──────────────┬────────────────┬──────────┬────────────────────┐
│   Library    │ Vulnerability  │ Severity │  Fixed Version     │
├──────────────┼────────────────┼──────────┼────────────────────┤
│ libssl3      │ CVE-2024-xxxx  │ CRITICAL │ 3.0.13-1~deb12u1   │
│ curl         │ CVE-2024-xxxx  │ HIGH     │ 7.88.1-10+deb12u5  │
└──────────────┴────────────────┴──────────┴────────────────────┘

# ECR 内置扫描（推荐，零配置）
$ aws ecr start-image-scan \
    --repository-name user-auth-stage-ecs \
    --image-id imageTag=latest
```

---

## 8. 信号处理与优雅停机

### Linux 信号基础

| 信号 | 编号 | 默认行为 | 能否捕获 | 用途 |
|------|------|---------|---------|------|
| SIGTERM | 15 | 终止 | 可以 | 请求进程优雅退出 |
| SIGKILL | 9 | 终止 | **不可以** | 强制杀死进程 |
| SIGINT | 2 | 终止 | 可以 | Ctrl+C |
| SIGCHLD | 17 | 忽略 | 可以 | 子进程退出通知 |
| SIGUSR1 | 10 | 终止 | 可以 | 自定义用途 |
| SIGHUP | 1 | 终止 | 可以 | 终端断开 / 配置重载 |

**SIGTERM vs SIGKILL**:

```
SIGTERM ("请你退出"):
  ├── 进程可以捕获信号
  ├── 进行清理工作（关闭数据库连接、完成当前请求、保存状态）
  └── 自行调用 exit()

SIGKILL ("立刻死"):
  ├── 进程无法捕获或忽略
  ├── 内核直接终止进程
  ├── 没有清理机会
  └── 可能导致数据不一致、连接泄漏
```

### ECS 中的停机流程

当 ECS 需要停止一个 Task（滚动部署、缩容、手动停止）：

```
时间线:

t=0s   ECS 发送 SIGTERM 到容器的 PID 1
       │
       ├── ALB 开始 deregistration (从 Target Group 移除)
       │   └── deregistration_delay (默认 300s，Optima 配置为 30s)
       │       期间: ALB 不再发送新请求，但等待现有请求完成
       │
       ├── 容器收到 SIGTERM
       │   └── 应用开始优雅停机:
       │       1. 停止接受新请求
       │       2. 等待处理中的请求完成
       │       3. 关闭数据库连接池
       │       4. 关闭 WebSocket 连接（发送 close frame）
       │       5. 调用 process.exit(0)
       │
       ▼
t=30s  stopTimeout 到期（默认 30s，可在 Task Definition 中配置）
       ECS 发送 SIGKILL 强制终止
       ← 如果你的应用没在 30s 内退出，就被强杀
```

### Node.js 优雅停机实现

```typescript
// 推荐的 Node.js 优雅停机模板

const server = http.createServer(app);
let isShuttingDown = false;

async function gracefulShutdown(signal: string) {
  if (isShuttingDown) return; // 防止重复执行
  isShuttingDown = true;

  console.log(`收到 ${signal}，开始优雅停机...`);

  // 1. 停止接受新连接
  server.close(() => {
    console.log('HTTP server 已关闭');
  });

  // 2. 设置强制退出定时器（比 ECS stopTimeout 短一些）
  const forceExitTimer = setTimeout(() => {
    console.error('优雅停机超时，强制退出');
    process.exit(1);
  }, 25_000); // 25s，留 5s 缓冲给 SIGKILL

  try {
    // 3. 等待处理中的请求完成
    await drainConnections();

    // 4. 关闭数据库连接池
    await db.end();

    // 5. 关闭 Redis 连接
    await redis.quit();

    console.log('优雅停机完成');
    clearTimeout(forceExitTimer);
    process.exit(0);
  } catch (err) {
    console.error('优雅停机出错:', err);
    clearTimeout(forceExitTimer);
    process.exit(1);
  }
}

// 注册信号处理
process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));
```

**对应 Optima 的 ECS 配置**:

```json
// Task Definition 中的停机配置
{
  "containerDefinitions": [{
    "stopTimeout": 30,         // SIGTERM 到 SIGKILL 的等待时间
    "essential": true          // 此容器停止 = 整个 Task 停止
  }]
}
```

```hcl
# Terraform 中 Target Group 的配置
resource "aws_lb_target_group" "service" {
  deregistration_delay = 30    # ALB 停止发送新请求后等待旧请求完成的时间

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}
```

### 滚动部署中的时间线

```
旧 Task                                    新 Task
──────                                    ──────

t=0s   ECS 启动新 Task
                                          启动容器...
                                          健康检查中...
t=30s                                     健康检查通过 ✅
                                          ALB 注册新 Task ✅
t=35s  ALB 开始 deregistration (旧 Task)
       停止发送新请求到旧 Task
       ↓
t=40s  ECS 发送 SIGTERM 到旧 Task
       旧 Task 开始优雅停机
       ↓ 处理剩余请求...
       ↓ 关闭连接...
t=50s  旧 Task 优雅退出 ✅

结果: 零停机部署
  - 新 Task 先就绪，旧 Task 再停止
  - 旧 Task 有充足时间完成正在处理的请求
```

### WebSocket 的优雅停机

WebSocket 连接是长连接，不像 HTTP 请求那样快速完成。session-gateway 需要特殊处理：

```typescript
async function gracefulShutdown(signal: string) {
  // 1. 停止接受新的 WebSocket 连接
  wss.close();

  // 2. 通知所有已连接的客户端即将断开
  for (const ws of wss.clients) {
    ws.send(JSON.stringify({
      type: 'server_shutdown',
      message: '服务器正在重启，请重新连接'
    }));
    // 发送 WebSocket close frame (code 1001 = Going Away)
    ws.close(1001, 'Server shutting down');
  }

  // 3. 等待所有连接关闭（设置超时）
  await waitForAllConnectionsClosed(10_000);

  // 4. 退出
  process.exit(0);
}
```

**客户端应对**: 客户端收到 `1001 Going Away` 后，应该自动重连。这就是 session-gateway 的断线重连机制需要处理的场景。

---

## 把这些知识串起来

现在你理解了容器的完整技术栈：

```
Docker 命令行 / ECS Task Definition
        │
        ▼
   ┌──────────────────────────────────────────────────┐
   │               容器运行时                           │
   │  containerd → runc → 调用 Linux 内核              │
   └──────────────────────────────────────────────────┘
        │              │              │
        ▼              ▼              ▼
   ┌──────────┐  ┌──────────┐  ┌──────────────┐
   │Namespace │  │ Cgroups  │  │ OverlayFS    │
   │          │  │          │  │              │
   │ 隔离:    │  │ 限制:    │  │ 文件系统:     │
   │ PID      │  │ CPU      │  │ 镜像分层     │
   │ NET      │  │ Memory   │  │ Copy-on-Write│
   │ MNT      │  │ IO       │  │ Whiteout     │
   │ UTS      │  │ PIDs     │  │              │
   │ IPC      │  │          │  │              │
   │ USER     │  │          │  │              │
   └──────────┘  └──────────┘  └──────────────┘
        │              │              │
        └──────────────┼──────────────┘
                       │
                       ▼
               ┌──────────────┐
               │ Linux Kernel │
               └──────────────┘
```

**容器 = Namespace (隔离) + Cgroups (限制) + Union FS (文件系统) + 进程**

它不是虚拟机。没有独立的内核，没有硬件虚拟化。它只是一个受限的 Linux 进程。

---

## 推荐资料

### 经典书籍

| 书名 | 作者 | 重点章节 | 推荐理由 |
|------|------|---------|---------|
| **《Linux 内核设计与实现》(LKD)** | Robert Love | Ch3 进程管理, Ch18 调试 | 进程模型的权威入门，薄且精 |
| **《UNIX 环境高级编程》(APUE)** | W. Richard Stevens | Ch7 进程环境, Ch8 进程控制, Ch10 信号 | 系统编程圣经，fork/exec/signal 讲得最透彻 |
| **《Docker Deep Dive》** | Nigel Poulton | 全书 | 容器实践指南，从使用到原理逐步深入 |
| **《Container Security》** | Liz Rice | Ch4 Namespaces, Ch5 Cgroups | 用 Go 代码手写容器，最好的动手教材 |

### 在线资源

- **[man7.org — namespaces](https://man7.org/linux/man-pages/man7/namespaces.7.html)**: Linux namespace 的官方文档，最权威的参考
- **[cgroup v2 内核文档](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)**: cgroup v2 的完整说明
- **[OCI Runtime Spec](https://github.com/opencontainers/runtime-spec)**: 容器运行时标准规范
- **[Julia Evans 的容器系列博客](https://jvns.ca/categories/containers/)**: 用简单语言解释复杂概念
- **[Dockerfile best practices (Docker 官方)](https://docs.docker.com/build/building/best-practices/)**: 镜像构建最佳实践
- **[Node.js Docker 最佳实践](https://github.com/nodejs/docker-node/blob/main/docs/BestPractices.md)**: Node.js 官方的 Docker 指南

### 动手实验建议

| 实验 | 预计时间 | 你会学到 |
|------|---------|---------|
| **用 `unshare` 手动创建 namespace** | 30 分钟 | namespace 的隔离机制（本文已包含命令） |
| **手动创建 cgroup 并限制进程资源** | 30 分钟 | `echo $$ > cgroup.procs` + `echo 100M > memory.max` |
| **用 `runc` 直接运行容器** | 1 小时 | 理解 OCI 规范和 config.json |
| **Liz Rice 的 "Containers From Scratch"** | 2 小时 | 用 Go 从零实现一个简化版容器 ([YouTube](https://www.youtube.com/watch?v=8fi7uSYlOdc)) |
| **分析 Optima 服务的 Dockerfile** | 1 小时 | 对照本文优化镜像分层和构建缓存 |
| **在 ECS Task 中测试优雅停机** | 1 小时 | 部署 → 触发滚动更新 → 观察 SIGTERM 处理 |
| **用 `docker diff` 观察 overlay 变更** | 15 分钟 | 理解 copy-on-write 和容器层 |

### 推荐学习路径

```
Week 1: 进程与信号
  ├── 读 APUE Ch8 (进程控制) + Ch10 (信号)
  ├── 实验: fork/exec 行为、信号处理
  └── 实践: 为 Optima 服务添加优雅停机

Week 2: Namespace 与 Cgroups
  ├── 读 Container Security Ch4-5
  ├── 实验: unshare 创建 namespace、手动操作 cgroup 文件
  └── 实践: 理解 ECS Task Definition 中每个配置的底层含义

Week 3: 镜像与运行时
  ├── 看 Liz Rice 的 "Containers From Scratch" 视频
  ├── 实验: 用 runc 直接运行容器
  └── 实践: 优化 Optima 服务的 Dockerfile（多阶段构建、缓存优化）
```
