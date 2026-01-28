# EC2 Warm Pool 启动时间测试结果

## 测试环境

- **区域**: ap-southeast-1
- **实例类型**: t3.small (2 vCPU, 2GB RAM)
- **Warm Pool 状态**: Stopped
- **ECS 集群**: fargate-warm-pool-test
- **Docker 镜像**: 简单测试镜像

## 测试结果

### Warm Pool 启动 (Stopped → InService → ECS Task Running)

| 阶段 | 时间 |
|------|------|
| EC2 从 Stopped 启动到 InService | **~20 秒** |
| ECS Agent 注册到集群 | 包含在上述时间内 |
| ECS 任务调度和启动 | **~1-3 秒** |
| **总计** | **~22 秒** |

### 对比：冷启动预估

| 阶段 | 时间 |
|------|------|
| EC2 实例启动 (pending → running) | ~30-60 秒 |
| 实例状态检查通过 | ~60-120 秒 |
| EBS 首次读取 (lazy loading) | ~30-60 秒 |
| Docker 镜像拉取 | ~30-60 秒 |
| ECS Agent 注册 | ~10-30 秒 |
| **总计** | **2-5 分钟** |

## 关键发现

1. **Warm Pool 显著加速启动**
   - 从 Stopped 状态启动比冷启动快 80%+
   - EBS 卷已预热，无需从 S3 加载数据
   - Docker 镜像已缓存在 EBS 中

2. **自动补充机制**
   - ASG 会自动维护 Warm Pool 的实例数量
   - `reuse_on_scale_in = true` 让缩容的实例回到 Warm Pool

3. **成本考虑**
   - Stopped 状态只收 EBS 存储费用
   - t3.small 30GB EBS ≈ $2.4/月/实例
   - 预热 2 个实例的额外成本 ≈ $5/月

## 配置建议

### 生产环境配置

```hcl
# terraform.tfvars
ec2_instance_type = "t3.medium"     # 根据需求调整
ec2_asg_min_size = 1                 # 至少保持 1 个运行实例
ec2_asg_max_size = 10               # 最大容量
ec2_asg_desired_capacity = 1        # 初始运行实例

ec2_warm_pool_state = "Stopped"     # 省钱，启动时间 ~20s
ec2_warm_pool_min_size = 2          # 预热实例数量
ec2_warm_pool_max_size = 5          # 最大预热容量
```

### 更快启动选项

如果需要更快的启动时间，可以使用 `Running` 状态：

```hcl
ec2_warm_pool_state = "Running"     # 实例保持运行，启动 <1 秒
```

但这会增加成本：
- Running 状态会收取完整的 EC2 费用
- t3.medium: ~$30/月/实例

## 结论

EC2 Warm Pool 是一个高性价比的解决方案：
- **启动时间**: 从 2-5 分钟降低到 ~22 秒
- **额外成本**: ~$5/月 (2 个 Stopped 预热实例)
- **可靠性**: AWS 托管，自动维护预热池

对于 AI Shell 场景，建议：
1. 保持 2-3 个 Stopped 预热实例
2. 结合 ECS Capacity Provider managed scaling 自动扩缩容
3. 监控 `WarmPoolMinSize` CloudWatch 指标确保预热池充足
