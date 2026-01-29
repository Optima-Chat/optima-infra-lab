# EC2 镜像预拉取优化

> **日期**: 2026-01-29
> **状态**: ✅ 已实施并验证

---

## 问题

用户报告新会话启动慢（"任务起来要半天"）。

### 诊断过程

1. 检查 ECS Task 启动时间：
```bash
aws ecs describe-tasks --cluster optima-prod-cluster --tasks <task-arn> \
  --query 'tasks[0].{PullStart:pullStartedAt,PullEnd:pullStoppedAt}'
```

2. 发现问题：
| Task | EC2 实例 | 镜像拉取时间 |
|------|---------|-------------|
| 正常 Task | 有缓存的实例 | **0.05 秒** |
| 慢 Task | 新启动的实例 | **44 秒** |

3. 根因：EC2 刚从 Warm Pool 启动，没有 Docker 镜像缓存。

---

## 解决方案

在 Launch Template 的 `user_data` 中添加镜像预拉取：

```bash
#!/bin/bash

# ECS Agent 配置
echo "ECS_CLUSTER=${CLUSTER_NAME}" >> /etc/ecs/ecs.config
echo "ECS_WARM_POOLS_CHECK=true" >> /etc/ecs/ecs.config
echo "ECS_ENABLE_SPOT_INSTANCE_DRAINING=true" >> /etc/ecs/ecs.config
echo "ECS_CONTAINER_STOP_TIMEOUT=120s" >> /etc/ecs/ecs.config

# 镜像预拉取（在后台执行，加速首次任务启动）
# 等待 Docker 服务启动
until systemctl is-active docker; do sleep 5; done

# 登录 ECR 并预拉取镜像
REGION="ap-southeast-1"
ECR_URL="585891120210.dkr.ecr.ap-southeast-1.amazonaws.com/optima-ai-shell"
IMAGE_TAG="latest"

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $(echo $ECR_URL | cut -d'/' -f1)
docker pull $ECR_URL:$IMAGE_TAG &

echo "Image pre-pull initiated for $ECR_URL:$IMAGE_TAG"
```

---

## Terraform 实现

修改 `modules/ai-shell-ecs/main.tf` 的 Launch Template：

```hcl
resource "aws_launch_template" "ecs_instance" {
  # ...

  user_data = base64encode(<<-EOF
    #!/bin/bash

    # ECS Agent 配置
    echo "ECS_CLUSTER=${var.ecs_cluster_name}" >> /etc/ecs/ecs.config
    # ...

    # 镜像预拉取
    until systemctl is-active docker; do sleep 5; done

    REGION="${data.aws_region.current.name}"
    ECR_URL="${var.ecr_repository_url}"
    IMAGE_TAG="${var.container_image_tag}"

    aws ecr get-login-password --region $REGION | \
      docker login --username AWS --password-stdin $(echo $ECR_URL | cut -d'/' -f1)
    docker pull $ECR_URL:$IMAGE_TAG &
  EOF
  )
}
```

---

## 生效流程

1. `terraform apply` - 更新 Launch Template
2. 触发 Instance Refresh 让现有实例更新：
```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name ai-shell-prod-ecs-asg \
  --preferences '{"MinHealthyPercentage": 50}' \
  --region ap-southeast-1
```
3. 监控刷新进度：
```bash
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name ai-shell-prod-ecs-asg \
  --query 'InstanceRefreshes[0].{Status:Status,Percent:PercentageComplete}' \
  --region ap-southeast-1
```

---

## 效果

| 指标 | 优化前 | 优化后 |
|------|--------|--------|
| 新 EC2 首次 Task 启动 | 44 秒 | **< 1 秒** |
| 镜像拉取时间 | 44 秒 | 0 秒（已缓存） |

---

## 相关提交

- `8c29908` - perf: EC2 启动时预拉取镜像，加速 Task 冷启动
- `ed2211a` - chore: AI Shell Prod ASG 扩容至 5 实例，添加 tfvars 到 git

---

## 后续优化

### Golden AMI 方案

如果 EC2 冷启动仍然太慢，可以使用 Packer 构建包含镜像的 Golden AMI：

1. 每次 Docker 镜像更新时自动构建新 AMI
2. AMI 中已包含 Docker 镜像缓存
3. 启动时间可进一步降低 30-60 秒

详见 [startup-optimization.md](../../private/notes-private/projects/active/ai-shell/startup-optimization.md) 中的 Golden AMI 章节。
