#!/usr/bin/env python3
"""
多用户并发模拟器

使用泊松分布模拟真实用户请求到达，评估不同容量策略下的用户等待时间。

策略:
1. 保守策略 - 70% 利用率触发扩容，2 个 Warm Pool 实例
2. 激进策略 - 50% 利用率触发扩容，3 个 Warm Pool 实例
3. 混合策略 - 1 个 Running + 2 个 Stopped Warm Pool

使用方法:
    python3 simulate-multi-user.py
    python3 simulate-multi-user.py --duration 8 --rate 3
    python3 simulate-multi-user.py --strategy conservative
    python3 simulate-multi-user.py --compare  # 比较所有策略
"""

import argparse
import json
import random
from dataclasses import dataclass, field
from typing import List, Dict, Optional
from datetime import datetime
import heapq

# 尝试导入 numpy，如果没有则使用标准库
try:
    import numpy as np
    HAS_NUMPY = True
except ImportError:
    HAS_NUMPY = False
    import math


def exponential_random(rate: float) -> float:
    """生成指数分布随机数"""
    if HAS_NUMPY:
        return np.random.exponential(1.0 / rate)
    else:
        return random.expovariate(rate)


def poisson_random(lam: float) -> int:
    """生成泊松分布随机数"""
    if HAS_NUMPY:
        return np.random.poisson(lam)
    else:
        L = math.exp(-lam)
        k = 0
        p = 1.0
        while p > L:
            k += 1
            p *= random.random()
        return k - 1


@dataclass
class SimConfig:
    """模拟配置"""
    # 时间参数（秒）
    warm_task_assign_time: float = 0.26      # 预热 Task 分配时间 (实测 260ms)
    task_startup_time: float = 3.0           # Task 启动时间 (预估 3s)
    ec2_warm_start_time: float = 22.0        # EC2 Warm Pool 启动时间 (实测 22s)
    ec2_cold_start_time: float = 180.0       # EC2 冷启动时间 (预估 3min)

    # 容量参数
    tasks_per_ec2: int = 4                   # 每个 EC2 可运行的 Task 数
    warm_task_pool_size: int = 3             # 预热 Task 池大小
    ec2_warm_pool_size: int = 2              # EC2 Warm Pool 大小
    initial_ec2_count: int = 1               # 初始 EC2 数量

    # 扩容策略
    scale_up_threshold: float = 0.7          # 扩容触发阈值 (70%)
    scale_down_threshold: float = 0.3        # 缩容触发阈值 (30%)

    # 用户行为
    session_duration_mean: float = 30 * 60   # 会话平均时长 (30min)
    session_duration_std: float = 10 * 60    # 会话时长标准差 (10min)

    # 模拟参数
    request_rate: float = 3.0                # 请求到达率 (每分钟)
    duration_hours: float = 8.0              # 模拟时长 (小时)


@dataclass
class Event:
    """事件"""
    time: float
    event_type: str  # 'user_arrive', 'user_leave', 'task_ready', 'ec2_ready'
    data: dict = field(default_factory=dict)

    def __lt__(self, other):
        return self.time < other.time


class WarmPoolSimulator:
    """预热池模拟器"""

    def __init__(self, config: SimConfig):
        self.config = config
        self.reset()

    def reset(self):
        """重置模拟状态"""
        self.current_time = 0.0

        # 资源状态
        self.running_ec2 = self.config.initial_ec2_count
        self.ec2_warm_pool = self.config.ec2_warm_pool_size
        self.warm_tasks = self.config.warm_task_pool_size
        self.active_sessions = 0

        # 待处理事件
        self.pending_tasks = 0      # 正在启动的 Task
        self.pending_ec2 = 0        # 正在启动的 EC2

        # 事件队列
        self.event_queue: List[Event] = []

        # 结果收集
        self.results: List[Dict] = []
        self.wait_times: List[float] = []

    def total_capacity(self) -> int:
        """当前总容量"""
        return self.running_ec2 * self.config.tasks_per_ec2

    def available_capacity(self) -> int:
        """当前可用容量"""
        return self.total_capacity() - self.active_sessions

    def utilization(self) -> float:
        """当前利用率"""
        total = self.total_capacity()
        if total == 0:
            return 1.0
        return self.active_sessions / total

    def schedule_event(self, delay: float, event_type: str, data: dict = None):
        """调度事件"""
        event = Event(
            time=self.current_time + delay,
            event_type=event_type,
            data=data or {}
        )
        heapq.heappush(self.event_queue, event)

    def handle_user_arrive(self, user_id: int) -> float:
        """处理用户到达，返回等待时间"""
        wait_time = 0.0

        # 1. 有预热 Task，直接分配
        if self.warm_tasks > 0:
            self.warm_tasks -= 1
            self.active_sessions += 1
            wait_time = self.config.warm_task_assign_time

            # 后台补充预热 Task
            self.refill_warm_tasks()

        # 2. EC2 有空闲容量，启动新 Task
        elif self.available_capacity() > self.pending_tasks:
            self.pending_tasks += 1
            wait_time = self.config.task_startup_time

            # 调度 Task 就绪事件
            self.schedule_event(
                delay=self.config.task_startup_time,
                event_type='task_ready',
                data={'user_id': user_id}
            )

        # 3. EC2 Warm Pool 有实例，启动
        elif self.ec2_warm_pool > 0:
            self.ec2_warm_pool -= 1
            self.pending_ec2 += 1
            wait_time = self.config.ec2_warm_start_time

            # 调度 EC2 就绪事件
            self.schedule_event(
                delay=self.config.ec2_warm_start_time,
                event_type='ec2_ready',
                data={'user_id': user_id, 'from_warm_pool': True}
            )

        # 4. 冷启动 EC2
        else:
            self.pending_ec2 += 1
            wait_time = self.config.ec2_cold_start_time

            # 调度 EC2 就绪事件
            self.schedule_event(
                delay=self.config.ec2_cold_start_time,
                event_type='ec2_ready',
                data={'user_id': user_id, 'from_warm_pool': False}
            )

        # 调度用户离开事件
        session_duration = max(60, random.gauss(
            self.config.session_duration_mean,
            self.config.session_duration_std
        ))
        self.schedule_event(
            delay=wait_time + session_duration,
            event_type='user_leave',
            data={'user_id': user_id}
        )

        # 记录结果
        self.wait_times.append(wait_time)
        self.results.append({
            'time': self.current_time,
            'user_id': user_id,
            'wait_time': wait_time,
            'active_sessions': self.active_sessions,
            'warm_tasks': self.warm_tasks,
            'running_ec2': self.running_ec2,
            'ec2_warm_pool': self.ec2_warm_pool,
            'utilization': self.utilization(),
        })

        return wait_time

    def handle_user_leave(self, user_id: int):
        """处理用户离开"""
        if self.active_sessions > 0:
            self.active_sessions -= 1

    def handle_task_ready(self, user_id: int):
        """处理 Task 就绪"""
        self.pending_tasks -= 1
        self.active_sessions += 1

    def handle_ec2_ready(self, user_id: int, from_warm_pool: bool):
        """处理 EC2 就绪"""
        self.pending_ec2 -= 1
        self.running_ec2 += 1
        self.active_sessions += 1

        # EC2 就绪后，补充预热 Task
        self.refill_warm_tasks()

    def refill_warm_tasks(self):
        """补充预热 Task 池"""
        # 计算可用容量
        total_capacity = self.running_ec2 * self.config.tasks_per_ec2
        used = self.active_sessions + self.pending_tasks + self.warm_tasks

        # 补充到目标大小
        to_add = min(
            self.config.warm_task_pool_size - self.warm_tasks,
            total_capacity - used
        )

        if to_add > 0:
            # 简化：假设预热 Task 立即可用（实际需要几秒启动）
            self.warm_tasks += to_add

    def check_proactive_scaling(self):
        """主动扩容检查"""
        utilization = self.utilization()

        if utilization > self.config.scale_up_threshold:
            # 需要扩容
            if self.ec2_warm_pool > 0 and self.pending_ec2 == 0:
                # 从 Warm Pool 启动一个实例
                self.ec2_warm_pool -= 1
                self.pending_ec2 += 1
                self.schedule_event(
                    delay=self.config.ec2_warm_start_time,
                    event_type='ec2_ready',
                    data={'user_id': -1, 'from_warm_pool': True}
                )

    def run(self) -> Dict:
        """运行模拟"""
        self.reset()

        end_time = self.config.duration_hours * 3600
        user_id = 0

        # 生成用户到达事件（泊松过程）
        rate_per_second = self.config.request_rate / 60

        arrival_time = 0
        while arrival_time < end_time:
            interval = exponential_random(rate_per_second)
            arrival_time += interval

            if arrival_time < end_time:
                self.schedule_event(
                    delay=arrival_time - self.current_time if self.current_time == 0 else arrival_time,
                    event_type='user_arrive',
                    data={'user_id': user_id}
                )
                user_id += 1

        # 重新初始化事件队列时间
        self.current_time = 0
        new_queue = []
        for event in self.event_queue:
            heapq.heappush(new_queue, event)
        self.event_queue = new_queue

        # 处理事件
        while self.event_queue:
            event = heapq.heappop(self.event_queue)
            self.current_time = event.time

            if event.event_type == 'user_arrive':
                self.handle_user_arrive(event.data['user_id'])
                self.check_proactive_scaling()

            elif event.event_type == 'user_leave':
                self.handle_user_leave(event.data['user_id'])

            elif event.event_type == 'task_ready':
                self.handle_task_ready(event.data['user_id'])

            elif event.event_type == 'ec2_ready':
                self.handle_ec2_ready(
                    event.data['user_id'],
                    event.data.get('from_warm_pool', False)
                )

        return self.analyze_results()

    def analyze_results(self) -> Dict:
        """分析模拟结果"""
        if not self.wait_times:
            return {}

        wait_times = sorted(self.wait_times)
        n = len(wait_times)

        # 计算统计数据
        stats = {
            'total_requests': n,
            'avg_wait': sum(wait_times) / n,
            'min_wait': min(wait_times),
            'max_wait': max(wait_times),
            'p50_wait': wait_times[int(n * 0.5)],
            'p95_wait': wait_times[min(int(n * 0.95), n - 1)],
            'p99_wait': wait_times[min(int(n * 0.99), n - 1)],
        }

        # 计算等待比例
        stats['wait_gt_1s'] = sum(1 for w in wait_times if w > 1) / n * 100
        stats['wait_gt_5s'] = sum(1 for w in wait_times if w > 5) / n * 100
        stats['wait_gt_20s'] = sum(1 for w in wait_times if w > 20) / n * 100

        return stats


def get_strategy_config(strategy: str) -> SimConfig:
    """获取策略配置"""
    config = SimConfig()

    if strategy == 'conservative':
        # 保守策略: 70% 触发扩容，2 个 Warm Pool
        config.scale_up_threshold = 0.7
        config.ec2_warm_pool_size = 2
        config.warm_task_pool_size = 3

    elif strategy == 'aggressive':
        # 激进策略: 50% 触发扩容，3 个 Warm Pool
        config.scale_up_threshold = 0.5
        config.ec2_warm_pool_size = 3
        config.warm_task_pool_size = 5

    elif strategy == 'hybrid':
        # 混合策略: 1 Running + 2 Stopped，更多预热 Task
        config.scale_up_threshold = 0.6
        config.initial_ec2_count = 1
        config.ec2_warm_pool_size = 2
        config.warm_task_pool_size = 4

    elif strategy == 'minimal':
        # 最小策略: 最低成本
        config.scale_up_threshold = 0.8
        config.ec2_warm_pool_size = 1
        config.warm_task_pool_size = 2

    return config


def estimate_monthly_cost(config: SimConfig) -> float:
    """估算月度成本（美元）"""
    # t3.small: ~$0.02/hour
    ec2_hourly = 0.02

    # 假设每天 12 小时运行
    hours_per_month = 12 * 30

    # Running EC2 成本
    running_cost = config.initial_ec2_count * ec2_hourly * hours_per_month

    # Warm Pool (Stopped) 成本：仅 EBS 存储，约 $0.003/hour
    warm_pool_cost = config.ec2_warm_pool_size * 0.003 * hours_per_month

    return running_cost + warm_pool_cost


def print_results(strategy: str, stats: Dict, config: SimConfig):
    """打印结果"""
    cost = estimate_monthly_cost(config)

    print(f"\n策略: {strategy}")
    print("-" * 50)
    print(f"配置:")
    print(f"  初始 EC2: {config.initial_ec2_count}")
    print(f"  EC2 Warm Pool: {config.ec2_warm_pool_size}")
    print(f"  预热 Task 池: {config.warm_task_pool_size}")
    print(f"  扩容阈值: {config.scale_up_threshold*100:.0f}%")
    print()
    print(f"结果:")
    print(f"  总请求数: {stats['total_requests']}")
    print(f"  平均等待: {stats['avg_wait']:.2f}s")
    print(f"  P50 等待: {stats['p50_wait']:.2f}s")
    print(f"  P95 等待: {stats['p95_wait']:.2f}s")
    print(f"  P99 等待: {stats['p99_wait']:.2f}s")
    print(f"  最大等待: {stats['max_wait']:.2f}s")
    print()
    print(f"  等待>1s:  {stats['wait_gt_1s']:.1f}%")
    print(f"  等待>5s:  {stats['wait_gt_5s']:.1f}%")
    print(f"  等待>20s: {stats['wait_gt_20s']:.1f}%")
    print()
    print(f"  预估月成本: ${cost:.0f}")


def compare_strategies(duration: float, rate: float):
    """比较所有策略"""
    strategies = ['conservative', 'aggressive', 'hybrid', 'minimal']

    print("=" * 70)
    print("     多用户并发模拟 - 策略比较")
    print("=" * 70)
    print()
    print(f"模拟参数:")
    print(f"  时长: {duration} 小时")
    print(f"  请求率: {rate} 个/分钟")
    print(f"  会话时长: 30 分钟 (平均)")
    print()

    all_results = {}

    for strategy in strategies:
        config = get_strategy_config(strategy)
        config.duration_hours = duration
        config.request_rate = rate

        sim = WarmPoolSimulator(config)
        stats = sim.run()
        all_results[strategy] = (stats, config)

        print_results(strategy, stats, config)

    # 打印比较表格
    print()
    print("=" * 70)
    print("策略对比表")
    print("=" * 70)
    print()
    print(f"{'策略':<15} {'平均等待':<10} {'P95':<10} {'P99':<10} {'等待>1s':<10} {'月成本':<10}")
    print("-" * 70)

    for strategy in strategies:
        stats, config = all_results[strategy]
        cost = estimate_monthly_cost(config)
        print(f"{strategy:<15} {stats['avg_wait']:<10.2f} {stats['p95_wait']:<10.2f} {stats['p99_wait']:<10.2f} {stats['wait_gt_1s']:<10.1f}% ${cost:<9.0f}")

    print()
    print("=" * 70)
    print()

    # 推荐策略
    best = min(strategies, key=lambda s: all_results[s][0]['avg_wait'])
    cheapest = min(strategies, key=lambda s: estimate_monthly_cost(all_results[s][1]))

    print(f"建议:")
    print(f"  - 最低延迟: {best}")
    print(f"  - 最低成本: {cheapest}")
    print()

    # 前端提示建议
    p95 = all_results['hybrid'][0]['p95_wait']
    print(f"前端提示建议:")
    print(f"  - 当预估等待时间 > 2s 时显示提示")
    print(f"  - 使用 hybrid 策略时，约 {all_results['hybrid'][0]['wait_gt_1s']:.0f}% 用户需要等待")


def main():
    parser = argparse.ArgumentParser(description="多用户并发模拟器")
    parser.add_argument(
        "--strategy", "-s",
        choices=['conservative', 'aggressive', 'hybrid', 'minimal'],
        default='hybrid',
        help="容量策略 (默认: hybrid)"
    )
    parser.add_argument(
        "--duration", "-d",
        type=float,
        default=8.0,
        help="模拟时长（小时）(默认: 8)"
    )
    parser.add_argument(
        "--rate", "-r",
        type=float,
        default=3.0,
        help="请求到达率（每分钟）(默认: 3)"
    )
    parser.add_argument(
        "--compare", "-c",
        action="store_true",
        help="比较所有策略"
    )
    parser.add_argument(
        "--output", "-o",
        type=str,
        help="输出 JSON 文件路径"
    )

    args = parser.parse_args()

    if args.compare:
        compare_strategies(args.duration, args.rate)
    else:
        config = get_strategy_config(args.strategy)
        config.duration_hours = args.duration
        config.request_rate = args.rate

        print("=" * 60)
        print("     多用户并发模拟")
        print("=" * 60)
        print()
        print(f"策略: {args.strategy}")
        print(f"时长: {args.duration} 小时")
        print(f"请求率: {args.rate} 个/分钟")
        print()

        sim = WarmPoolSimulator(config)
        stats = sim.run()

        print_results(args.strategy, stats, config)

        if args.output:
            with open(args.output, 'w') as f:
                json.dump({
                    'strategy': args.strategy,
                    'config': {
                        'duration_hours': args.duration,
                        'request_rate': args.rate,
                        'initial_ec2': config.initial_ec2_count,
                        'ec2_warm_pool': config.ec2_warm_pool_size,
                        'warm_task_pool': config.warm_task_pool_size,
                        'scale_up_threshold': config.scale_up_threshold,
                    },
                    'stats': stats,
                    'monthly_cost': estimate_monthly_cost(config),
                }, f, indent=2)
            print(f"\n结果已保存到: {args.output}")


if __name__ == "__main__":
    main()
