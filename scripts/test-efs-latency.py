#!/usr/bin/env python3
"""
EFS 目录操作延迟测试脚本

通过 ECS Exec 在容器内部测量真实的 EFS 操作延迟。

使用方法:
    python3 test-efs-latency.py
    python3 test-efs-latency.py --iterations 10
"""

import argparse
import subprocess
import sys
import re
import json

# 默认配置
CLUSTER = "fargate-warm-pool-test"
SERVICE = "fargate-warm-pool-test-ec2-service"
REGION = "ap-southeast-1"
CONTAINER = "test"


def get_task_arn() -> str:
    """获取第一个运行中的 Task ARN"""
    result = subprocess.run(
        [
            "aws", "ecs", "list-tasks",
            "--cluster", CLUSTER,
            "--service-name", SERVICE,
            "--region", REGION,
            "--query", "taskArns[0]",
            "--output", "text"
        ],
        capture_output=True,
        text=True
    )

    task_arn = result.stdout.strip()
    if not task_arn or task_arn == "None":
        return None
    return task_arn


def run_in_container(task_arn: str, command: str) -> tuple:
    """在容器内执行命令，返回 (stdout, stderr, returncode)"""
    result = subprocess.run(
        [
            "aws", "ecs", "execute-command",
            "--cluster", CLUSTER,
            "--task", task_arn,
            "--container", CONTAINER,
            "--region", REGION,
            "--interactive",
            "--command", command
        ],
        capture_output=True,
        text=True,
        timeout=30
    )
    return result.stdout, result.stderr, result.returncode


def parse_time_output(output: str) -> float:
    """解析 time 命令输出，返回毫秒"""
    # 匹配 "real 0m0.01s" 格式
    match = re.search(r'real\s+(\d+)m\s*(\d+\.?\d*)s', output)
    if match:
        minutes = int(match.group(1))
        seconds = float(match.group(2))
        return (minutes * 60 + seconds) * 1000
    return 0


def test_efs_latency(task_arn: str, iterations: int = 5):
    """测试 EFS 操作延迟"""

    print("=" * 50)
    print("     EFS 目录操作延迟测试")
    print("=" * 50)
    print()
    print(f"Task: ...{task_arn[-12:]}")
    print(f"Container: {CONTAINER}")
    print(f"Iterations: {iterations}")
    print()

    results = {
        "mkdir": [],
        "write": [],
        "read": [],
        "full_init": []
    }

    # 清理
    run_in_container(task_arn, "rm -rf /mnt/efs/pytest-*")

    print("--- 1. mkdir 测试 ---")
    for i in range(iterations):
        cmd = f"time mkdir -p /mnt/efs/pytest-{i}/.optima 2>&1"
        stdout, stderr, rc = run_in_container(task_arn, cmd)
        ms = parse_time_output(stdout + stderr)
        results["mkdir"].append(ms)
        print(f"  mkdir {i+1}: {ms:.1f}ms")

    print()
    print("--- 2. 写文件测试 ---")
    for i in range(iterations):
        cmd = f'time sh -c "echo hello-{i} > /mnt/efs/pytest-{i}/data.txt" 2>&1'
        stdout, stderr, rc = run_in_container(task_arn, cmd)
        ms = parse_time_output(stdout + stderr)
        results["write"].append(ms)
        print(f"  write {i+1}: {ms:.1f}ms")

    print()
    print("--- 3. 读文件测试 ---")
    for i in range(iterations):
        cmd = f"time cat /mnt/efs/pytest-{i}/data.txt 2>&1"
        stdout, stderr, rc = run_in_container(task_arn, cmd)
        ms = parse_time_output(stdout + stderr)
        results["read"].append(ms)
        print(f"  read {i+1}: {ms:.1f}ms")

    print()
    print("--- 4. 完整用户初始化 ---")
    for i in range(min(3, iterations)):
        cmd = f'time sh -c "mkdir -p /mnt/efs/pytest-init-{i}/.optima && echo token > /mnt/efs/pytest-init-{i}/.optima/token.json && cd /mnt/efs/pytest-init-{i}" 2>&1'
        stdout, stderr, rc = run_in_container(task_arn, cmd)
        ms = parse_time_output(stdout + stderr)
        results["full_init"].append(ms)
        print(f"  init {i+1}: {ms:.1f}ms")

    # 清理
    run_in_container(task_arn, "rm -rf /mnt/efs/pytest-* /mnt/efs/pytest-init-*")

    # 统计
    print()
    print("-" * 50)
    print("Results Summary:")
    print("-" * 50)

    for name, values in results.items():
        if values:
            avg = sum(values) / len(values)
            print(f"  {name:12s}: avg={avg:6.1f}ms  min={min(values):6.1f}ms  max={max(values):6.1f}ms")

    print()
    return results


def main():
    parser = argparse.ArgumentParser(description="EFS 目录操作延迟测试")
    parser.add_argument(
        "--iterations", "-n", type=int, default=5, help="测试迭代次数"
    )

    args = parser.parse_args()

    # 获取 Task
    print("Getting running task...")
    task_arn = get_task_arn()

    if not task_arn:
        print("Error: No running tasks found")
        print(f"Run: aws ecs update-service --cluster {CLUSTER} --service {SERVICE} --desired-count 1")
        sys.exit(1)

    print(f"Found task: ...{task_arn[-12:]}")
    print()

    try:
        test_efs_latency(task_arn, args.iterations)
    except subprocess.TimeoutExpired:
        print("Error: Command timed out")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
