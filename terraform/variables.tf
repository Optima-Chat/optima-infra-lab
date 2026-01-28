variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "fargate-warm-pool-test"
}

variable "vpc_id" {
  description = "VPC ID (use existing optima VPC)"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS tasks"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for EC2 instances (testing)"
  type        = list(string)
  default     = []
}

variable "ecr_repository_url" {
  description = "ECR repository URL for test image"
  type        = string
  default     = ""
}

variable "gateway_url" {
  description = "Session Gateway WebSocket URL for warm tasks to connect"
  type        = string
  default     = "ws://localhost:5174"
}

variable "warm_pool_size" {
  description = "Number of warm tasks to maintain"
  type        = number
  default     = 3
}

variable "task_cpu" {
  description = "Task CPU units (256 = 0.25 vCPU)"
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Task memory in MB"
  type        = number
  default     = 512
}

# ============================================================================
# EC2 Warm Pool 配置
# ============================================================================

variable "ec2_instance_type" {
  description = "EC2 instance type for ECS"
  type        = string
  default     = "t3.small"  # 2 vCPU, 2GB RAM
}

variable "ec2_asg_min_size" {
  description = "ASG minimum size (running instances)"
  type        = number
  default     = 0
}

variable "ec2_asg_max_size" {
  description = "ASG maximum size"
  type        = number
  default     = 5
}

variable "ec2_asg_desired_capacity" {
  description = "ASG desired capacity (running instances)"
  type        = number
  default     = 1
}

variable "ec2_warm_pool_state" {
  description = "Warm pool instance state: Stopped, Hibernated, or Running"
  type        = string
  default     = "Hibernated"  # Hibernated 比 Stopped 启动更快
}

variable "ec2_warm_pool_min_size" {
  description = "Minimum number of instances in warm pool"
  type        = number
  default     = 2
}

variable "ec2_warm_pool_max_size" {
  description = "Maximum prepared capacity (running + warm pool)"
  type        = number
  default     = 5
}

variable "ec2_service_desired_count" {
  description = "Desired count for EC2 ECS service"
  type        = number
  default     = 1
}

# ============================================================================
# AI Shell 镜像配置
# ============================================================================

variable "use_ai_shell_image" {
  description = "Use AI Shell image instead of test image"
  type        = bool
  default     = false
}

variable "ai_shell_image" {
  description = "AI Shell ECR image URI"
  type        = string
  default     = "585891120210.dkr.ecr.ap-southeast-1.amazonaws.com/optima-ai-shell:latest"
}

variable "warm_pool_mode" {
  description = "Enable warm pool mode for AI Shell container"
  type        = bool
  default     = true
}

# ============================================================================
# 启动优化配置
# ============================================================================

variable "optimized_userdata" {
  description = "Use optimized User Data (reduced EBS warming)"
  type        = bool
  default     = false
}
