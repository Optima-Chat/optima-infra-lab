#!/usr/bin/env python3
"""
ECS Task 启动时间测试脚本

测量从 run-task 到 Task RUNNING 的时间，用于评估：
- EC2 有空闲容量时启动新 Task 的延迟
- 预热池补充的时间

使用方法:
    python3 test-task-startup.py
    python3 test-task-startup.py --iterations 5
    python3 test-task-startup.py --cleanup  # 清理测试创建的 Task
"""

import argparse
import boto3
import time
import sys
from datetime import datetime

# 默认配置
CLUSTER = "fargate-warm-pool-test"
TASK_DEFINITION = "fargate-warm-pool-test-ec2"
REGION = "ap-southeast-1"


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
        "p50": sorted_values[int(n * 0.5)],
        "p95": sorted_values[min(int(n * 0.95), n - 1)],
        "p99": sorted_values[min(int(n * 0.99), n - 1)],
    }


def wait_for_task_running(ecs, cluster: str, task_arn: str, timeout: int = 120) -> float:
    """等待 Task 变为 RUNNING 状态，返回等待时间（秒）"""
    start = time.time()

    while True:
        elapsed = time.time() - start
        if elapsed > timeout:
            raise TimeoutError(f"Task 未能在 {timeout}s 内启动")

        response = ecs.describe_tasks(cluster=cluster, tasks=[task_arn])
        if not response.get("tasks"):
            time.sleep(0.5)
            continue

        task = response["tasks"][0]
        status = task.get("lastStatus", "UNKNOWN")

        if status == "RUNNING":
            return elapsed
        elif status in ["STOPPED", "DEPROVISIONING"]:
            reason = task.get("stoppedReason", "Unknown")
            raise RuntimeError(f"Task 停止: {reason}")

        time.sleep(0.5)


def test_task_startup(iterations: int = 3, cleanup: bool = True, verbose: bool = True):
    """测试 Task 启动时间"""
    ecs = boto3.client("ecs", region_name=REGION)

    print("=" * 60)
    print("     ECS Task 启动时间测试")
    print("=" * 60)
    print()
    print(f"Cluster:         {CLUSTER}")
    print(f"Task Definition: {TASK_DEFINITION}")
    print(f"Iterations:      {iterations}")
    print(f"Cleanup:         {cleanup}")
    print()

    # 获取 Task Definition 的完整 ARN
    try:
        td_response = ecs.describe_task_definition(taskDefinition=TASK_DEFINITION)
        td_arn = td_response["taskDefinition"]["taskDefinitionArn"]
        print(f"Task Definition ARN: {td_arn}")
    except Exception as e:
        print(f"Error: 无法获取 Task Definition: {e}")
        sys.exit(1)

    # 检查是否有 EC2 容量
    print()
    print("检查 EC2 容量...")
    container_instances = ecs.list_container_instances(cluster=CLUSTER, status="ACTIVE")
    if not container_instances.get("containerInstanceArns"):
        print("Warning: 没有活跃的 EC2 实例，测试可能失败")
        print("         请先确保 ASG desired_capacity > 0")
        return None

    print(f"  活跃 EC2 实例: {len(container_instances['containerInstanceArns'])} 个")
    print()

    startup_times = []
    created_tasks = []

    print("-" * 60)

    for i in range(iterations):
        print(f"\n[Run {i+1}/{iterations}]")

        try:
            # 记录开始时间
            start = time.time()
            start_dt = datetime.now()

            # 启动新 Task
            print(f"  {start_dt.strftime('%H:%M:%S.%f')[:-3]} - 启动 Task...")
            response = ecs.run_task(
                cluster=CLUSTER,
                taskDefinition=TASK_DEFINITION,
                count=1,
                launchType="EC2",
                enableExecuteCommand=True,
            )

            if not response.get("tasks"):
                failures = response.get("failures", [])
                reason = failures[0].get("reason", "Unknown") if failures else "Unknown"
                print(f"  Error: Task 启动失败 - {reason}")
                continue

            task_arn = response["tasks"][0]["taskArn"]
            task_id = task_arn.split("/")[-1]
            created_tasks.append(task_arn)

            api_time = time.time() - start
            print(f"  {datetime.now().strftime('%H:%M:%S.%f')[:-3]} - run-task API 返回 ({api_time*1000:.0f}ms)")
            print(f"  Task ID: {task_id}")

            # 等待 Task RUNNING
            wait_time = wait_for_task_running(ecs, CLUSTER, task_arn)

            total_time = time.time() - start
            startup_times.append(total_time)

            print(f"  {datetime.now().strftime('%H:%M:%S.%f')[:-3]} - Task RUNNING!")
            print(f"  总启动时间: {total_time:.2f}s")

        except Exception as e:
            print(f"  Error: {e}")
            continue

        # 避免资源耗尽
        if i < iterations - 1:
            time.sleep(1)

    # 清理创建的 Task
    if cleanup and created_tasks:
        print()
        print("-" * 60)
        print(f"清理 {len(created_tasks)} 个测试 Task...")
        for task_arn in created_tasks:
            try:
                ecs.stop_task(cluster=CLUSTER, task=task_arn, reason="Test cleanup")
                print(f"  Stopped: {task_arn.split('/')[-1]}")
            except Exception as e:
                print(f"  Warning: 无法停止 {task_arn}: {e}")

    # 统计结果
    print()
    print("=" * 60)
    print("Results:")
    print("=" * 60)

    if not startup_times:
        print("  没有成功的测试数据")
        return None

    stats = calculate_stats(startup_times)

    print(f"  成功次数: {len(startup_times)}/{iterations}")
    print()
    print(f"  平均启动时间:  {stats['avg']:.2f}s ({stats['avg']*1000:.0f}ms)")
    print(f"  最小启动时间:  {stats['min']:.2f}s")
    print(f"  最大启动时间:  {stats['max']:.2f}s")
    print(f"  P50:           {stats['p50']:.2f}s")
    print(f"  P95:           {stats['p95']:.2f}s")

    print()
    print("-" * 60)
    print("说明:")
    print("  - 此测试测量从 run-task 到 Task RUNNING 的时间")
    print("  - 要求 EC2 实例已有空闲容量")
    print("  - 如果 EC2 没有容量，需要等待 EC2 启动（见 test-ec2-cold-start.py）")
    print("-" * 60)

    return {
        "startup_times": startup_times,
        "stats": stats,
    }


def cleanup_tasks(verbose: bool = True):
    """清理所有测试创建的 Task"""
    ecs = boto3.client("ecs", region_name=REGION)

    print("正在清理测试 Task...")

    # 列出所有运行中的 Task
    response = ecs.list_tasks(cluster=CLUSTER, desiredStatus="RUNNING")
    task_arns = response.get("taskArns", [])

    if not task_arns:
        print("  没有运行中的 Task")
        return

    # 获取 Task 详情，只停止测试 Task Definition 的 Task
    tasks_response = ecs.describe_tasks(cluster=CLUSTER, tasks=task_arns)

    stopped = 0
    for task in tasks_response.get("tasks", []):
        td_arn = task.get("taskDefinitionArn", "")
        if TASK_DEFINITION in td_arn:
            try:
                ecs.stop_task(cluster=CLUSTER, task=task["taskArn"], reason="Manual cleanup")
                if verbose:
                    print(f"  Stopped: {task['taskArn'].split('/')[-1]}")
                stopped += 1
            except Exception as e:
                print(f"  Warning: {e}")

    print(f"  清理完成，停止了 {stopped} 个 Task")


def main():
    parser = argparse.ArgumentParser(description="ECS Task 启动时间测试")
    parser.add_argument(
        "--iterations", "-n", type=int, default=3, help="测试迭代次数 (默认: 3)"
    )
    parser.add_argument(
        "--no-cleanup", action="store_true", help="不清理测试创建的 Task"
    )
    parser.add_argument(
        "--cleanup", action="store_true", help="只执行清理操作"
    )
    parser.add_argument("--quiet", "-q", action="store_true", help="静默模式")

    args = parser.parse_args()

    try:
        if args.cleanup:
            cleanup_tasks(verbose=not args.quiet)
        else:
            test_task_startup(
                iterations=args.iterations,
                cleanup=not args.no_cleanup,
                verbose=not args.quiet,
            )
    except KeyboardInterrupt:
        print("\n\n中断测试，正在清理...")
        cleanup_tasks()
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
