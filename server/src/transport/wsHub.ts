/**
 * WebSocket 层：把客户端的 attach / send / interrupt 映射到 ClaudeRunner，
 * 再把 runner 产生的事件推回客户端。
 *
 * 一个连接同一时刻只挂一个会话。切换项目/会话就是重新 attach，
 * 旧的 runner 会被停掉 —— 手机上不存在"同时看多个会话"的界面，
 * 让连接与会话一一对应能省掉大量状态同步的麻烦。
 */

import { WebSocketServer, WebSocket } from 'ws';
import type { Server } from 'node:http';
import type { AppConfig } from '../config.js';
import type { TokenStore } from '../auth/tokens.js';
import type { SessionScanner } from '../claude/scanner.js';
import { ClaudeRunner } from '../claude/runner.js';
import { extractBearer } from './httpApi.js';
import type {
    ClientMessage,
    ServerMessage,
    WireEvent,
} from '../protocol/wire.js';

/** 单条上行消息的最大字节数 */
const MAX_MESSAGE_BYTES = 256 * 1024;
/** 心跳间隔，用于清理半死连接 */
const HEARTBEAT_MS = 30_000;

export interface WsDeps {
    config: AppConfig;
    tokens: TokenStore;
    scanner: SessionScanner;
}

/** 每个连接的状态 */
interface Connection {
    socket: WebSocket;
    deviceName: string;
    runner: ClaudeRunner | null;
    alive: boolean;
}

function send(socket: WebSocket, message: ServerMessage): void {
    if (socket.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify(message));
}

export function attachWebSocket(server: Server, deps: WsDeps): () => void {
    const { tokens, scanner, config } = deps;

    // noServer 模式：自己处理 upgrade，才能在握手阶段就做鉴权
    const wss = new WebSocketServer({ noServer: true });
    const connections = new Set<Connection>();

    server.on('upgrade', (req, socket, head) => {
        const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
        if (url.pathname !== '/ws') {
            socket.destroy();
            return;
        }

        // 鸿蒙的 webSocket.connect 支持自定义 header，所以 token 走 Authorization。
        // 同时兼容 query 参数形式，方便用 wscat 之类的工具调试。
        const token =
            extractBearer(req.headers.authorization) ??
            url.searchParams.get('token') ??
            undefined;

        const device = tokens.verify(token);
        if (!device) {
            socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
            socket.destroy();
            return;
        }

        wss.handleUpgrade(req, socket, head, (ws) => {
            handleConnection(ws, device.deviceName);
        });
    });

    function handleConnection(socket: WebSocket, deviceName: string): void {
        const conn: Connection = { socket, deviceName, runner: null, alive: true };
        connections.add(conn);
        console.log(`[ws] ${deviceName} 已连接`);

        socket.on('pong', () => {
            conn.alive = true;
        });

        socket.on('message', (raw) => {
            void onMessage(conn, raw);
        });

        socket.on('close', () => {
            conn.runner?.stop();
            connections.delete(conn);
            console.log(`[ws] ${deviceName} 已断开`);
        });

        socket.on('error', (e) => {
            console.warn(`[ws] ${deviceName} 连接出错:`, e);
        });
    }

    async function onMessage(conn: Connection, raw: unknown): Promise<void> {
        const text = String(raw);
        if (Buffer.byteLength(text) > MAX_MESSAGE_BYTES) {
            send(conn.socket, { type: 'fatal', message: '消息过大' });
            return;
        }

        let msg: ClientMessage;
        try {
            const parsed: unknown = JSON.parse(text);
            if (typeof parsed !== 'object' || parsed === null) return;
            msg = parsed as ClientMessage;
        } catch {
            send(conn.socket, { type: 'fatal', message: '消息不是合法 JSON' });
            return;
        }

        switch (msg.type) {
            case 'attach':
                await onAttach(conn, msg);
                return;

            case 'send': {
                if (!conn.runner) {
                    send(conn.socket, { type: 'fatal', message: '请先 attach 一个会话' });
                    return;
                }
                const content = typeof msg.text === 'string' ? msg.text.trim() : '';
                if (!content) return;

                // 延迟到第一条消息才真正拉起 claude 进程。
                //
                // 进程启动要加载整个 transcript，大会话上可能几十秒。
                // 放在 attach 里做，用户一进聊天页就得干等，而他可能只是
                // 想翻翻历史记录 —— 那种情况下这个进程纯属白起。
                if (!conn.runner.isStarted()) {
                    conn.runner.start();
                }

                // 先把用户消息回显出去。SDK 不会把我们推进去的用户消息
                // 再吐回来，不回显的话手机上看不到自己刚发的内容。
                const echo: WireEvent = {
                    kind: 'text',
                    id: `local-${Date.now()}`,
                    ts: Date.now(),
                    role: 'user',
                    text: content,
                };
                send(conn.socket, { type: 'event', payload: echo });

                conn.runner.send(content);
                return;
            }

            case 'permission_response': {
                const requestId = typeof msg.requestId === 'string' ? msg.requestId : '';
                const decision = msg.decision;
                if (!requestId || !decision) return;
                if (decision !== 'allow' && decision !== 'always' && decision !== 'deny') {
                    return;
                }
                const ok = conn.runner?.resolvePermission(requestId, decision) ?? false;
                if (!ok) {
                    // 请求已经失效（超时/被打断），让客户端收起弹窗
                    send(conn.socket, { type: 'permission_closed', requestId });
                }
                return;
            }

            case 'interrupt':
                await conn.runner?.interrupt();
                return;

            case 'detach':
                conn.runner?.stop();
                conn.runner = null;
                return;

            default:
                send(conn.socket, { type: 'fatal', message: '未知的消息类型' });
        }
    }

    async function onAttach(conn: Connection, msg: ClientMessage): Promise<void> {
        const projectId = typeof msg.projectId === 'string' ? msg.projectId : '';
        if (!projectId) {
            send(conn.socket, { type: 'fatal', message: 'attach 缺少 projectId' });
            return;
        }

        const cwd = await scanner.resolveProjectPath(projectId);
        if (!cwd) {
            send(conn.socket, { type: 'fatal', message: '项目不存在或不在白名单内' });
            return;
        }

        // 切换会话前先停掉旧的
        conn.runner?.stop();

        const runner = new ClaudeRunner({
            cwd,
            resumeSessionId:
                typeof msg.sessionId === 'string' && msg.sessionId ? msg.sessionId : undefined,
            permissionMode: config.permissionMode,
            executablePath: config.claudeExecutablePath,
            onEvent: (event) => send(conn.socket, { type: 'event', payload: event }),
            onThinking: (value) => send(conn.socket, { type: 'thinking', value }),
            onSessionId: (sessionId) => send(conn.socket, { type: 'attached', sessionId }),
            onPermissionRequest: (request) =>
                send(conn.socket, { type: 'permission_request', request }),
            onPermissionClosed: (requestId) =>
                send(conn.socket, { type: 'permission_closed', requestId }),
            onFatal: (message) => send(conn.socket, { type: 'fatal', message }),
        });
        conn.runner = runner;
        // 刻意不在这里 start()：见 'send' 分支的说明

        // attached 的语义是"可以发消息了"，不是"拿到 session id 了"。
        //
        // 这一点很关键：新建会话时，SDK 在收到第一条用户消息之前不会吐任何东西，
        // 包括带 session_id 的 init 消息。如果非要等到 id 才回 attached，
        // 就会死锁 —— 客户端等 attached 才敢发，服务端等发了才有 id。
        //
        // 所以这里立刻回一条，新会话的 sessionId 先留空；
        // 等真实 id 到了，onSessionId 会再补发一条 attached 让客户端更新。
        send(conn.socket, { type: 'attached', sessionId: msg.sessionId ?? '' });

        console.log(`[ws] ${conn.deviceName} attach → ${cwd}${msg.sessionId ? ` (续接 ${msg.sessionId})` : ' (新会话)'}`);
    }

    // 心跳：ws 不会自动发现对端掉线，必须自己 ping
    const heartbeat = setInterval(() => {
        for (const conn of connections) {
            if (!conn.alive) {
                conn.socket.terminate();
                continue;
            }
            conn.alive = false;
            conn.socket.ping();
        }
    }, HEARTBEAT_MS);

    /** 关服时调用 */
    return function close(): void {
        clearInterval(heartbeat);
        for (const conn of connections) {
            conn.runner?.stop();
            conn.socket.close();
        }
        wss.close();
    };
}
