#!/usr/bin/env python3
"""
AI Shell 日报脚本

从 CloudWatch Logs Insights 查询 session-gateway 日志，生成每日统计报告。

依赖: boto3
用法:
  python3 daily_report.py                    # 今天的报告 (prod)
  python3 daily_report.py --date 2026-02-08  # 指定日期
  python3 daily_report.py --env stage        # Stage 环境
  python3 daily_report.py --range 7d         # 最近 7 天
  python3 daily_report.py --format json      # JSON 输出
  python3 daily_report.py --compare 2026-02-07  # 与指定日期对比
"""

import argparse
import json
import sys
import time
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3

# 日志组映射（session-gateway 有独立的日志组）
LOG_GROUPS = {
    "stage": "/ecs/session-gateway-stage",
    "prod": "/ecs/session-gateway-prod",
}

REGION = "ap-southeast-1"

# CloudWatch Logs Insights 查询模板
QUERIES = {
    "session_count": """
fields @timestamp
| filter event = "task_lifecycle" and phase = "session_create"
| stats count() as total
""",

    "task_startup": """
fields @timestamp
| filter event = "task_lifecycle" and phase = "task_ready"
| stats count() as total,
        avg(duration_ms) as avg_ms,
        pct(duration_ms, 50) as p50,
        pct(duration_ms, 90) as p90,
        pct(duration_ms, 99) as p99,
        max(duration_ms) as max_ms
""",

    "task_phases": """
fields @timestamp, phase, duration_ms
| filter event = "task_lifecycle" and phase in ["task_start", "task_pending", "task_connect"]
| stats avg(duration_ms) as avg_ms,
        pct(duration_ms, 90) as p90
  by phase
""",

    "restart_stats": """
fields @timestamp, success, duration_ms
| filter event = "task_lifecycle" and phase = "restart" and ispresent(success)
| stats count() as total,
        avg(duration_ms) as avg_restart_ms
  by success
""",

    "errors": """
fields @timestamp, message, level
| filter level = "error"
| stats count() as total by message
| sort total desc
| limit 20
""",

    "ws_disconnects": """
fields @timestamp
| filter event = "task_lifecycle" and phase = "ws_disconnect"
| stats count() as total by processingState
""",

    "message_roundtrip": """
fields @timestamp
| filter event = "task_lifecycle" and phase = "message_roundtrip"
| stats count() as total,
        avg(duration_ms) as avg_ms,
        pct(duration_ms, 50) as p50,
        pct(duration_ms, 90) as p90,
        max(duration_ms) as max_ms
""",

    "slow_startups": """
fields @timestamp, duration_ms, sessionId, userId
| filter event = "task_lifecycle" and phase = "task_ready" and duration_ms > 10000
| sort duration_ms desc
| limit 10
""",

    "idle_timeouts": """
fields @timestamp
| filter event = "task_lifecycle" and phase = "idle_timeout"
| stats count() as total
""",

    "unique_users": """
fields @timestamp
| filter userId != "" and event = "task_lifecycle" and phase = "session_create"
| stats count() as sessions by userId
| stats count() as unique_users, sum(sessions) as total_sessions
""",

    "user_sessions": """
fields @timestamp, userId, userEmail, sessionId
| filter event = "task_lifecycle" and phase = "session_create"
| sort @timestamp desc
| limit 50
""",
}


def run_query(client: Any, log_group: str, query: str, start: int, end: int) -> list[dict]:
    """执行 CloudWatch Logs Insights 查询并返回结果"""
    response = client.start_query(
        logGroupName=log_group,
        startTime=start,
        endTime=end,
        queryString=query.strip(),
    )
    query_id = response["queryId"]

    # 轮询等待结果
    for _ in range(60):
        result = client.get_query_results(queryId=query_id)
        if result["status"] == "Complete":
            # 转换结果格式
            rows = []
            for row in result.get("results", []):
                entry = {}
                for field in row:
                    if field["field"] != "@ptr":
                        entry[field["field"]] = field["value"]
                rows.append(entry)
            return rows
        if result["status"] == "Failed":
            return []
        time.sleep(1)

    return []


def format_ms(value: str | float | None) -> str:
    """格式化毫秒"""
    if value is None:
        return "N/A"
    try:
        ms = float(value)
        if ms >= 1000:
            return f"{ms / 1000:.1f}s"
        return f"{ms:.0f}ms"
    except (ValueError, TypeError):
        return str(value)


def generate_report(
    env: str,
    start_time: datetime,
    end_time: datetime,
    compare_data: dict | None = None,
) -> dict:
    """生成报告数据"""
    client = boto3.client("logs", region_name=REGION)
    log_group = LOG_GROUPS[env]

    start_ts = int(start_time.timestamp())
    end_ts = int(end_time.timestamp())

    data: dict[str, Any] = {"env": env, "start": start_time.isoformat(), "end": end_time.isoformat()}

    print(f"查询日志组: {log_group}", file=sys.stderr)
    print(f"时间范围: {start_time.strftime('%Y-%m-%d %H:%M')} ~ {end_time.strftime('%Y-%m-%d %H:%M')}", file=sys.stderr)

    for name, query in QUERIES.items():
        print(f"  查询: {name}...", file=sys.stderr, end=" ")
        rows = run_query(client, log_group, query, start_ts, end_ts)
        data[name] = rows
        print(f"({len(rows)} 行)", file=sys.stderr)

    data["compare"] = compare_data
    return data


def format_report_md(data: dict) -> str:
    """格式化为 Markdown 报告"""
    lines: list[str] = []
    env = data["env"].upper()

    lines.append(f"# AI Shell 日报 ({data['start'][:10]}) [{env}]")
    lines.append("")

    # 会话统计
    lines.append("## 会话统计")
    session_rows = data.get("session_count", [])
    session_count = int(session_rows[0].get("total", 0)) if session_rows else 0
    user_rows = data.get("unique_users", [])
    unique_users = int(user_rows[0].get("unique_users", 0)) if user_rows else 0
    restart_rows = data.get("restart_stats", [])
    restart_total = 0
    restart_success = 0
    restart_failure = 0
    for row in restart_rows:
        count = int(row.get("total", 0))
        restart_total += count
        if row.get("success") == "1":
            restart_success = count
        else:
            restart_failure = count
    idle_rows = data.get("idle_timeouts", [])
    idle_count = int(idle_rows[0].get("total", 0)) if idle_rows else 0

    lines.append(f"- 新建会话: **{session_count}**")
    lines.append(f"- 活跃用户: **{unique_users}**")
    lines.append(f"- Task 重启: **{restart_total}** (成功 {restart_success}, 失败 {restart_failure})")
    lines.append(f"- 空闲超时: **{idle_count}**")
    lines.append("")

    # 用户会话明细
    user_session_rows = data.get("user_sessions", [])
    if user_session_rows:
        lines.append("### 会话明细")
        lines.append("| 时间 | 用户 | 会话 ID |")
        lines.append("|------|------|---------|")
        for row in user_session_rows:
            ts = row.get("@timestamp", "")[:19]
            email = row.get("userEmail", row.get("userId", "N/A"))
            sid = row.get("sessionId", "N/A")[:12]
            lines.append(f"| {ts} | {email} | {sid}... |")
        lines.append("")

    # 启动耗时
    lines.append("## 启动耗时")
    startup_rows = data.get("task_startup", [])
    if startup_rows:
        row = startup_rows[0]
        total = int(row.get("total", 0))
        lines.append(f"- 样本数: {total}")
        lines.append(f"- P50: **{format_ms(row.get('p50'))}** | P90: **{format_ms(row.get('p90'))}** | P99: **{format_ms(row.get('p99'))}**")
        lines.append(f"- 平均: {format_ms(row.get('avg_ms'))} | 最大: {format_ms(row.get('max_ms'))}")
    else:
        lines.append("- 无数据")
    lines.append("")

    # 各阶段耗时
    lines.append("### 各阶段耗时")
    phase_rows = data.get("task_phases", [])
    if phase_rows:
        lines.append("| 阶段 | 平均 | P90 |")
        lines.append("|------|------|-----|")
        phase_labels = {"task_start": "RunTask API", "task_pending": "PENDING→RUNNING", "task_connect": "RUNNING→WS连接"}
        for row in phase_rows:
            phase = row.get("phase", "")
            label = phase_labels.get(phase, phase)
            lines.append(f"| {label} | {format_ms(row.get('avg_ms'))} | {format_ms(row.get('p90'))} |")
    else:
        lines.append("- 无数据")
    lines.append("")

    # 慢启动
    lines.append("## 慢启动 (>10s)")
    slow_rows = data.get("slow_startups", [])
    if slow_rows:
        lines.append(f"共 **{len(slow_rows)}** 次")
        for row in slow_rows:
            lines.append(f"- {format_ms(row.get('duration_ms'))} (user: {row.get('userId', 'N/A')[:8]}..., session: {row.get('sessionId', 'N/A')[:8]}...)")
    else:
        lines.append("- 无慢启动")
    lines.append("")

    # 消息响应
    lines.append("## 消息响应 (首字延迟)")
    rt_rows = data.get("message_roundtrip", [])
    if rt_rows:
        row = rt_rows[0]
        lines.append(f"- 消息数: {int(row.get('total', 0))}")
        lines.append(f"- P50: **{format_ms(row.get('p50'))}** | P90: **{format_ms(row.get('p90'))}** | 最大: {format_ms(row.get('max_ms'))}")
    else:
        lines.append("- 无数据")
    lines.append("")

    # 错误统计
    lines.append("## 错误统计")
    error_rows = data.get("errors", [])
    if error_rows:
        lines.append("| 错误消息 | 次数 |")
        lines.append("|----------|------|")
        for row in error_rows:
            msg = row.get("message", "Unknown")[:60]
            count = int(row.get("total", 0))
            lines.append(f"| {msg} | {count} |")
    else:
        lines.append("- 无错误")
    lines.append("")

    # WebSocket 断开
    lines.append("## WebSocket 断开")
    ws_rows = data.get("ws_disconnects", [])
    if ws_rows:
        for row in ws_rows:
            state = row.get("processingState", "unknown")
            count = int(row.get("total", 0))
            emoji = "!" if state == "processing" else ""
            lines.append(f"- {state}: **{count}** {emoji}")
    else:
        lines.append("- 无数据")
    lines.append("")

    # 对比数据
    compare = data.get("compare")
    if compare:
        lines.append("## 与前一天对比")
        prev_sessions = int(compare.get("session_count", [{}])[0].get("total", 0)) if compare.get("session_count") else 0
        if session_count > 0 and prev_sessions > 0:
            change = ((session_count - prev_sessions) / prev_sessions) * 100
            lines.append(f"- 会话数: {prev_sessions} → {session_count} ({change:+.0f}%)")
        prev_startup = compare.get("task_startup", [{}])
        if prev_startup and startup_rows:
            prev_p90 = prev_startup[0].get("p90")
            curr_p90 = startup_rows[0].get("p90")
            if prev_p90 and curr_p90:
                lines.append(f"- 启动 P90: {format_ms(prev_p90)} → {format_ms(curr_p90)}")
        lines.append("")

    # 异常高亮
    alerts: list[str] = []
    if startup_rows:
        p99 = float(startup_rows[0].get("p99", 0))
        if p99 > 15000:
            alerts.append(f"P99 启动耗时 {format_ms(p99)} > 15s 阈值")
    if restart_failure > 0:
        alerts.append(f"Task 重启失败 {restart_failure} 次")
    ws_processing = 0
    for row in ws_rows:
        if row.get("processingState") == "processing":
            ws_processing = int(row.get("total", 0))
    if ws_processing > 10:
        alerts.append(f"处理中断开 {ws_processing} 次 (可能丢失 AI 回复)")

    if alerts:
        lines.append("## !! 异常告警")
        for alert in alerts:
            lines.append(f"- {alert}")
        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="AI Shell 日报")
    parser.add_argument("--env", choices=["stage", "prod"], default="prod", help="环境 (默认 prod)")
    parser.add_argument("--date", type=str, help="指定日期 (YYYY-MM-DD)")
    parser.add_argument("--range", type=str, help="时间范围 (如 7d, 24h)")
    parser.add_argument("--format", choices=["md", "json"], default="md", help="输出格式")
    parser.add_argument("--compare", type=str, help="对比日期 (YYYY-MM-DD)")
    args = parser.parse_args()

    now = datetime.now(timezone.utc)

    # 计算时间范围
    if args.range:
        unit = args.range[-1]
        value = int(args.range[:-1])
        if unit == "d":
            start_time = now - timedelta(days=value)
        elif unit == "h":
            start_time = now - timedelta(hours=value)
        else:
            print(f"不支持的时间单位: {unit}", file=sys.stderr)
            sys.exit(1)
        end_time = now
    elif args.date:
        date = datetime.strptime(args.date, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        start_time = date
        end_time = date + timedelta(days=1)
    else:
        # 默认今天
        start_time = now.replace(hour=0, minute=0, second=0, microsecond=0)
        end_time = now

    # 对比数据
    compare_data = None
    if args.compare:
        compare_date = datetime.strptime(args.compare, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        print(f"\n查询对比数据 ({args.compare})...", file=sys.stderr)
        compare_data = generate_report(args.env, compare_date, compare_date + timedelta(days=1))

    # 生成报告
    data = generate_report(args.env, start_time, end_time, compare_data)

    if args.format == "json":
        print(json.dumps(data, indent=2, default=str))
    else:
        print(format_report_md(data))


if __name__ == "__main__":
    main()
