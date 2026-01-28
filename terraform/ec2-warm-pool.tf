# ============================================================================
# ECS on EC2 + Warm Pool 测试配置
# 用于测试 EC2 预热后的启动时间
# ============================================================================

# 获取最新的 ECS 优化 AMI
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

# ============================================================================
# User Data 版本
# ============================================================================

# 完整版 User Data (深度预热，~22s)
locals {
  userdata_full = <<-EOF
    #!/bin/bash
    set -ex
    echo "EC2_BOOT_START=$(date +%s%3N)" >> /var/log/boot-timing.log

    cat >> /etc/ecs/ecs.config <<ECSCONFIG
    ECS_CLUSTER=${aws_ecs_cluster.test.name}
    ECS_WARM_POOLS_CHECK=true
    ECS_ENABLE_TASK_IAM_ROLE=true
    ECS_IMAGE_PULL_BEHAVIOR=prefer-cached
    ECSCONFIG

    if [ ! -f /var/lib/cloud/instance/sem/ebs_warmed ]; then
      echo "WARM_START=$(date +%s%3N)" >> /var/log/boot-timing.log
      find /lib/modules -type f -exec cat {} \; > /dev/null 2>&1 || true
      find /usr/bin /usr/sbin /usr/lib64 -type f -exec cat {} \; > /dev/null 2>&1 || true
      find /var/lib/docker -type f -exec cat {} \; > /dev/null 2>&1 || true
      find /var/lib/ecs -type f -exec cat {} \; > /dev/null 2>&1 || true
      echo "WARM_END=$(date +%s%3N)" >> /var/log/boot-timing.log
      touch /var/lib/cloud/instance/sem/ebs_warmed
    fi

    echo "EC2_WARM_DONE=$(date +%s%3N)" >> /var/log/boot-timing.log
    systemctl enable ecs && systemctl start ecs
    until curl -s http://localhost:51678/v1/metadata; do sleep 1; done
    echo "ECS_AGENT_READY=$(date +%s%3N)" >> /var/log/boot-timing.log
  EOF

  # 优化版 User Data (零预热，让 EBS 按需加载)
  userdata_optimized = <<-EOF
    #!/bin/bash
    set -ex
    echo "EC2_BOOT_START=$(date +%s%3N)" >> /var/log/boot-timing.log

    # 配置 ECS Agent
    cat >> /etc/ecs/ecs.config <<ECSCONFIG
    ECS_CLUSTER=${aws_ecs_cluster.test.name}
    ECS_WARM_POOLS_CHECK=true
    ECS_ENABLE_TASK_IAM_ROLE=true
    ECS_IMAGE_PULL_BEHAVIOR=prefer-cached
    ECSCONFIG

    # 不预热！让 EBS 按需加载
    # 首次冷启动: ECS/Docker 启动时自动加载需要的文件
    # Warm Pool 恢复: EBS 已缓存，不受影响

    echo "EC2_WARM_DONE=$(date +%s%3N)" >> /var/log/boot-timing.log
    systemctl enable ecs && systemctl start ecs
    until curl -s http://localhost:51678/v1/metadata; do sleep 1; done
    echo "ECS_AGENT_READY=$(date +%s%3N)" >> /var/log/boot-timing.log
  EOF
}

# ============================================================================
# IAM Role for EC2 Instances
# ============================================================================

resource "aws_iam_role" "ec2_instance" {
  name = "${var.project_name}-ec2-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "ec2_ecs" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# EFS 访问权限
resource "aws_iam_role_policy" "ec2_efs" {
  name = "efs-access"
  role = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:ClientRootAccess"
        ]
        Resource = aws_efs_file_system.test.arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_instance.name
}

# ============================================================================
# Security Group for EC2 Instances
# ============================================================================

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2"
  description = "Security group for ECS EC2 instances"
  vpc_id      = var.vpc_id

  # 允许出站到 EFS
  egress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 允许出站到 ECR 和其他 AWS 服务
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 允许出站到 ECR（HTTP）
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-ec2"
    Project = var.project_name
  }
}

# ============================================================================
# Launch Template
# ============================================================================

resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.project_name}-ecs-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.ec2_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  # 启用 Hibernation 支持
  hibernation_options {
    configured = true
  }

  network_interfaces {
    associate_public_ip_address = true  # 测试用，分配公网 IP
    security_groups             = [aws_security_group.ec2.id]
  }

  # EBS 根卷配置（优化启动速度）
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 30  # AMI 快照大小，不能更小
      volume_type           = "gp3"
      iops                  = 3000  # 提高 IOPS 加速启动
      throughput            = 125   # 提高吞吐量
      delete_on_termination = true
      encrypted             = true  # Hibernation 要求加密
    }
  }

  # User Data: 配置 ECS Agent + EBS 预热
  # var.optimized_userdata=true 时使用精简版预热（只预热 Docker/ECS）
  # var.optimized_userdata=false 时使用深度预热（预热全部系统文件）
  user_data = base64encode(var.optimized_userdata ? local.userdata_optimized : local.userdata_full)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.project_name}-ecs-instance"
      Project = var.project_name
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name    = "${var.project_name}-ecs-volume"
      Project = var.project_name
    }
  }

  tags = {
    Project = var.project_name
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ============================================================================
# Auto Scaling Group with Warm Pool
# ============================================================================

resource "aws_autoscaling_group" "ecs" {
  name                = "${var.project_name}-ecs-asg"
  vpc_zone_identifier = length(var.public_subnet_ids) > 0 ? var.public_subnet_ids : var.private_subnet_ids
  min_size            = var.ec2_asg_min_size
  max_size            = var.ec2_asg_max_size
  desired_capacity    = var.ec2_asg_desired_capacity

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  # Warm Pool 配置
  warm_pool {
    pool_state                  = var.ec2_warm_pool_state  # "Stopped", "Hibernated" 或 "Running"
    min_size                    = var.ec2_warm_pool_min_size
    max_group_prepared_capacity = var.ec2_warm_pool_max_size

    instance_reuse_policy {
      reuse_on_scale_in = true
    }
  }

  # 健康检查
  health_check_type         = "EC2"
  health_check_grace_period = 60

  # 实例刷新配置
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-ecs-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}

# ============================================================================
# ECS Capacity Provider (EC2)
# ============================================================================

resource "aws_ecs_capacity_provider" "ec2" {
  name = "warm-pool-test-ec2-cp"  # 不能包含 "fargate"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.ecs.arn
    managed_termination_protection = "DISABLED"

    managed_scaling {
      maximum_scaling_step_size = 2
      minimum_scaling_step_size = 1
      status                    = "DISABLED"  # 禁用托管扩缩，手动控制测试
      target_capacity           = 100
    }
  }

  tags = {
    Project = var.project_name
  }
}

# 更新 Cluster 的 Capacity Providers
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.test.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT", aws_ecs_capacity_provider.ec2.name]

  # EC2 作为默认（测试 EC2 Warm Pool）
  default_capacity_provider_strategy {
    base              = 0
    weight            = 1
    capacity_provider = aws_ecs_capacity_provider.ec2.name
  }
}

# ============================================================================
# ECS Task Definition (EC2 compatible)
# ============================================================================

resource "aws_ecs_task_definition" "ec2" {
  family                   = "${var.project_name}-ec2"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"  # EC2 使用 bridge 模式
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name  = var.use_ai_shell_image ? "ai-shell" : "test"
      image = var.use_ai_shell_image ? var.ai_shell_image : "${aws_ecr_repository.test.repository_url}:latest"

      essential = true

      cpu    = var.task_cpu
      memory = var.task_memory

      environment = var.use_ai_shell_image ? [
        { name = "WARM_POOL_MODE", value = tostring(var.warm_pool_mode) },
        { name = "GATEWAY_WS_URL", value = var.gateway_url },
        { name = "LAUNCH_TYPE", value = "EC2" },
      ] : [
        { name = "TEST_MODE", value = "standalone" },
        { name = "LAUNCH_TYPE", value = "EC2" },
      ]

      mountPoints = [
        {
          sourceVolume  = "efs-workspaces"
          containerPath = "/mnt/efs"
          readOnly      = false
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.tasks.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = var.use_ai_shell_image ? "ai-shell" : "ec2"
        }
      }

      linuxParameters = {
        initProcessEnabled = true
      }
    }
  ])

  volume {
    name = "efs-workspaces"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.test.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.shared.id
        iam             = "ENABLED"
      }
    }
  }

  tags = {
    Project = var.project_name
  }
}

# ============================================================================
# ECS Service (EC2)
# ============================================================================

resource "aws_ecs_service" "ec2" {
  name            = "${var.project_name}-ec2-service"
  cluster         = aws_ecs_cluster.test.id
  task_definition = aws_ecs_task_definition.ec2.arn
  desired_count   = var.ec2_service_desired_count

  # 启用 ECS Exec
  enable_execute_command = true

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 1
    base              = 1
  }

  # 等待稳定状态的时间
  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 50

  tags = {
    Project = var.project_name
  }

  # 依赖 capacity provider 关联
  depends_on = [aws_ecs_cluster_capacity_providers.main]

  lifecycle {
    ignore_changes = [desired_count]
  }
}
