/**
 * HTTP 接口。
 *
 * 用 node:http 裸写，不引 Web 框架 —— 一共只有 5 个路由，
 * 引 Fastify/Express 带来的依赖体积和升级负担不划算。
 */

import type { IncomingMessage, ServerResponse } from 'node:http';
import type { AppConfig } from '../config.js';
import type { TokenStore } from '../auth/tokens.js';
import type { PairingManager } from '../auth/pairing.js';
import type { SessionScanner } from '../claude/scanner.js';
import { loadHistory } from '../claude/history.js';
import { renameSession } from '@anthropic-ai/claude-agent-sdk';
import type { PairResponse } from '../protocol/wire.js';

/** 请求体最大字节数，防止有人拿超大 body 打爆内存 */
const MAX_BODY_BYTES = 64 * 1024;

/** 历史消息一次最多返回多少条 */
const DEFAULT_HISTORY_LIMIT = 300;
const MAX_HISTORY_LIMIT = 2000;

export interface HttpDeps {
    config: AppConfig;
    tokens: TokenStore;
    pairing: PairingManager;
    scanner: SessionScanner;
    /** 配对成功后调用，用于轮换配对码并刷新终端提示 */
    onPaired: (deviceName: string) => void;
}

// ---------------------------------------------------------------------------
// 基础工具
// ---------------------------------------------------------------------------

function sendJson(res: ServerResponse, status: number, body: unknown): void {
    const text = JSON.stringify(body);
    res.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': Buffer.byteLength(text),
        'Cache-Control': 'no-store',
    });
    res.end(text);
}

function sendError(res: ServerResponse, status: number, message: string): void {
    sendJson(res, status, { error: message });
}

async function readBody(req: IncomingMessage): Promise<string> {
    return new Promise((resolve, reject) => {
        const chunks: Buffer[] = [];
        let total = 0;
        req.on('data', (chunk: Buffer) => {
            total += chunk.length;
            if (total > MAX_BODY_BYTES) {
                reject(new Error('请求体过大'));
                req.destroy();
                return;
            }
            chunks.push(chunk);
        });
        req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
        req.on('error', reject);
    });
}

/** 从 Authorization 头里取出 Bearer token */
export function extractBearer(header: string | undefined): string | undefined {
    if (!header) return undefined;
    const prefix = 'Bearer ';
    if (!header.startsWith(prefix)) return undefined;
    const token = header.slice(prefix.length).trim();
    return token.length > 0 ? token : undefined;
}

function parseLimit(raw: string | null): number {
    if (!raw) return DEFAULT_HISTORY_LIMIT;
    const n = Number.parseInt(raw, 10);
    if (!Number.isInteger(n) || n < 1) return DEFAULT_HISTORY_LIMIT;
    return Math.min(n, MAX_HISTORY_LIMIT);
}

// ---------------------------------------------------------------------------
// 路由
// ---------------------------------------------------------------------------

export function createHttpHandler(deps: HttpDeps) {
    const { config, tokens, pairing, scanner, onPaired } = deps;

    return async function handle(
        req: IncomingMessage,
        res: ServerResponse,
    ): Promise<void> {
        const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
        const path = url.pathname;
        const method = req.method ?? 'GET';

        try {
            // ---- 健康检查：不需要鉴权，用于客户端探测地址是否正确 ----
            if (method === 'GET' && path === '/api/ping') {
                sendJson(res, 200, {
                    ok: true,
                    serverName: config.serverName,
                    // 让客户端知道当前是否有配对码在等待，配对页可据此提示
                    pairingOpen: pairing.peek() !== null,
                });
                return;
            }

            // ---- 配对：唯一不需要 token 的写接口 ----
            if (method === 'POST' && path === '/api/pair') {
                let payload: Record<string, unknown>;
                try {
                    const parsed: unknown = JSON.parse(await readBody(req));
                    if (typeof parsed !== 'object' || parsed === null) {
                        sendError(res, 400, '请求体必须是 JSON 对象');
                        return;
                    }
                    payload = parsed as Record<string, unknown>;
                } catch {
                    sendError(res, 400, '请求体不是合法 JSON');
                    return;
                }

                const code = typeof payload['code'] === 'string' ? payload['code'] : '';
                const deviceName =
                    typeof payload['deviceName'] === 'string'
                        ? payload['deviceName']
                        : '鸿蒙设备';

                const result = pairing.consume(code);
                if (!result.ok) {
                    const messages: Record<string, string> = {
                        locked: '尝试次数过多，请 60 秒后再试',
                        expired: '配对码已过期，请查看服务器终端获取新的配对码',
                        mismatch: '配对码不正确',
                    };
                    // 统一用 401，不因原因不同返回不同状态码
                    sendError(res, 401, messages[result.reason] ?? '配对失败');
                    return;
                }

                const issued = tokens.issue(deviceName);
                onPaired(issued.deviceName);

                const body: PairResponse = {
                    token: issued.token,
                    serverName: config.serverName,
                };
                sendJson(res, 200, body);
                return;
            }

            // ---- 以下接口都需要 token ----
            const device = tokens.verify(extractBearer(req.headers.authorization));
            if (!device) {
                sendError(res, 401, '未授权，请先完成配对');
                return;
            }

            if (method === 'GET' && path === '/api/projects') {
                sendJson(res, 200, await scanner.listProjects());
                return;
            }

            // /api/projects/:id/sessions
            const sessionsMatch = path.match(/^\/api\/projects\/([^/]+)\/sessions$/);
            if (method === 'GET' && sessionsMatch) {
                const projectId = decodeURIComponent(sessionsMatch[1]!);
                const sessions = await scanner.listSessions(projectId);
                if (!sessions) {
                    sendError(res, 404, '项目不存在');
                    return;
                }
                sendJson(res, 200, sessions);
                return;
            }

            // /api/sessions/:id/messages
            const messagesMatch = path.match(/^\/api\/sessions\/([^/]+)\/messages$/);
            if (method === 'GET' && messagesMatch) {
                const sessionId = decodeURIComponent(messagesMatch[1]!);
                const filePath = await scanner.findSessionFile(sessionId);
                if (!filePath) {
                    sendError(res, 404, '会话不存在');
                    return;
                }
                const limit = parseLimit(url.searchParams.get('limit'));
                sendJson(res, 200, await loadHistory(filePath, { limit }));
                return;
            }

            // /api/sessions/:id/rename
            const renameMatch = path.match(/^\/api\/sessions\/([^/]+)\/rename$/);
            if (method === 'POST' && renameMatch) {
                const sessionId = decodeURIComponent(renameMatch[1]!);
                const filePath = await scanner.findSessionFile(sessionId);
                if (!filePath) {
                    sendError(res, 404, '会话不存在');
                    return;
                }

                let title = '';
                try {
                    const parsed: unknown = JSON.parse(await readBody(req));
                    if (typeof parsed === 'object' && parsed !== null) {
                        const t = (parsed as Record<string, unknown>)['title'];
                        if (typeof t === 'string') title = t.trim();
                    }
                } catch {
                    sendError(res, 400, '请求体不是合法 JSON');
                    return;
                }
                if (title.length === 0) {
                    sendError(res, 400, '标题不能为空');
                    return;
                }
                if (title.length > 60) title = title.slice(0, 60);

                try {
                    // 走 SDK 而不是自己往 jsonl 里塞记录 ——
                    // 这样改的名字 Claude Code 自己也认，在终端 /resume
                    // 的选择器里看到的就是同一个标题，真正做到两端同步
                    const cwd = await scanner.findSessionCwd(sessionId);
                    if (!cwd) {
                        sendError(res, 404, '会话不存在');
                        return;
                    }
                    await renameSession(sessionId, title, { dir: cwd });
                } catch (e) {
                    console.error('[http] 重命名会话失败:', e);
                    sendError(res, 500, '重命名失败');
                    return;
                }
                sendJson(res, 200, { ok: true, title });
                return;
            }

            sendError(res, 404, '接口不存在');
        } catch (e) {
            console.error('[http] 处理请求出错:', e);
            // 不把内部错误细节回给客户端
            sendError(res, 500, '服务器内部错误');
        }
    };
}
