#!/usr/bin/env python3
"""
ECS Task 预热池容量策略模拟器

基于实测数据:
- ECS Task 启动时间（镜像缓存）: ~10 秒
- EC2 从 Hibernated 唤醒: ~15 秒
- EC2 冷启动: ~180 秒

模拟不同预热策略下的用户等待时间，帮助选择最优配置。

使用方法:
    python3 simulate-capacity.py [--verbose]
"""

import random
import heapq
from dataclasses import dataclass, field
from typing import List, Dict, Optional
from collections import defaultdict
import argparse

# ============================================================================
# 配置参数
# ============================================================================

@dataclass
class SimConfig:
    """模拟配置"""
    # 请求模式
    request_rate: float = 5.0          # 每分钟请求数（峰值）
    session_duration: float = 30.0     # 平均会话时长（分钟）

    # EC2 实例配置
    tasks_per_instance: int = 7        # 每个 EC2 可运行的 Task 数 (256MB Task)
    initial_instances: int = 1         # 初始运行 EC2 实例数
    max_instances: int = 50            # 最大 EC2 实例数

    # ECS Task 预热配置
    warm_tasks: int = 2                # 预热的空闲 Task 数
    warm_task_start_time: float = 0.0  # 预热 Task 分配时间（几乎为 0）

    # EC2 扩容时间
    new_task_start_time: float = 10.0  # 新 Task 启动时间（EC2 有容量）
    ec2_warm_start_time: float = 15.0  # EC2 从 Hibernated 启动时间
    ec2_cold_start_time: float = 180.0 # EC2 冷启动时间

    # EC2 Warm Pool 配置
    ec2_warm_pool_size: int = 2        # Hibernated EC2 预热数

    # 扩容策略
    task_utilization_threshold: float = 0.7  # Task 利用率阈值，触发新 Task
    ec2_capacity_threshold: int = 2          # EC2 剩余容量阈值，触发扩容

    # 模拟参数
    simulation_hours: float = 8.0      # 模拟时长（小时）

    # 成本参数（美元/小时）
    instance_cost_running: float = 0.0208  # t3.small 运行成本
    instance_cost_stopped: float = 0.0008  # EBS 存储成本 (Hibernated)
    task_cost: float = 0.0              # Task 额外成本（EC2 上为 0）


# ============================================================================
# 事件驱动模拟器
# ============================================================================

@dataclass(order=True)
class Event:
    """模拟事件"""
    time: float
    event_type: str = field(compare=False)
    data: dict = field(default_factory=dict, compare=False)


class TaskWarmPoolSimulator:
    """ECS Task 预热池模拟器"""

    def __init__(self, config: SimConfig, verbose: bool = False):
        self.config = config
        self.verbose = verbose

        # 状态
        self.current_time = 0.0

        # EC2 实例
        self.running_ec2 = config.initial_instances
        self.ec2_warm_pool = config.ec2_warm_pool_size
        self.pending_ec2: List[float] = []  # EC2 就绪时间列表

        # ECS Task
        self.active_tasks = 0              # 服务用户的 Task
        self.warm_tasks = config.warm_tasks # 空闲预热 Task
        self.pending_tasks: List[float] = [] # 正在启动的 Task 就绪时间

        # 会话
        self.active_sessions = 0

        # 事件队列
        self.events: List[Event] = []

        # 统计
        self.wait_times: List[float] = []
        self.total_requests = 0
        self.requests_instant = 0          # 即时响应（预热 Task）
        self.requests_new_task = 0         # 等待新 Task
        self.requests_new_ec2_warm = 0     # 等待 EC2 Warm Pool
        self.requests_new_ec2_cold = 0     # 等待 EC2 冷启动

        # 容量跟踪
        self.capacity_history: List[tuple] = []

    def log(self, msg: str):
        """调试日志"""
        if self.verbose:
            print(f"[{self.current_time:.1f}s] {msg}")

    def schedule(self, delay: float, event_type: str, data: dict = None):
        """调度事件"""
        heapq.heappush(self.events, Event(
            time=self.current_time + delay,
            event_type=event_type,
            data=data or {}
        ))

    def get_ec2_capacity(self) -> int:
        """获取 EC2 总 Task 容量"""
        return self.running_ec2 * self.config.tasks_per_instance

    def get_used_task_slots(self) -> int:
        """获取已使用的 Task 槽位"""
        return self.active_tasks + self.warm_tasks + len(self.pending_tasks)

    def get_available_task_slots(self) -> int:
        """获取可用于启动新 Task 的槽位"""
        return max(0, self.get_ec2_capacity() - self.get_used_task_slots())

    def handle_request(self) -> float:
        """处理用户请求，返回等待时间"""
        self.total_requests += 1

        # 场景 1: 有预热 Task，即时分配
        if self.warm_tasks > 0:
            self.warm_tasks -= 1
            self.active_tasks += 1
            self.active_sessions += 1
            self.requests_instant += 1

            # 调度会话结束
            duration = random.expovariate(1.0 / (self.config.session_duration * 60))
            self.schedule(duration, 'session_end')

            # 后台补充预热 Task
            self.schedule_warm_task_replenish()

            self.log(f"预热 Task 分配 (剩余预热: {self.warm_tasks})")
            return 0.0

        # 场景 2: 无预热 Task，但 EC2 有容量，启动新 Task
        if self.get_available_task_slots() > 0:
            wait_time = self.config.new_task_start_time
            self.pending_tasks.append(self.current_time + wait_time)
            self.requests_new_task += 1

            self.schedule(wait_time, 'task_ready_for_user')
            self.log(f"启动新 Task (等待 {wait_time}s)")
            return wait_time

        # 场景 3: EC2 无容量，需要扩容
        if self.ec2_warm_pool > 0:
            # 从 Hibernated 启动
            self.ec2_warm_pool -= 1
            ec2_time = self.config.ec2_warm_start_time
            self.requests_new_ec2_warm += 1
            self.log(f"EC2 Warm Pool 启动 (剩余: {self.ec2_warm_pool})")
        else:
            # 冷启动
            ec2_time = self.config.ec2_cold_start_time
            self.requests_new_ec2_cold += 1
            self.log("EC2 冷启动")

        # EC2 就绪后还需要启动 Task
        wait_time = ec2_time + self.config.new_task_start_time
        self.pending_ec2.append(self.current_time + ec2_time)

        self.schedule(ec2_time, 'ec2_ready')
        self.schedule(wait_time, 'task_ready_for_user')

        # 补充 EC2 Warm Pool
        self.schedule(30, 'replenish_ec2_pool')

        return wait_time

    def schedule_warm_task_replenish(self):
        """调度预热 Task 补充"""
        # 检查是否需要补充，以及是否有容量
        needed = self.config.warm_tasks - self.warm_tasks - len([
            t for t in self.pending_tasks
            if t > self.current_time  # 正在启动的 Task
        ])

        available = self.get_available_task_slots()

        to_start = min(needed, available)
        for _ in range(to_start):
            if self.get_available_task_slots() > 0:
                self.schedule(self.config.new_task_start_time, 'warm_task_ready')
                self.pending_tasks.append(self.current_time + self.config.new_task_start_time)
                self.log("后台启动预热 Task")

    def check_proactive_scaling(self):
        """主动扩容检查"""
        # 检查是否需要扩容 EC2
        available_slots = self.get_available_task_slots()

        if available_slots < self.config.ec2_capacity_threshold:
            if self.ec2_warm_pool > 0:
                self.ec2_warm_pool -= 1
                self.schedule(self.config.ec2_warm_start_time, 'ec2_ready')
                self.pending_ec2.append(self.current_time + self.config.ec2_warm_start_time)
                self.schedule(30, 'replenish_ec2_pool')
                self.log(f"主动扩容 EC2 (可用槽位: {available_slots})")

    def run(self) -> Dict:
        """运行模拟"""
        simulation_seconds = self.config.simulation_hours * 3600

        # 初始化：调度第一个请求
        self.schedule_next_request()

        # 调度定期检查
        self.schedule(10, 'periodic_check')

        # 事件循环
        while self.events and self.current_time < simulation_seconds:
            event = heapq.heappop(self.events)
            self.current_time = event.time

            if event.event_type == 'request':
                wait_time = self.handle_request()
                self.wait_times.append(wait_time)
                self.schedule_next_request()

            elif event.event_type == 'session_end':
                self.active_sessions -= 1
                self.active_tasks -= 1
                # 会话结束，Task 变回预热状态
                self.warm_tasks += 1
                self.log(f"会话结束 (活跃: {self.active_sessions}, 预热: {self.warm_tasks})")

            elif event.event_type == 'ec2_ready':
                self.running_ec2 += 1
                self.pending_ec2 = [t for t in self.pending_ec2 if t > self.current_time]
                self.log(f"EC2 就绪 (运行: {self.running_ec2})")

            elif event.event_type == 'task_ready_for_user':
                # Task 就绪，分配给用户
                self.pending_tasks = [t for t in self.pending_tasks if t > self.current_time]
                self.active_tasks += 1
                self.active_sessions += 1
                duration = random.expovariate(1.0 / (self.config.session_duration * 60))
                self.schedule(duration, 'session_end')
                self.log(f"Task 就绪分配 (活跃: {self.active_sessions})")

            elif event.event_type == 'warm_task_ready':
                # 预热 Task 就绪
                self.pending_tasks = [t for t in self.pending_tasks if t > self.current_time]
                self.warm_tasks += 1
                self.log(f"预热 Task 就绪 (预热: {self.warm_tasks})")

            elif event.event_type == 'replenish_ec2_pool':
                # 补充 EC2 Warm Pool
                while self.ec2_warm_pool < self.config.ec2_warm_pool_size:
                    self.ec2_warm_pool += 1
                    self.log(f"补充 EC2 Warm Pool (当前: {self.ec2_warm_pool})")

            elif event.event_type == 'periodic_check':
                self.check_proactive_scaling()
                self.schedule_warm_task_replenish()
                self.schedule(10, 'periodic_check')

            # 记录容量历史
            self.capacity_history.append((
                self.current_time,
                self.running_ec2,
                self.active_tasks,
                self.warm_tasks
            ))

        return self.get_results()

    def schedule_next_request(self):
        """调度下一个请求（泊松分布）"""
        rate_per_second = self.config.request_rate / 60.0
        interval = random.expovariate(rate_per_second)
        self.schedule(interval, 'request')

    def get_results(self) -> Dict:
        """获取模拟结果"""
        if not self.wait_times:
            return {}

        wait_times_sorted = sorted(self.wait_times)
        n = len(wait_times_sorted)

        # 计算成本
        avg_running = sum(h[1] for h in self.capacity_history) / len(self.capacity_history) if self.capacity_history else 1
        running_hours = avg_running * self.config.simulation_hours
        stopped_hours = self.config.ec2_warm_pool_size * self.config.simulation_hours

        monthly_cost = (
            running_hours * self.config.instance_cost_running * 30 +
            stopped_hours * self.config.instance_cost_stopped * 30
        )

        return {
            'total_requests': self.total_requests,
            'requests_instant': self.requests_instant,
            'requests_new_task': self.requests_new_task,
            'requests_new_ec2_warm': self.requests_new_ec2_warm,
            'requests_new_ec2_cold': self.requests_new_ec2_cold,
            'instant_ratio': self.requests_instant / self.total_requests if self.total_requests else 0,
            'avg_wait': sum(self.wait_times) / n,
            'p50_wait': wait_times_sorted[int(n * 0.50)],
            'p95_wait': wait_times_sorted[int(n * 0.95)],
            'p99_wait': wait_times_sorted[int(n * 0.99)],
            'max_wait': max(self.wait_times),
            'avg_instances': avg_running,
            'monthly_cost': monthly_cost,
        }


# ============================================================================
# 策略定义
# ============================================================================

STRATEGIES = {
    'A: 无预热 Task': SimConfig(
        warm_tasks=0,
        ec2_warm_pool_size=2,
    ),
    'B: 2个预热 Task': SimConfig(
        warm_tasks=2,
        ec2_warm_pool_size=2,
    ),
    'C: 3个预热 Task': SimConfig(
        warm_tasks=3,
        ec2_warm_pool_size=2,
    ),
    'D: 4个预热 Task': SimConfig(
        warm_tasks=4,
        ec2_warm_pool_size=2,
    ),
    'E: 5个预热 Task + 3个EC2': SimConfig(
        warm_tasks=5,
        ec2_warm_pool_size=3,
    ),
}


# ============================================================================
# 主程序
# ============================================================================

def run_simulation(strategy_name: str, config: SimConfig, verbose: bool = False) -> Dict:
    """运行单个策略的模拟"""
    num_runs = 5
    results_list = []

    for i in range(num_runs):
        random.seed(42 + i)
        sim = TaskWarmPoolSimulator(config, verbose=(verbose and i == 0))
        results = sim.run()
        results_list.append(results)

    # 平均结果
    avg_results = {}
    for key in results_list[0].keys():
        values = [r[key] for r in results_list]
        avg_results[key] = sum(values) / len(values)

    return avg_results


def format_time(seconds: float) -> str:
    """格式化时间"""
    if seconds < 0.001:
        return "0ms"
    elif seconds < 1:
        return f"{seconds*1000:.0f}ms"
    elif seconds < 60:
        return f"{seconds:.1f}s"
    else:
        return f"{seconds/60:.1f}m"


def print_results(all_results: Dict[str, Dict]):
    """打印结果表格"""
    print()
    print("=" * 100)
    print("                         ECS Task 预热池容量策略模拟结果")
    print("=" * 100)
    print()
    print(f"{'策略':<30} {'即时响应':>10} {'平均等待':>10} {'P95等待':>10} {'最大等待':>10} {'月成本':>10}")
    print("-" * 100)

    for name, results in all_results.items():
        print(f"{name:<30} "
              f"{results['instant_ratio']*100:>9.1f}% "
              f"{format_time(results['avg_wait']):>10} "
              f"{format_time(results['p95_wait']):>10} "
              f"{format_time(results['max_wait']):>10} "
              f"${results['monthly_cost']:>8.0f}")

    print("-" * 100)
    print()

    # 详细统计
    print("详细统计:")
    print("-" * 100)
    for name, results in all_results.items():
        print(f"\n{name}:")
        print(f"  总请求数: {results['total_requests']:.0f}")
        print(f"  即时响应 (预热Task): {results['requests_instant']:.0f} ({results['instant_ratio']*100:.1f}%)")
        print(f"  等待新Task (10s): {results['requests_new_task']:.0f}")
        print(f"  等待EC2 Warm (25s): {results['requests_new_ec2_warm']:.0f}")
        print(f"  等待EC2 Cold (190s): {results['requests_new_ec2_cold']:.0f}")
        print(f"  平均运行EC2: {results['avg_instances']:.1f}")


def print_recommendations(all_results: Dict[str, Dict]):
    """打印建议"""
    print()
    print("=" * 100)
    print("                                    建议")
    print("=" * 100)
    print()

    # 找出最佳策略
    best_instant = max(all_results.items(), key=lambda x: x[1]['instant_ratio'])
    best_wait = min(all_results.items(), key=lambda x: x[1]['avg_wait'])
    best_cost = min(all_results.items(), key=lambda x: x[1]['monthly_cost'])

    print(f"最高即时响应率: {best_instant[0]} ({best_instant[1]['instant_ratio']*100:.1f}%)")
    print(f"最低平均等待: {best_wait[0]} ({format_time(best_wait[1]['avg_wait'])})")
    print(f"最低成本: {best_cost[0]} (${best_cost[1]['monthly_cost']:.0f}/月)")
    print()

    # 推荐策略
    # 找到即时响应率 > 95% 且成本最低的
    good_strategies = [(n, r) for n, r in all_results.items() if r['instant_ratio'] > 0.95]
    if good_strategies:
        recommended = min(good_strategies, key=lambda x: x[1]['monthly_cost'])
        print(f"推荐策略 (>95%即时响应 + 最低成本): {recommended[0]}")
        print(f"  - 即时响应率: {recommended[1]['instant_ratio']*100:.1f}%")
        print(f"  - 平均等待: {format_time(recommended[1]['avg_wait'])}")
        print(f"  - 月成本: ${recommended[1]['monthly_cost']:.0f}")
    print()

    # 前端提示建议
    print("前端提示策略:")
    print("-" * 50)
    print("  - 即时响应 (预热Task): 无提示，直接连接")
    print("  - 等待新Task (~10s): 显示 \"环境准备中...\"")
    print("  - 等待EC2扩容 (~25s): 显示 \"正在启动资源，预计20秒...\"")
    print("  - 冷启动 (~3min): 显示 \"首次启动较慢，预计3分钟...\"")
    print()


def main():
    parser = argparse.ArgumentParser(description='ECS Task 预热池容量策略模拟器')
    parser.add_argument('--verbose', '-v', action='store_true', help='显示详细日志')
    parser.add_argument('--strategy', '-s', help='只运行指定策略')
    args = parser.parse_args()

    print()
    print("ECS Task 预热池容量策略模拟器")
    print("=" * 50)
    print()
    print("基于实测数据:")
    print(f"  - ECS Task 启动时间（镜像缓存）: ~10 秒")
    print(f"  - EC2 从 Hibernated 唤醒: ~15 秒")
    print(f"  - EC2 冷启动: ~180 秒")
    print()
    print("模拟参数:")
    print(f"  - 请求率: 5 个/分钟（泊松分布）")
    print(f"  - 会话时长: 30 分钟（指数分布）")
    print(f"  - 每 EC2 容量: 7 个 Task (256MB)")
    print(f"  - 模拟时长: 8 小时")
    print()
    print("运行模拟中...")

    all_results = {}

    for name, config in STRATEGIES.items():
        if args.strategy and args.strategy not in name:
            continue
        print(f"  {name}...", end='', flush=True)
        results = run_simulation(name, config, args.verbose)
        all_results[name] = results
        print(" 完成")

    print_results(all_results)
    print_recommendations(all_results)


if __name__ == '__main__':
    main()
