/**
 * Fargate 预热池测试 - 简化版 Session Gateway
 *
 * 功能：
 * 1. 接收预热任务的 WebSocket 连接
 * 2. 提供分配 API
 * 3. 提供状态查询 API
 */

import express from 'express';
import { createServer } from 'http';
import { WebSocketServer, WebSocket } from 'ws';
import { WarmPoolManager } from './warm-pool.js';
import { EfsManager } from './efs-manager.js';

// 配置
const PORT = parseInt(process.env.GATEWAY_PORT || '5174');
const EFS_MOUNT_PATH = process.env.EFS_MOUNT_PATH || '/mnt/efs';
const ENVIRONMENT = process.env.ENVIRONMENT || 'test';

// 初始化
const app = express();
const server = createServer(app);
const wss = new WebSocketServer({ noServer: true });

const warmPool = new WarmPoolManager();
const efsManager = new EfsManager(EFS_MOUNT_PATH, ENVIRONMENT);

// 中间件
app.use(express.json());

// ============================================================================
// HTTP API
// ============================================================================

/**
 * 状态查询
 */
app.get('/api/status', (req, res) => {
  res.json({
    warmCount: warmPool.getWarmCount(),
    assignedCount: warmPool.getAssignedCount(),
    tasks: warmPool.getTaskList(),
    efsMounted: efsManager.isMounted(),
  });
});

/**
 * 分配预热任务
 */
app.post('/api/acquire', async (req, res) => {
  const { userId, sessionId } = req.body;

  if (!userId) {
    res.status(400).json({ success: false, error: 'userId is required' });
    return;
  }

  const startTime = Date.now();

  // 确保用户目录存在
  try {
    await efsManager.ensureUserDirectory(userId);
  } catch (err) {
    console.error('[API] Failed to create user directory:', err);
  }

  // 分配任务
  const task = await warmPool.acquireWarmTask(userId, sessionId);

  if (task) {
    const latency = Date.now() - startTime;
    console.log(`[API] Assigned task to ${userId} in ${latency}ms`);

    res.json({
      success: true,
      taskId: task.taskId,
      userId,
      sessionId,
      latency,
    });
  } else {
    res.json({
      success: false,
      error: 'No warm tasks available',
      warmCount: warmPool.getWarmCount(),
    });
  }
});

/**
 * 释放任务
 */
app.post('/api/release', (req, res) => {
  const { taskId } = req.body;

  if (!taskId) {
    res.status(400).json({ success: false, error: 'taskId is required' });
    return;
  }

  warmPool.releaseTask(taskId);
  res.json({ success: true, taskId });
});

/**
 * 用户目录信息
 */
app.get('/api/users', (req, res) => {
  const users = efsManager.listUserDirectories();
  res.json({
    users,
    count: users.length,
  });
});

/**
 * 健康检查
 */
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    warmCount: warmPool.getWarmCount(),
    assignedCount: warmPool.getAssignedCount(),
  });
});

// ============================================================================
// WebSocket
// ============================================================================

server.on('upgrade', (request, socket, head) => {
  const url = request.url || '';

  // 预热任务连接端点: /internal/warm/{taskId}
  if (url.startsWith('/internal/warm/')) {
    wss.handleUpgrade(request, socket, head, (ws) => {
      const taskId = url.split('/').pop() || `unknown-${Date.now()}`;
      handleWarmTaskConnection(ws, taskId);
    });
  } else {
    // 未知端点，关闭连接
    socket.destroy();
  }
});

/**
 * 处理预热任务连接
 */
function handleWarmTaskConnection(ws: WebSocket, taskId: string): void {
  console.log(`[WS] Warm task connected: ${taskId}`);

  // 注册到预热池
  warmPool.registerWarmTask(taskId, ws);

  // 处理消息
  ws.on('message', (data) => {
    try {
      const msg = JSON.parse(data.toString());
      handleWarmTaskMessage(taskId, msg);
    } catch (err) {
      console.error(`[WS] Invalid message from ${taskId}:`, err);
    }
  });

  ws.on('close', () => {
    console.log(`[WS] Warm task disconnected: ${taskId}`);
  });

  ws.on('error', (err) => {
    console.error(`[WS] Error from ${taskId}:`, err);
  });
}

/**
 * 处理预热任务消息
 */
function handleWarmTaskMessage(taskId: string, msg: any): void {
  switch (msg.type) {
    case 'status':
      console.log(`[WS] Task ${taskId} status:`, msg.status);
      break;

    case 'heartbeat':
      warmPool.updateHeartbeat(taskId);
      break;

    case 'user_session_ready':
      console.log(`[WS] Task ${taskId} user session ready:`, msg.userId);
      break;

    case 'execute_result':
      console.log(`[WS] Task ${taskId} execute result:`, msg);
      break;

    default:
      console.log(`[WS] Task ${taskId} unknown message:`, msg.type);
  }
}

// ============================================================================
// 启动
// ============================================================================

server.listen(PORT, () => {
  console.log('='.repeat(50));
  console.log('  Fargate Warm Pool Test Gateway');
  console.log('='.repeat(50));
  console.log('');
  console.log(`  HTTP API:     http://localhost:${PORT}`);
  console.log(`  WebSocket:    ws://localhost:${PORT}/internal/warm/{taskId}`);
  console.log('');
  console.log('  Endpoints:');
  console.log('    GET  /api/status    - Pool status');
  console.log('    POST /api/acquire   - Acquire warm task');
  console.log('    POST /api/release   - Release task');
  console.log('    GET  /api/users     - List user directories');
  console.log('    GET  /health        - Health check');
  console.log('');
  console.log(`  EFS Mount:    ${EFS_MOUNT_PATH}`);
  console.log(`  Environment:  ${ENVIRONMENT}`);
  console.log(`  EFS Mounted:  ${efsManager.isMounted()}`);
  console.log('');
  console.log('='.repeat(50));
});
