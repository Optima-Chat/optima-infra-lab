# 环节 C 优化方案

> **当前基线**: 81s (冷启动 → InService)
> **优化目标**: <40s

---

## 当前 81s 时间分解

```
┌─────────────────────────────────────────────────────────────────────────┐
│  EC2 冷启动时间分解 (总计 ~81s)                                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1. EC2 Pending → Running          ~15-20s                             │
│     ├─ 实例分配                     ~5s                                 │
│     ├─ 网络接口配置                  ~5s                                 │
│     └─ EBS 卷挂载                   ~5-10s                              │
│                                                                         │
│  2. 系统初始化                       ~20-30s                             │
│     ├─ 内核启动                      ~5s                                 │
│     ├─ systemd 初始化               ~10s                                │
│     └─ cloud-init 执行              ~10-15s                             │
│                                                                         │
│  3. User Data 执行                  ~15-25s                             │
│     ├─ ECS 配置写入                  ~1s                                 │
│     ├─ EBS 深度预热 (首次)           ~10-20s                            │
│     └─ Docker 镜像拉取              ~5s (如果需要)                       │
│                                                                         │
│  4. ECS Agent 启动                  ~10-15s                             │
│     ├─ 服务启动                      ~3s                                 │
│     ├─ 集群注册                      ~5s                                 │
│     └─ 健康检查通过                  ~5s                                 │
│                                                                         │
│  5. ASG 健康检查                    ~5-10s                              │
│     └─ EC2 状态检查 → InService     ~5-10s                              │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 优化方案

### 方案 1: 精简 User Data (预期节省 10-15s)

**当前问题**:
- EBS 深度预热在每次冷启动都执行
- 预热脚本读取整个文件系统，耗时长

**优化方法**:
```bash
# 只预热关键路径，不是整个文件系统
# 当前:
find /lib/modules /usr/bin /usr/sbin /usr/lib64 /var/lib/docker /var/lib/ecs -type f -exec cat {} \; > /dev/null

# 优化为: 只预热 ECS 和 Docker 关键文件
cat /var/lib/ecs/ecs-agent-data.json > /dev/null 2>&1 || true
docker info > /dev/null 2>&1 || true
```

**测试方法**:
```bash
# 对比不同预热策略的启动时间
./scripts/test-userdata-optimization.sh
```

### 方案 2: 禁用 cloud-init 模块 (预期节省 5-10s)

**当前问题**:
- cloud-init 执行所有默认模块
- 很多模块对 ECS 无用

**优化方法**:
在 Launch Template 的 User Data 开头添加:
```bash
# 禁用不必要的 cloud-init 模块
cat > /etc/cloud/cloud.cfg.d/99-disable-slow.cfg <<'CLOUDCFG'
cloud_init_modules:
  - bootcmd
  - write-files

cloud_config_modules:
  - runcmd

cloud_final_modules:
  - scripts-user
  - final-message
CLOUDCFG
```

**注意**: 需要在 AMI 构建时执行，否则无效

### 方案 3: Golden AMI (预期节省 20-30s)

**原理**: 把所有首次初始化工作预先完成，打包成 AMI

**Golden AMI 包含**:
1. EBS 已预热 (所有文件从 S3 加载完成)
2. Docker 镜像已缓存
3. ECS Agent 已配置
4. cloud-init 已优化

**构建流程**:
```
1. 启动标准 ECS AMI 实例
2. 执行完整的 User Data (EBS 预热 + Docker pull)
3. 清理临时文件
4. 创建 AMI 快照
5. 更新 Launch Template 使用新 AMI
```

### 方案 4: 减少 ASG 健康检查等待 (预期节省 5s)

**当前配置**:
```hcl
health_check_grace_period = 60  # 等待 60s 才检查
```

**优化为**:
```hcl
health_check_grace_period = 30  # 减少到 30s
```

### 方案 5: 优化网络初始化 (预期节省 5s)

**方法**: 使用静态 IP 或减少 ENI 配置时间

**注意**: 可能影响灵活性，需要评估

---

## 测试计划

### 第一轮: 验证当前时间分解

```bash
# 测试脚本: 分解测量每个阶段
./scripts/test-cold-start-breakdown.sh
```

需要测量:
- [ ] pending → running 时间
- [ ] running → status checks OK 时间
- [ ] User Data 执行时间 (通过日志)
- [ ] ECS Agent 注册时间

### 第二轮: 精简 User Data

1. 创建最小 User Data 版本
2. 对比测试启动时间
3. 验证 ECS 功能正常

### 第三轮: Golden AMI

1. 编写 Packer 配置
2. 构建 Golden AMI
3. 更新 Launch Template
4. 对比测试启动时间

---

## 预期效果

| 优化项 | 当前 | 优化后 | 节省 |
|--------|------|--------|------|
| 基线 | 81s | - | - |
| 精简 User Data | 81s | 66s | 15s |
| + 减少健康检查等待 | 66s | 56s | 10s |
| + Golden AMI | 56s | 35s | 21s |
| **总计** | **81s** | **35s** | **46s** |

---

## 下一步

1. [ ] 运行 `test-cold-start-breakdown.sh` 验证时间分解
2. [ ] 测试精简 User Data 效果
3. [ ] 评估 Golden AMI 方案的 ROI
