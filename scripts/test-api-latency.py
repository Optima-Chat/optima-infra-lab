#!/usr/bin/env python3
"""
AWS ECS API 延迟测试脚本

测量 list_tasks 和 describe_tasks API 的延迟，
用于评估预热池分配的上限延迟（实际预热池使用内存操作，不需要调用 API）。

使用方法:
    python3 test-api-latency.py
    python3 test-api-latency.py --iterations 20
"""

import argparse
import boto3
import time
import sys

# 默认配置
CLUSTER = "fargate-warm-pool-test"
SERVICE = "fargate-warm-pool-test-ec2-service"
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


def test_api_latency(iterations: int = 10, verbose: bool = True):
    """测试 ECS API 延迟"""
    ecs = boto3.client("ecs", region_name=REGION)

    print("=" * 50)
    print("     AWS ECS API 延迟测试")
    print("=" * 50)
    print()
    print(f"Cluster: {CLUSTER}")
    print(f"Service: {SERVICE}")
    print(f"Iterations: {iterations}")
    print()

    list_times = []
    describe_times = []
    total_times = []

    for i in range(iterations):
        total_start = time.time()

        # list_tasks
        start = time.time()
        resp = ecs.list_tasks(
            cluster=CLUSTER, serviceName=SERVICE, desiredStatus="RUNNING"
        )
        list_time = (time.time() - start) * 1000
        list_times.append(list_time)

        task_arns = resp.get("taskArns", [])

        # describe_tasks
        if task_arns:
            start = time.time()
            ecs.describe_tasks(cluster=CLUSTER, tasks=task_arns[:1])
            desc_time = (time.time() - start) * 1000
            describe_times.append(desc_time)
        else:
            desc_time = 0

        total_time = (time.time() - total_start) * 1000
        total_times.append(total_time)

        if verbose:
            print(
                f"  Run {i+1:2d}: list={list_time:6.0f}ms, describe={desc_time:6.0f}ms, total={total_time:6.0f}ms"
            )

        # 避免 API throttling
        time.sleep(0.1)

    print()
    print("-" * 50)
    print("Results:")
    print("-" * 50)

    list_stats = calculate_stats(list_times)
    desc_stats = calculate_stats(describe_times)
    total_stats = calculate_stats(total_times)

    print(
        f"  list_tasks:     avg={list_stats['avg']:6.0f}ms  min={list_stats['min']:6.0f}ms  max={list_stats['max']:6.0f}ms  p95={list_stats['p95']:6.0f}ms"
    )
    print(
        f"  describe_tasks: avg={desc_stats['avg']:6.0f}ms  min={desc_stats['min']:6.0f}ms  max={desc_stats['max']:6.0f}ms  p95={desc_stats['p95']:6.0f}ms"
    )
    print(
        f"  total:          avg={total_stats['avg']:6.0f}ms  min={total_stats['min']:6.0f}ms  max={total_stats['max']:6.0f}ms  p95={total_stats['p95']:6.0f}ms"
    )

    print()
    print("-" * 50)
    print("Note: 预热池实际分配是内存操作 (~1ms)，不需要调用 AWS API")
    print("      这里测试的是上限延迟，用于回退场景评估")
    print("-" * 50)

    return {
        "list_tasks": list_stats,
        "describe_tasks": desc_stats,
        "total": total_stats,
    }


def main():
    parser = argparse.ArgumentParser(description="AWS ECS API 延迟测试")
    parser.add_argument(
        "--iterations", "-n", type=int, default=10, help="测试迭代次数"
    )
    parser.add_argument("--quiet", "-q", action="store_true", help="静默模式")

    args = parser.parse_args()

    try:
        test_api_latency(iterations=args.iterations, verbose=not args.quiet)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
