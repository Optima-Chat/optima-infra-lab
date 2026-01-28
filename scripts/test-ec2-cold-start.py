#!/usr/bin/env python3
"""
EC2 冷启动时间测试脚本

测量从 ASG 扩容到 Task 就绪的完整时间，包括：
- EC2 实例创建时间
- ECS Agent 注册时间
- Task 调度和启动时间

场景:
1. EC2 Warm Pool 启动（从 Stopped/Hibernated 状态）
2. EC2 冷启动（无 Warm Pool，完全新建实例）

使用方法:
    python3 test-ec2-cold-start.py --mode warm      # 测试 Warm Pool 启动
    python3 test-ec2-cold-start.py --mode cold      # 测试完全冷启动
    python3 test-ec2-cold-start.py --status         # 查看当前状态
"""

import argparse
import boto3
import time
import sys
from datetime import datetime

# 默认配置
CLUSTER = "fargate-warm-pool-test"
ASG_NAME = "fargate-warm-pool-test-ecs-asg"
TASK_DEFINITION = "fargate-warm-pool-test-ec2"
SERVICE_NAME = "fargate-warm-pool-test-ec2-service"
REGION = "ap-southeast-1"


def get_asg_status(autoscaling, asg_name: str) -> dict:
    """获取 ASG 状态"""
    response = autoscaling.describe_auto_scaling_groups(
        AutoScalingGroupNames=[asg_name]
    )
    if not response.get("AutoScalingGroups"):
        raise ValueError(f"ASG {asg_name} not found")

    asg = response["AutoScalingGroups"][0]

    # 获取 Warm Pool 状态
    try:
        wp_response = autoscaling.describe_warm_pool(AutoScalingGroupName=asg_name)
        warm_pool = wp_response.get("WarmPoolConfiguration", {})
        warm_instances = wp_response.get("Instances", [])
    except Exception:
        warm_pool = {}
        warm_instances = []

    return {
        "min_size": asg["MinSize"],
        "max_size": asg["MaxSize"],
        "desired_capacity": asg["DesiredCapacity"],
        "instances": asg.get("Instances", []),
        "warm_pool_config": warm_pool,
        "warm_pool_instances": warm_instances,
    }


def wait_for_instance_in_service(autoscaling, asg_name: str, timeout: int = 300) -> float:
    """等待新实例进入 InService 状态"""
    start = time.time()
    initial_in_service = set()

    # 获取初始 InService 实例
    status = get_asg_status(autoscaling, asg_name)
    for inst in status["instances"]:
        if inst["LifecycleState"] == "InService":
            initial_in_service.add(inst["InstanceId"])

    print(f"  初始 InService 实例: {len(initial_in_service)} 个")

    while True:
        elapsed = time.time() - start
        if elapsed > timeout:
            raise TimeoutError(f"实例未能在 {timeout}s 内进入 InService")

        status = get_asg_status(autoscaling, asg_name)

        current_in_service = set()
        pending = 0
        for inst in status["instances"]:
            if inst["LifecycleState"] == "InService":
                current_in_service.add(inst["InstanceId"])
            elif inst["LifecycleState"] in ["Pending", "Pending:Wait", "Pending:Proceed"]:
                pending += 1

        # 检查是否有新的 InService 实例
        new_in_service = current_in_service - initial_in_service
        if new_in_service:
            return elapsed, list(new_in_service)[0]

        print(f"    [{elapsed:.0f}s] InService: {len(current_in_service)}, Pending: {pending}")
        time.sleep(2)


def wait_for_ecs_instance(ecs, cluster: str, instance_id: str, timeout: int = 180) -> float:
    """等待 EC2 实例注册到 ECS Cluster"""
    start = time.time()

    while True:
        elapsed = time.time() - start
        if elapsed > timeout:
            raise TimeoutError(f"EC2 未能在 {timeout}s 内注册到 ECS Cluster")

        response = ecs.list_container_instances(cluster=cluster, status="ACTIVE")

        for ci_arn in response.get("containerInstanceArns", []):
            ci_response = ecs.describe_container_instances(
                cluster=cluster, containerInstances=[ci_arn]
            )
            for ci in ci_response.get("containerInstances", []):
                if ci.get("ec2InstanceId") == instance_id:
                    return elapsed

        print(f"    [{elapsed:.0f}s] 等待 ECS Agent 注册...")
        time.sleep(2)


def wait_for_task_running(ecs, cluster: str, service: str, min_count: int = 1, timeout: int = 120) -> float:
    """等待 Service 有运行中的 Task"""
    start = time.time()

    while True:
        elapsed = time.time() - start
        if elapsed > timeout:
            raise TimeoutError(f"Task 未能在 {timeout}s 内启动")

        response = ecs.list_tasks(cluster=cluster, serviceName=service, desiredStatus="RUNNING")
        running = len(response.get("taskArns", []))

        if running >= min_count:
            return elapsed

        print(f"    [{elapsed:.0f}s] 运行中 Task: {running}/{min_count}")
        time.sleep(2)


def print_status(verbose: bool = True):
    """打印当前 ASG 和 ECS 状态"""
    autoscaling = boto3.client("autoscaling", region_name=REGION)
    ecs = boto3.client("ecs", region_name=REGION)

    print("=" * 60)
    print("     当前基础设施状态")
    print("=" * 60)
    print()

    # ASG 状态
    try:
        status = get_asg_status(autoscaling, ASG_NAME)
        print(f"ASG: {ASG_NAME}")
        print(f"  Min/Max/Desired: {status['min_size']}/{status['max_size']}/{status['desired_capacity']}")
        print()

        print("  Running Instances:")
        if status["instances"]:
            for inst in status["instances"]:
                print(f"    - {inst['InstanceId']}: {inst['LifecycleState']}")
        else:
            print("    (none)")

        print()
        print("  Warm Pool:")
        if status["warm_pool_instances"]:
            for inst in status["warm_pool_instances"]:
                print(f"    - {inst['InstanceId']}: {inst['LifecycleState']}")
        else:
            print("    (none)")

    except Exception as e:
        print(f"  Error: {e}")

    # ECS 状态
    print()
    print(f"ECS Cluster: {CLUSTER}")

    try:
        ci_response = ecs.list_container_instances(cluster=CLUSTER, status="ACTIVE")
        ci_count = len(ci_response.get("containerInstanceArns", []))
        print(f"  Container Instances: {ci_count}")

        tasks_response = ecs.list_tasks(cluster=CLUSTER, serviceName=SERVICE_NAME, desiredStatus="RUNNING")
        task_count = len(tasks_response.get("taskArns", []))
        print(f"  Running Tasks: {task_count}")

    except Exception as e:
        print(f"  Error: {e}")

    print()


def test_warm_pool_start(verbose: bool = True) -> dict:
    """测试 EC2 Warm Pool 启动时间"""
    autoscaling = boto3.client("autoscaling", region_name=REGION)
    ecs = boto3.client("ecs", region_name=REGION)

    print("=" * 60)
    print("     EC2 Warm Pool 启动时间测试")
    print("=" * 60)
    print()

    # 获取当前状态
    status = get_asg_status(autoscaling, ASG_NAME)
    print(f"当前状态:")
    print(f"  Desired Capacity: {status['desired_capacity']}")
    print(f"  Running Instances: {len([i for i in status['instances'] if i['LifecycleState'] == 'InService'])}")
    print(f"  Warm Pool Instances: {len(status['warm_pool_instances'])}")

    if not status["warm_pool_instances"]:
        print()
        print("Error: Warm Pool 为空，无法测试 Warm Pool 启动")
        print("       请先运行: test-ec2-cold-start.py --mode cold")
        return None

    # 增加 desired_capacity 触发从 Warm Pool 启动
    new_desired = status["desired_capacity"] + 1
    print()
    print(f"触发扩容: desired_capacity {status['desired_capacity']} -> {new_desired}")
    print()

    start_time = time.time()
    start_dt = datetime.now()

    autoscaling.set_desired_capacity(
        AutoScalingGroupName=ASG_NAME,
        DesiredCapacity=new_desired,
    )

    print(f"[{start_dt.strftime('%H:%M:%S')}] 扩容请求已发送")

    # 等待实例 InService
    print()
    print("阶段 1: 等待 EC2 实例 InService...")
    ec2_time, instance_id = wait_for_instance_in_service(autoscaling, ASG_NAME)
    print(f"  EC2 InService! 耗时: {ec2_time:.1f}s")
    print(f"  Instance ID: {instance_id}")

    # 等待 ECS Agent 注册
    print()
    print("阶段 2: 等待 ECS Agent 注册...")
    ecs_time = wait_for_ecs_instance(ecs, CLUSTER, instance_id)
    print(f"  ECS Agent 注册完成! 耗时: {ecs_time:.1f}s (从扩容开始)")

    # 等待 Task 运行
    print()
    print("阶段 3: 等待 Task 调度...")
    task_time = wait_for_task_running(ecs, CLUSTER, SERVICE_NAME)
    print(f"  Task 运行! 耗时: {task_time:.1f}s (从扩容开始)")

    total_time = time.time() - start_time

    print()
    print("=" * 60)
    print("Results:")
    print("=" * 60)
    print()
    print(f"  EC2 启动 (Warm Pool -> InService): {ec2_time:.1f}s")
    print(f"  ECS Agent 注册:                    {ecs_time - ec2_time:.1f}s")
    print(f"  Task 调度:                         {task_time - ecs_time:.1f}s")
    print(f"  ─────────────────────────────────────")
    print(f"  总时间:                            {total_time:.1f}s")
    print()

    return {
        "ec2_start_time": ec2_time,
        "ecs_register_time": ecs_time,
        "task_start_time": task_time,
        "total_time": total_time,
        "instance_id": instance_id,
    }


def test_cold_start(verbose: bool = True) -> dict:
    """测试 EC2 完全冷启动时间（无 Warm Pool）"""
    autoscaling = boto3.client("autoscaling", region_name=REGION)
    ecs = boto3.client("ecs", region_name=REGION)

    print("=" * 60)
    print("     EC2 完全冷启动时间测试")
    print("=" * 60)
    print()

    # 获取当前状态
    status = get_asg_status(autoscaling, ASG_NAME)
    print(f"当前状态:")
    print(f"  Desired Capacity: {status['desired_capacity']}")
    print(f"  Running Instances: {len([i for i in status['instances'] if i['LifecycleState'] == 'InService'])}")
    print(f"  Warm Pool Instances: {len(status['warm_pool_instances'])}")
    print()

    # 如果有 Warm Pool 实例，需要先清空
    if status["warm_pool_instances"]:
        print("Warning: Warm Pool 不为空")
        print("         冷启动测试需要先清空 Warm Pool")
        print("         可以通过 Terraform 临时禁用 Warm Pool 来测试")
        print()
        print("建议步骤:")
        print("  1. terraform apply -var='ec2_warm_pool_min_size=0' -var='ec2_warm_pool_max_size=0'")
        print("  2. 等待 Warm Pool 实例终止")
        print("  3. 再运行此测试")
        print()

        # 继续测试，但标记为 "可能使用了 Warm Pool"
        print("继续测试（结果可能不准确，因为可能使用了 Warm Pool）...")
        print()

    # 增加 desired_capacity 触发扩容
    new_desired = status["desired_capacity"] + 1
    print(f"触发扩容: desired_capacity {status['desired_capacity']} -> {new_desired}")
    print()

    start_time = time.time()
    start_dt = datetime.now()

    autoscaling.set_desired_capacity(
        AutoScalingGroupName=ASG_NAME,
        DesiredCapacity=new_desired,
    )

    print(f"[{start_dt.strftime('%H:%M:%S')}] 扩容请求已发送")

    # 等待实例 InService
    print()
    print("阶段 1: 等待 EC2 实例创建并 InService...")
    ec2_time, instance_id = wait_for_instance_in_service(autoscaling, ASG_NAME, timeout=600)
    print(f"  EC2 InService! 耗时: {ec2_time:.1f}s")
    print(f"  Instance ID: {instance_id}")

    # 等待 ECS Agent 注册
    print()
    print("阶段 2: 等待 ECS Agent 注册...")
    ecs_time = wait_for_ecs_instance(ecs, CLUSTER, instance_id)
    print(f"  ECS Agent 注册完成! 耗时: {ecs_time:.1f}s (从扩容开始)")

    # 等待 Task 运行
    print()
    print("阶段 3: 等待 Task 调度...")
    task_time = wait_for_task_running(ecs, CLUSTER, SERVICE_NAME)
    print(f"  Task 运行! 耗时: {task_time:.1f}s (从扩容开始)")

    total_time = time.time() - start_time

    print()
    print("=" * 60)
    print("Results:")
    print("=" * 60)
    print()
    print(f"  EC2 创建 -> InService:             {ec2_time:.1f}s")
    print(f"  ECS Agent 注册:                    {ecs_time - ec2_time:.1f}s")
    print(f"  Task 调度:                         {task_time - ecs_time:.1f}s")
    print(f"  ─────────────────────────────────────")
    print(f"  总时间:                            {total_time:.1f}s")
    print()

    return {
        "ec2_start_time": ec2_time,
        "ecs_register_time": ecs_time,
        "task_start_time": task_time,
        "total_time": total_time,
        "instance_id": instance_id,
    }


def scale_down(target: int = 1, verbose: bool = True):
    """缩容 ASG"""
    autoscaling = boto3.client("autoscaling", region_name=REGION)

    status = get_asg_status(autoscaling, ASG_NAME)
    current = status["desired_capacity"]

    if current <= target:
        print(f"当前 desired_capacity={current} 已经 <= {target}，无需缩容")
        return

    print(f"缩容: desired_capacity {current} -> {target}")
    autoscaling.set_desired_capacity(
        AutoScalingGroupName=ASG_NAME,
        DesiredCapacity=target,
    )
    print("缩容请求已发送")


def main():
    parser = argparse.ArgumentParser(description="EC2 冷启动时间测试")
    parser.add_argument(
        "--mode", "-m",
        choices=["warm", "cold", "status", "scale-down"],
        default="status",
        help="测试模式: warm(Warm Pool启动), cold(冷启动), status(查看状态), scale-down(缩容)"
    )
    parser.add_argument(
        "--target", "-t",
        type=int,
        default=1,
        help="scale-down 目标 desired_capacity (默认: 1)"
    )
    parser.add_argument("--quiet", "-q", action="store_true", help="静默模式")

    args = parser.parse_args()

    try:
        if args.mode == "status":
            print_status(verbose=not args.quiet)
        elif args.mode == "warm":
            test_warm_pool_start(verbose=not args.quiet)
        elif args.mode == "cold":
            test_cold_start(verbose=not args.quiet)
        elif args.mode == "scale-down":
            scale_down(target=args.target, verbose=not args.quiet)
    except KeyboardInterrupt:
        print("\n\n测试中断")
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
