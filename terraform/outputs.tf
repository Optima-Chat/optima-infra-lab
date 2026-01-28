output "ecs_cluster_arn" {
  description = "ECS Cluster ARN"
  value       = aws_ecs_cluster.test.arn
}

output "ecs_cluster_name" {
  description = "ECS Cluster name"
  value       = aws_ecs_cluster.test.name
}

output "ecs_task_definition_arn" {
  description = "ECS Task Definition ARN"
  value       = aws_ecs_task_definition.warm.arn
}

output "ecs_task_definition_family" {
  description = "ECS Task Definition family"
  value       = aws_ecs_task_definition.warm.family
}

output "ecs_service_name" {
  description = "ECS Service name"
  value       = aws_ecs_service.warm_pool.name
}

output "ecr_repository_url" {
  description = "ECR Repository URL"
  value       = aws_ecr_repository.test.repository_url
}

output "efs_file_system_id" {
  description = "EFS File System ID"
  value       = aws_efs_file_system.test.id
}

output "efs_access_point_id" {
  description = "EFS Access Point ID"
  value       = aws_efs_access_point.shared.id
}

output "security_group_tasks_id" {
  description = "Security Group ID for tasks"
  value       = aws_security_group.tasks.id
}

output "cloudwatch_log_group" {
  description = "CloudWatch Log Group name"
  value       = aws_cloudwatch_log_group.tasks.name
}

# 生成环境变量导出命令
output "env_exports" {
  description = "Environment variable exports for scripts"
  value       = <<-EOT
    export ECS_CLUSTER_ARN="${aws_ecs_cluster.test.arn}"
    export ECS_CLUSTER_NAME="${aws_ecs_cluster.test.name}"
    export ECS_TASK_DEFINITION="${aws_ecs_task_definition.warm.family}"
    export ECS_SERVICE_NAME="${aws_ecs_service.warm_pool.name}"
    export ECR_REPOSITORY_URL="${aws_ecr_repository.test.repository_url}"
    export EFS_FILE_SYSTEM_ID="${aws_efs_file_system.test.id}"
    export EFS_ACCESS_POINT_ID="${aws_efs_access_point.shared.id}"
    export SECURITY_GROUP_ID="${aws_security_group.tasks.id}"
    export LOG_GROUP="${aws_cloudwatch_log_group.tasks.name}"
  EOT
}

# ============================================================================
# EC2 Warm Pool Outputs
# ============================================================================

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.ecs.name
}

output "launch_template_id" {
  description = "Launch Template ID"
  value       = aws_launch_template.ecs.id
}

output "ec2_task_definition_arn" {
  description = "EC2 ECS Task Definition ARN"
  value       = aws_ecs_task_definition.ec2.arn
}

output "ec2_task_definition_family" {
  description = "EC2 ECS Task Definition family"
  value       = aws_ecs_task_definition.ec2.family
}

output "ec2_service_name" {
  description = "EC2 ECS Service name"
  value       = aws_ecs_service.ec2.name
}

# 常用命令
output "useful_commands" {
  description = "Useful commands for testing"
  value       = <<-EOT

    # ========== Fargate 测试 ==========

    # 1. 构建并推送镜像
    ./scripts/deploy.sh

    # 2. 强制重新部署（拉取新镜像）
    aws ecs update-service --cluster ${aws_ecs_cluster.test.name} --service ${aws_ecs_service.warm_pool.name} --force-new-deployment

    # 3. 查看任务列表
    aws ecs list-tasks --cluster ${aws_ecs_cluster.test.name}

    # 4. 查看日志
    aws logs tail ${aws_cloudwatch_log_group.tasks.name} --follow

    # 5. 进入容器（ECS Exec）
    TASK_ARN=$(aws ecs list-tasks --cluster ${aws_ecs_cluster.test.name} --query 'taskArns[0]' --output text)
    aws ecs execute-command --cluster ${aws_ecs_cluster.test.name} --task $TASK_ARN --container test --interactive --command /bin/bash

    # ========== EC2 Warm Pool 测试 ==========

    # 6. 查看 ASG 状态
    aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${aws_autoscaling_group.ecs.name} --query 'AutoScalingGroups[0].{Desired:DesiredCapacity,Min:MinSize,Max:MaxSize,Instances:Instances[*].{Id:InstanceId,State:LifecycleState}}'

    # 7. 查看 Warm Pool 状态
    aws autoscaling describe-warm-pool --auto-scaling-group-name ${aws_autoscaling_group.ecs.name}

    # 8. 测试从 Warm Pool 启动（增加 desired capacity）
    ./scripts/test-ec2-warm-start.sh

    # 9. 测试 EC2 冷启动时间
    ./scripts/test-ec2-cold-start.sh

    # 10. 查看 EC2 实例启动日志
    # SSH 进入实例后: cat /var/log/boot-timing.log

  EOT
}
