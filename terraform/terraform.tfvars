# Fargate 预热池测试配置

aws_region   = "ap-southeast-1"
project_name = "fargate-warm-pool-test"

# 使用 Optima Prod VPC
vpc_id = "vpc-0543daa6f6e4e536e"

# 私有子网（Fargate 用）
private_subnet_ids = [
  "subnet-04c0aa568f25b5d85",  # ap-southeast-1a
  "subnet-04efcc49ea9ef1db1",  # ap-southeast-1b
]

# 公有子网（EC2 测试用）
public_subnet_ids = [
  "subnet-0bb13203dfaca7b6e",  # ap-southeast-1a public
  "subnet-0b9a2e79d20bc489f",  # ap-southeast-1b public
]

# Fargate 预热池大小
warm_pool_size = 1

# 任务资源（小规格，测试更多预热 Task）
task_cpu    = 128   # 0.125 vCPU
task_memory = 256   # 256 MB

# ============================================================================
# EC2 Warm Pool 配置
# ============================================================================

ec2_instance_type = "t3.small"  # 2 vCPU, 2GB RAM

# ASG 配置
ec2_asg_min_size         = 0
ec2_asg_max_size         = 5
ec2_asg_desired_capacity = 1   # 保持 1 个运行实例

# Warm Pool 配置
ec2_warm_pool_state    = "Hibernated"  # 休眠状态，比 Stopped 启动更快
ec2_warm_pool_min_size = 2             # 至少保持 2 个预热实例
ec2_warm_pool_max_size = 3             # 最大预热容量（测试用，减少资源）

# EC2 ECS Service
ec2_service_desired_count = 1
