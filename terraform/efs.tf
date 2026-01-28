# ============================================================================
# EFS File System
# ============================================================================

resource "aws_efs_file_system" "test" {
  creation_token = var.project_name
  encrypted      = true

  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"

  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  lifecycle_policy {
    transition_to_primary_storage_class = "AFTER_1_ACCESS"
  }

  tags = {
    Name    = var.project_name
    Project = var.project_name
  }
}

# ============================================================================
# EFS Security Group
# ============================================================================

resource "aws_security_group" "efs" {
  name        = "${var.project_name}-efs"
  description = "Security group for EFS mount targets"
  vpc_id      = var.vpc_id

  # 允许 Fargate 任务访问
  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }

  # 允许 EC2 实例访问
  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  tags = {
    Name    = "${var.project_name}-efs"
    Project = var.project_name
  }
}

# ============================================================================
# EFS Mount Targets (one per subnet)
# ============================================================================

resource "aws_efs_mount_target" "private" {
  count = length(var.private_subnet_ids)

  file_system_id  = aws_efs_file_system.test.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# 公有子网的 Mount Target（EC2 测试用）
resource "aws_efs_mount_target" "public" {
  count = length(var.public_subnet_ids)

  file_system_id  = aws_efs_file_system.test.id
  subnet_id       = var.public_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# ============================================================================
# EFS Access Point - Shared (for warm pool)
# ============================================================================

resource "aws_efs_access_point" "shared" {
  file_system_id = aws_efs_file_system.test.id

  root_directory {
    path = "/workspaces"

    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  posix_user {
    uid = 1000
    gid = 1000
  }

  tags = {
    Name    = "${var.project_name}-shared"
    Project = var.project_name
  }
}
