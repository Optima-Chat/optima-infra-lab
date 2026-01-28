terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ============================================================================
# ECS Cluster
# ============================================================================

resource "aws_ecs_cluster" "test" {
  name = var.project_name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Project = var.project_name
  }
}

# Capacity Providers 配置移到 ec2-warm-pool.tf 统一管理
# resource "aws_ecs_cluster_capacity_providers" "test" {
#   cluster_name = aws_ecs_cluster.test.name
#
#   capacity_providers = ["FARGATE", "FARGATE_SPOT"]
#
#   default_capacity_provider_strategy {
#     base              = 1
#     weight            = 1
#     capacity_provider = "FARGATE_SPOT"
#   }
# }

# ============================================================================
# Security Group
# ============================================================================

resource "aws_security_group" "tasks" {
  name        = "${var.project_name}-tasks"
  description = "Security group for Fargate tasks"
  vpc_id      = var.vpc_id

  # 允许出站到 EFS
  egress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 允许出站到 Gateway (WebSocket)
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 5174
    to_port     = 5174
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-tasks"
    Project = var.project_name
  }
}

# ============================================================================
# IAM Role for ECS Tasks
# ============================================================================

resource "aws_iam_role" "task_execution" {
  name = "${var.project_name}-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name = "${var.project_name}-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Project = var.project_name
  }
}

# EFS 访问权限
resource "aws_iam_role_policy" "task_efs" {
  name = "efs-access"
  role = aws_iam_role.task.id

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

# SSM 权限（用于 ECS Exec）
resource "aws_iam_role_policy" "task_ssm" {
  name = "ssm-exec"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })
}

# ============================================================================
# ECR Repository
# ============================================================================

resource "aws_ecr_repository" "test" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = {
    Project = var.project_name
  }
}

# ============================================================================
# CloudWatch Log Group
# ============================================================================

resource "aws_cloudwatch_log_group" "tasks" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 7

  tags = {
    Project = var.project_name
  }
}

# ============================================================================
# ECS Task Definition
# ============================================================================

resource "aws_ecs_task_definition" "warm" {
  family                   = "${var.project_name}-warm"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name  = "test"
      image = "${aws_ecr_repository.test.repository_url}:latest"

      essential = true

      environment = [
        { name = "TEST_MODE", value = "standalone" },
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
          "awslogs-stream-prefix" = "test"
        }
      }

      # ECS Exec 需要
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
# ECS Service - Warm Pool (Spot)
# ============================================================================

resource "aws_ecs_service" "warm_pool" {
  name            = "${var.project_name}-warm-pool"
  cluster         = aws_ecs_cluster.test.id
  task_definition = aws_ecs_task_definition.warm.arn
  desired_count   = var.warm_pool_size
  launch_type     = "FARGATE"  # 直接使用 launch_type

  # 启用 ECS Exec（方便进入容器调试）
  enable_execute_command = true

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  tags = {
    Project = var.project_name
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}
