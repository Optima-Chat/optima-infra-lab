# Golden AMI 自动构建

> **状态**: 🚧 已创建配置，待测试
> **日期**: 2026-01-29

---

## 概述

Golden AMI 是预装所有依赖的自定义 AMI，类似于"精装房"，启动后无需额外配置。

### 对比

| 比喻 | 说明 | 冷启动时间 |
|------|------|-----------|
| 普通 AMI | 毛坯房，每次入住都要装修 | ~180s |
| **Golden AMI** | 精装房，拎包入住 | **~60-90s** |

### 预装内容

1. **ECS Agent 配置** - `/etc/ecs/ecs.config`
2. **Docker 镜像** - 预拉取 AI Shell 镜像
3. **EBS 预热** - 读取关键文件触发从 S3 加载

---

## 使用方法

### 方式一：手动构建

```bash
cd packer

# 首次运行需要初始化
packer init .

# 构建（使用默认配置）
./build.sh

# 构建（指定镜像 tag）
./build.sh --tag v1.2.3

# 构建（指定集群）
./build.sh --cluster optima-stage-cluster
```

### 方式二：GitHub Actions

1. 进入 [Actions 页面](../../actions/workflows/build-golden-ami.yml)
2. 点击 "Run workflow"
3. 填写参数：
   - `image_tag`: Docker 镜像 tag（默认 latest）
   - `ecs_cluster`: ECS 集群名称
   - `update_launch_template`: 是否自动更新 Launch Template

### 方式三：自动触发（可选）

在 AI Shell 镜像构建完成后自动触发 Golden AMI 构建：

```yaml
# 在 optima-ai-shell 的 workflow 中添加
- name: Trigger Golden AMI Build
  uses: peter-evans/repository-dispatch@v2
  with:
    repository: Optima-Chat/optima-infra-lab
    event-type: ai-shell-image-built
    client-payload: '{"image_tag": "${{ github.sha }}"}'
```

---

## 更新 Terraform 配置

构建完成后，更新 `terraform.tfvars`：

```hcl
# Golden AMI - 预拉取 Docker 镜像，减少冷启动 ~25s
golden_ami_id = "ami-xxxxxxxxx"  # 替换为新构建的 AMI ID
```

然后 apply：

```bash
cd terraform
terraform apply
```

---

## 更新生产环境

### 方式一：更新 Launch Template

```bash
# 1. 创建新版本
aws ec2 create-launch-template-version \
  --launch-template-name ai-shell-prod-ecs \
  --source-version '$Latest' \
  --launch-template-data '{"ImageId":"ami-xxxxxxxxx"}' \
  --region ap-southeast-1

# 2. 设为默认版本
aws ec2 modify-launch-template \
  --launch-template-name ai-shell-prod-ecs \
  --default-version '$Latest' \
  --region ap-southeast-1

# 3. 触发 Instance Refresh
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name ai-shell-prod-ecs-asg \
  --preferences '{"MinHealthyPercentage": 50}' \
  --region ap-southeast-1
```

### 方式二：修改 optima-terraform

```bash
cd /mnt/d/optima-workspace/infrastructure/optima-terraform/stacks/ai-shell-ecs

# 更新 terraform.tfvars
# 添加: golden_ami_id = "ami-xxxxxxxxx"

terraform apply
```

---

## 构建时间估算

| 步骤 | 时间 |
|------|------|
| 启动临时 EC2 | 1-2 min |
| 配置 ECS Agent | ~10s |
| 登录 ECR | ~5s |
| 拉取 Docker 镜像 | 2-3 min |
| 预热 EBS | 1-2 min |
| 创建 AMI 快照 | 3-5 min |
| **总计** | **8-12 min** |

---

## 效果

| 场景 | 普通 AMI | Golden AMI | 提升 |
|------|---------|-----------|------|
| EC2 冷启动 | ~180s | **~60-90s** | 50-67% |
| Warm Pool 恢复 | ~22s | **~15s** | 32% |
| 首次 Task 启动 | +44s | **0s** | 100% |

---

## 注意事项

### 镜像更新

每次 AI Shell Docker 镜像更新后，需要重新构建 Golden AMI，否则会失去预拉取优势。

推荐流程：
1. AI Shell 代码 push → Docker 镜像构建
2. Docker 镜像推送 ECR → 触发 Golden AMI 构建
3. Golden AMI 构建完成 → 更新 Launch Template
4. Instance Refresh → 新实例使用新 AMI

### EBS 加密

为支持 EC2 Hibernation，EBS 必须启用加密。Golden AMI 已配置 `encrypted = true`。

### 清理旧 AMI

定期清理旧的 Golden AMI 以节省存储成本：

```bash
# 列出所有 Golden AMI
aws ec2 describe-images \
  --owners self \
  --filters "Name=name,Values=ai-shell-golden-*" \
  --query 'Images[*].[ImageId,Name,CreationDate]' \
  --output table \
  --region ap-southeast-1

# 删除旧 AMI
aws ec2 deregister-image --image-id ami-xxxxxxxxx --region ap-southeast-1
```

---

## 相关文件

- [packer/ai-shell-golden.pkr.hcl](../packer/ai-shell-golden.pkr.hcl) - Packer 配置
- [packer/build.sh](../packer/build.sh) - 构建脚本
- [.github/workflows/build-golden-ami.yml](../.github/workflows/build-golden-ami.yml) - GitHub Actions
