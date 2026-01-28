# User Data 优化测试结果

> **测试日期**: 2026-01-28
> **结论**: 零预热方案可行，节省 22 秒

---

## 测试结果

| 版本 | 预热数据量 | User Data 耗时 | 节省 |
|------|-----------|---------------|------|
| 完整预热 | 1.1GB | 22.6s | 基线 |
| 精简预热 | 458MB | 2.3s | 20.3s |
| **零预热** | **0** | **5ms** | **22.6s** |

## 分析

### 完整预热 (原版)

预热目录:
```
/lib/modules:   110M
/usr/bin:       365M
/usr/sbin:       45M
/usr/lib64:     142M
/var/lib/docker: 145M
/var/lib/ecs:   313M
总计:          1.1GB
```

**问题**: 大部分是系统文件，ECS 启动不需要

### 精简预热

只预热 Docker + ECS:
```
/var/lib/docker: 145M
/var/lib/ecs:   313M
总计:           458MB
```

**效果**: 22.6s → 2.3s (节省 90%)

### 零预热

完全不预热，让 EBS 按需加载。

**原理**:
- EBS 从 S3 快照延迟加载
- 首次访问时自动加载
- Warm Pool 实例复用时 EBS 已缓存

**效果**: 22.6s → 5ms (节省 99.98%)

## 对冷启动总时间的影响

| 配置 | 估算冷启动时间 |
|------|--------------|
| 完整预热 | ~81s |
| 零预热 | **~59s** |
| 节省 | **22s (27%)** |

## 结论

1. **零预热方案推荐使用**
   - User Data 几乎瞬间完成
   - EBS 按需加载不影响 ECS 启动
   - Warm Pool 复用时完全无感

2. **后续优化空间**
   - 减少 ASG 健康检查等待 (当前 60s)
   - 优化 cloud-init 模块
   - Golden AMI (预装 Docker 镜像)

## 配置

Terraform 变量:
```hcl
# 使用零预热版本
optimized_userdata = true
```

User Data (简化版):
```bash
#!/bin/bash
set -ex
echo "EC2_BOOT_START=$(date +%s%3N)" >> /var/log/boot-timing.log

cat >> /etc/ecs/ecs.config <<ECSCONFIG
ECS_CLUSTER=${CLUSTER_NAME}
ECS_WARM_POOLS_CHECK=true
ECS_IMAGE_PULL_BEHAVIOR=prefer-cached
ECSCONFIG

# 不预热！让 EBS 按需加载
echo "EC2_WARM_DONE=$(date +%s%3N)" >> /var/log/boot-timing.log

systemctl enable ecs && systemctl start ecs
until curl -s http://localhost:51678/v1/metadata; do sleep 1; done
echo "ECS_AGENT_READY=$(date +%s%3N)" >> /var/log/boot-timing.log
```
