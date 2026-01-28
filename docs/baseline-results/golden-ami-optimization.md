# Golden AMI 优化方案

> **日期**: 2026-01-28
> **目标**: 减少冷启动时间 25-30s

---

## 冷启动 80s 分解

| 阶段 | 耗时 | 可优化 | 优化方法 |
|------|------|--------|---------|
| EC2 启动 | ~20s | ❌ | AWS 硬限制 |
| 状态检查 | ~30s | ❌ | AWS 硬限制 |
| User Data | ~5ms | ✅ 已优化 | 零预热 |
| ECS Agent 启动 | ~5s | ⚠️ 部分 | 预配置 |
| ECS Agent 注册 | ~10s | ❌ | AWS 内部 |
| Docker 镜像拉取 | ~15s | ✅ | **Golden AMI** |

## Golden AMI 内容

预烘焙的 AMI 包含：

1. **预拉取的 Docker 镜像**
   ```bash
   # 已拉取
   585891120210.dkr.ecr.ap-southeast-1.amazonaws.com/optima-ai-shell:latest
   ```

2. **预配置的 ECS Agent**
   ```bash
   # /etc/ecs/ecs.config 已包含
   ECS_CLUSTER=fargate-warm-pool-test
   ECS_WARM_POOLS_CHECK=true
   ECS_IMAGE_PULL_BEHAVIOR=prefer-cached
   ```

3. **预热的 EBS 数据**
   - Docker 层已在磁盘上
   - ECS Agent 二进制已加载

## 预期效果

| 场景 | 当前 | Golden AMI 后 |
|------|------|--------------|
| 冷启动 | ~80s | ~55s |
| Warm Pool 唤醒 | ~17s | ~12s |
| 热池 Task 分配 | ~280ms | ~280ms (无变化) |

**节省**: ~25s (主要是镜像拉取时间)

## 使用方法

### 1. 构建 Golden AMI

```bash
./scripts/build-golden-ami.sh
```

### 2. 配置 Terraform

```hcl
# terraform.tfvars
golden_ami_id = "ami-xxxxxxxxx"
```

### 3. 部署

```bash
terraform apply
```

## 注意事项

1. **需要定期更新** - 当 ai-shell 镜像更新时，需要重新构建 Golden AMI
2. **多镜像支持** - 可以在脚本中添加更多需要预拉取的镜像
3. **成本** - Golden AMI 的 EBS 快照会产生少量存储费用 (~$0.05/GB/月)

## 无法优化的部分

以下是 AWS 硬限制，无法优化：

- EC2 实例启动: ~20s
- EC2 状态检查: ~30s
- ECS Agent 集群注册: ~10s

**总计 ~60s 是下限**，无论怎么优化都省不了。

## 进一步优化思路

如果 60s 仍不能接受，需要考虑：

1. **Fargate** - 无需等待 EC2，但启动时间也是 30-60s
2. **Lambda** - 冷启动 1-5s，但有运行时间限制
3. **预启动更多 Task** - 增大热池容量
4. **多区域部署** - 分散负载，减少扩容需求
