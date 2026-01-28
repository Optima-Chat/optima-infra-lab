/**
 * Warm Pool Manager
 *
 * 管理预热任务的连接和分配
 */

import type { WebSocket } from 'ws';

export interface WarmTask {
  taskId: string;
  ws: WebSocket;
  state: 'warm' | 'assigned';
  userId?: string;
  sessionId?: string;
  connectedAt: Date;
  assignedAt?: Date;
  lastHeartbeat: Date;
}

export class WarmPoolManager {
  private tasks: Map<string, WarmTask> = new Map();

  /**
   * 注册预热任务（任务连接时调用）
   */
  registerWarmTask(taskId: string, ws: WebSocket): void {
    const task: WarmTask = {
      taskId,
      ws,
      state: 'warm',
      connectedAt: new Date(),
      lastHeartbeat: new Date(),
    };

    this.tasks.set(taskId, task);
    console.log(`[WarmPool] Task registered: ${taskId}`);
    console.log(`[WarmPool] Pool size: ${this.getWarmCount()} warm, ${this.getAssignedCount()} assigned`);

    // 监听关闭事件
    ws.on('close', () => {
      this.tasks.delete(taskId);
      console.log(`[WarmPool] Task disconnected: ${taskId}`);
    });
  }

  /**
   * 分配预热任务给用户
   */
  async acquireWarmTask(userId: string, sessionId?: string): Promise<WarmTask | null> {
    // 找一个 warm 状态的任务
    for (const [taskId, task] of this.tasks) {
      if (task.state === 'warm') {
        // 标记为 assigned
        task.state = 'assigned';
        task.userId = userId;
        task.sessionId = sessionId;
        task.assignedAt = new Date();

        console.log(`[WarmPool] Task ${taskId} assigned to user ${userId}`);

        // 发送初始化消息
        task.ws.send(JSON.stringify({
          type: 'init_user_session',
          userId,
          sessionId,
          env: 'test',
        }));

        return task;
      }
    }

    console.log('[WarmPool] No warm tasks available');
    return null;
  }

  /**
   * 释放任务（用户断开时）
   */
  releaseTask(taskId: string): void {
    const task = this.tasks.get(taskId);
    if (task) {
      // 直接关闭连接，让 ECS Service 重新创建
      task.ws.close();
      this.tasks.delete(taskId);
      console.log(`[WarmPool] Task ${taskId} released`);
    }
  }

  /**
   * 更新心跳
   */
  updateHeartbeat(taskId: string): void {
    const task = this.tasks.get(taskId);
    if (task) {
      task.lastHeartbeat = new Date();
    }
  }

  /**
   * 获取 warm 状态的任务数量
   */
  getWarmCount(): number {
    let count = 0;
    for (const task of this.tasks.values()) {
      if (task.state === 'warm') count++;
    }
    return count;
  }

  /**
   * 获取 assigned 状态的任务数量
   */
  getAssignedCount(): number {
    let count = 0;
    for (const task of this.tasks.values()) {
      if (task.state === 'assigned') count++;
    }
    return count;
  }

  /**
   * 获取所有任务列表
   */
  getTaskList(): Array<{
    taskId: string;
    state: string;
    userId?: string;
    connectedAt: string;
    assignedAt?: string;
  }> {
    return Array.from(this.tasks.values()).map((task) => ({
      taskId: task.taskId,
      state: task.state,
      userId: task.userId,
      connectedAt: task.connectedAt.toISOString(),
      assignedAt: task.assignedAt?.toISOString(),
    }));
  }

  /**
   * 根据 taskId 获取任务
   */
  getTask(taskId: string): WarmTask | undefined {
    return this.tasks.get(taskId);
  }
}
