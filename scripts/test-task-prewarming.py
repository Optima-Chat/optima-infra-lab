#!/usr/bin/env python3
"""
Task 预热池测试脚本

测试共享 AP + Task 预热池方案的各项指标:
1. EFS 目录操作延迟
2. 预热 Task 分配延迟（模拟）
3. 端到端流程时间

使用方法:
    python3 test-task-prewarming.py --test all
    python3 test-task-prewarming.py --test directory
    python3 test-task-prewarming.py --test allocation
"""

import argparse
import boto3
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from typing import Optional

# AWS 配置
AWS_REGION = "ap-southeast-1"
ECS_CLUSTER = "fargate-warm-pool-test"
ECS_SERVICE = "fargate-warm-pool-test-ec2-service"

# 测试配置
TEST_USER_PREFIX = "test-user"


class Colors:
    """终端颜色"""
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    CYAN = '\033[96m'
    END = '\033[0m'
    BOLD = '\033[1m'


def log(msg: str, color: str = ""):
    """带颜色的日志输出"""
    timestamp = datetime.now().strftime("%H:%M:%S.%f")[:-3]
    if color:
        print(f"{color}[{timestamp}] {msg}{Colors.END}")
    else:
        print(f"[{timestamp}] {msg}")


def log_success(msg: str):
    log(f"✓ {msg}", Colors.GREEN)


def log_warning(msg: str):
    log(f"⚠ {msg}", Colors.YELLOW)


def log_error(msg: str):
    log(f"✗ {msg}", Colors.RED)


def log_info(msg: str):
    log(f"→ {msg}", Colors.CYAN)


def get_running_tasks() -> list:
    """获取正在运行的 Task 列表"""
    ecs = boto3.client("ecs", region_name=AWS_REGION)

    response = ecs.list_tasks(
        cluster=ECS_CLUSTER,
        serviceName=ECS_SERVICE,
        desiredStatus="RUNNING"
    )

    task_arns = response.get("taskArns", [])

    if not task_arns:
        return []

    # 获取详细信息
    tasks_response = ecs.describe_tasks(
        cluster=ECS_CLUSTER,
        tasks=task_arns
    )

    return tasks_response.get("tasks", [])


def exec_in_container(task_arn: str, command: str, container_name: str = "test") -> tuple:
    """
    在容器内执行命令
    返回 (stdout, stderr, return_code, execution_time_ms)
    """
    start_time = time.time()

    try:
        result = subprocess.run(
            [
                "aws", "ecs", "execute-command",
                "--cluster", ECS_CLUSTER,
                "--task", task_arn,
                "--container", container_name,
                "--interactive",
                "--command", command,
                "--region", AWS_REGION
            ],
            capture_output=True,
            text=True,
            timeout=30
        )

        execution_time_ms = (time.time() - start_time) * 1000
        return result.stdout, result.stderr, result.returncode, execution_time_ms

    except subprocess.TimeoutExpired:
        return "", "Timeout", -1, 30000
    except Exception as e:
        return "", str(e), -1, 0


def test_efs_mount(task_arn: str) -> bool:
    """测试 EFS 是否正确挂载"""
    log_info(f"Testing EFS mount on task: {task_arn[-12:]}")

    stdout, stderr, rc, exec_time = exec_in_container(
        task_arn,
        "ls -la /mnt/efs && df -h /mnt/efs"
    )

    if rc == 0:
        log_success(f"EFS mounted correctly ({exec_time:.0f}ms)")
        return True
    else:
        log_error(f"EFS mount check failed: {stderr}")
        return False


def test_directory_operations(task_arn: str, iterations: int = 10) -> dict:
    """
    测试目录操作延迟
    返回各操作的延迟统计
    """
    results = {
        "mkdir": [],
        "touch": [],
        "read": [],
        "cleanup": []
    }

    log_info(f"Testing directory operations ({iterations} iterations)")

    for i in range(iterations):
        user_id = f"{TEST_USER_PREFIX}-{int(time.time())}-{i}"
        user_dir = f"/mnt/efs/{user_id}"

        # 测试 mkdir
        cmd = f"time -f '%e' mkdir -p {user_dir} 2>&1 | tail -1"
        stdout, stderr, rc, _ = exec_in_container(task_arn, cmd)
        if rc == 0 and stdout.strip():
            try:
                results["mkdir"].append(float(stdout.strip()) * 1000)
            except ValueError:
                pass

        # 测试 touch (创建文件)
        cmd = f"time -f '%e' touch {user_dir}/test.txt 2>&1 | tail -1"
        stdout, stderr, rc, _ = exec_in_container(task_arn, cmd)
        if rc == 0 and stdout.strip():
            try:
                results["touch"].append(float(stdout.strip()) * 1000)
            except ValueError:
                pass

        # 测试 read
        cmd = f"time -f '%e' cat {user_dir}/test.txt 2>&1 | tail -1"
        stdout, stderr, rc, _ = exec_in_container(task_arn, cmd)
        if rc == 0 and stdout.strip():
            try:
                results["read"].append(float(stdout.strip()) * 1000)
            except ValueError:
                pass

        # 清理
        cmd = f"time -f '%e' rm -rf {user_dir} 2>&1 | tail -1"
        stdout, stderr, rc, _ = exec_in_container(task_arn, cmd)
        if rc == 0 and stdout.strip():
            try:
                results["cleanup"].append(float(stdout.strip()) * 1000)
            except ValueError:
                pass

    return results


def calculate_stats(values: list) -> dict:
    """计算统计数据"""
    if not values:
        return {"avg": 0, "min": 0, "max": 0, "p50": 0, "p95": 0, "p99": 0}

    sorted_values = sorted(values)
    n = len(sorted_values)

    return {
        "avg": sum(values) / n,
        "min": min(values),
        "max": max(values),
        "p50": sorted_values[int(n * 0.5)] if n > 0 else 0,
        "p95": sorted_values[int(n * 0.95)] if n > 1 else sorted_values[-1],
        "p99": sorted_values[int(n * 0.99)] if n > 2 else sorted_values[-1],
    }


def print_stats_table(results: dict, title: str):
    """打印统计表格"""
    print(f"\n{Colors.BOLD}=== {title} ==={Colors.END}\n")
    print(f"{'Operation':<15} {'Avg':>10} {'Min':>10} {'Max':>10} {'P95':>10} {'P99':>10}")
    print("-" * 65)

    for op, values in results.items():
        stats = calculate_stats(values)
        print(f"{op:<15} {stats['avg']:>9.1f}ms {stats['min']:>9.1f}ms {stats['max']:>9.1f}ms {stats['p95']:>9.1f}ms {stats['p99']:>9.1f}ms")


def test_task_allocation_simulation(num_tasks: int = 5) -> dict:
    """
    模拟 Task 分配延迟

    实际的分配逻辑在 Gateway 中，这里模拟测量：
    1. 列出可用 Task 的时间
    2. 标记 Task 为已分配的时间（通过环境变量或标签）
    """
    results = {
        "list_tasks": [],
        "describe_tasks": [],
        "total": []
    }

    log_info(f"Simulating task allocation ({num_tasks} iterations)")

    ecs = boto3.client("ecs", region_name=AWS_REGION)

    for i in range(num_tasks):
        total_start = time.time()

        # 1. 列出 Task
        list_start = time.time()
        response = ecs.list_tasks(
            cluster=ECS_CLUSTER,
            serviceName=ECS_SERVICE,
            desiredStatus="RUNNING"
        )
        list_time = (time.time() - list_start) * 1000
        results["list_tasks"].append(list_time)

        task_arns = response.get("taskArns", [])

        if task_arns:
            # 2. 获取 Task 详情
            describe_start = time.time()
            ecs.describe_tasks(
                cluster=ECS_CLUSTER,
                tasks=task_arns[:1]  # 只获取一个
            )
            describe_time = (time.time() - describe_start) * 1000
            results["describe_tasks"].append(describe_time)

        total_time = (time.time() - total_start) * 1000
        results["total"].append(total_time)

        # 避免 API throttling
        time.sleep(0.2)

    return results


def test_user_init_simulation(task_arn: str) -> dict:
    """
    模拟用户初始化流程

    测量从分配 Task 到用户可用的时间：
    1. 创建用户目录
    2. 写入配置文件
    3. 切换工作目录
    """
    results = {
        "create_user_dir": [],
        "write_config": [],
        "switch_dir": [],
        "total": []
    }

    iterations = 5
    log_info(f"Simulating user initialization ({iterations} iterations)")

    for i in range(iterations):
        user_id = f"{TEST_USER_PREFIX}-init-{int(time.time())}-{i}"
        user_dir = f"/mnt/efs/{user_id}"

        total_start = time.time()

        # 1. 创建用户目录
        cmd = f"mkdir -p {user_dir}/.optima"
        stdout, stderr, rc, exec_time = exec_in_container(task_arn, cmd)
        results["create_user_dir"].append(exec_time)

        # 2. 写入配置文件
        cmd = f'echo \'{{"user": "{user_id}"}}\' > {user_dir}/.optima/config.json'
        stdout, stderr, rc, exec_time = exec_in_container(task_arn, cmd)
        results["write_config"].append(exec_time)

        # 3. 切换工作目录并验证
        cmd = f"cd {user_dir} && pwd && ls -la"
        stdout, stderr, rc, exec_time = exec_in_container(task_arn, cmd)
        results["switch_dir"].append(exec_time)

        total_time = (time.time() - total_start) * 1000
        results["total"].append(total_time)

        # 清理
        exec_in_container(task_arn, f"rm -rf {user_dir}")

    return results


def run_all_tests():
    """运行所有测试"""
    print(f"\n{Colors.BOLD}{'=' * 60}{Colors.END}")
    print(f"{Colors.BOLD}    Task 预热池测试{Colors.END}")
    print(f"{Colors.BOLD}{'=' * 60}{Colors.END}\n")

    # 获取运行中的 Task
    log_info("Getting running tasks...")
    tasks = get_running_tasks()

    if not tasks:
        log_error("No running tasks found. Please ensure ECS service is running.")
        log_info(f"Run: aws ecs update-service --cluster {ECS_CLUSTER} --service {ECS_SERVICE} --desired-count 1")
        return False

    log_success(f"Found {len(tasks)} running task(s)")

    task = tasks[0]
    task_arn = task["taskArn"]
    container_name = task["containers"][0]["name"] if task.get("containers") else "test"

    log_info(f"Using task: {task_arn[-12:]} (container: {container_name})")

    # 测试 1: EFS 挂载
    print(f"\n{Colors.BOLD}--- Test 1: EFS Mount ---{Colors.END}")
    if not test_efs_mount(task_arn):
        log_error("EFS mount test failed, aborting")
        return False

    # 测试 2: 目录操作延迟
    print(f"\n{Colors.BOLD}--- Test 2: Directory Operations ---{Colors.END}")
    dir_results = test_directory_operations(task_arn, iterations=5)
    print_stats_table(dir_results, "Directory Operations Latency")

    # 测试 3: Task 分配模拟
    print(f"\n{Colors.BOLD}--- Test 3: Task Allocation (Simulation) ---{Colors.END}")
    alloc_results = test_task_allocation_simulation(num_tasks=5)
    print_stats_table(alloc_results, "Task Allocation API Latency")

    # 测试 4: 用户初始化模拟
    print(f"\n{Colors.BOLD}--- Test 4: User Initialization (Simulation) ---{Colors.END}")
    init_results = test_user_init_simulation(task_arn)
    print_stats_table(init_results, "User Initialization Latency")

    # 总结
    print(f"\n{Colors.BOLD}{'=' * 60}{Colors.END}")
    print(f"{Colors.BOLD}    测试总结{Colors.END}")
    print(f"{Colors.BOLD}{'=' * 60}{Colors.END}\n")

    # 计算端到端时间估算
    avg_allocation = calculate_stats(alloc_results["total"])["avg"]
    avg_init = calculate_stats(init_results["total"])["avg"]
    estimated_e2e = avg_allocation + avg_init

    print(f"Task 分配 API 延迟:     {avg_allocation:>8.0f} ms")
    print(f"用户初始化延迟:         {avg_init:>8.0f} ms")
    print(f"预估端到端延迟:         {estimated_e2e:>8.0f} ms")
    print()

    # 目标对比
    target = 2000  # 2 秒
    if estimated_e2e < target:
        log_success(f"预估延迟 {estimated_e2e:.0f}ms < 目标 {target}ms")
    else:
        log_warning(f"预估延迟 {estimated_e2e:.0f}ms > 目标 {target}ms，需要优化")

    print()
    return True


def main():
    parser = argparse.ArgumentParser(description="Task 预热池测试脚本")
    parser.add_argument(
        "--test",
        choices=["all", "directory", "allocation", "init"],
        default="all",
        help="选择测试类型"
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=5,
        help="测试迭代次数"
    )

    args = parser.parse_args()

    if args.test == "all":
        success = run_all_tests()
    elif args.test == "directory":
        tasks = get_running_tasks()
        if tasks:
            results = test_directory_operations(tasks[0]["taskArn"], args.iterations)
            print_stats_table(results, "Directory Operations Latency")
            success = True
        else:
            log_error("No running tasks found")
            success = False
    elif args.test == "allocation":
        results = test_task_allocation_simulation(args.iterations)
        print_stats_table(results, "Task Allocation API Latency")
        success = True
    elif args.test == "init":
        tasks = get_running_tasks()
        if tasks:
            results = test_user_init_simulation(tasks[0]["taskArn"])
            print_stats_table(results, "User Initialization Latency")
            success = True
        else:
            log_error("No running tasks found")
            success = False

    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
