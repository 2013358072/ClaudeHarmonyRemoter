/**
 * WebSocket 冒烟测试。
 *
 * 用法：node scripts/ws-smoke.mjs <token> [projectId] [sessionId]
 *
 * 依次验证：
 *   1. 不带 token 连接应被拒（401）
 *   2. 带 token 连接应成功
 *   3. attach 一个项目后能收到 attached / fatal
 *   4. 发一条消息能收到回显和后续事件
 */

import WebSocket from 'ws';

const [token, projectId, sessionId] = process.argv.slice(2);
const PORT = process.env.CLAUDE_HARMONY_PORT ?? '4517';
const BASE = `ws://127.0.0.1:${PORT}/ws`;
/** 要发的提示词，用 PROMPT 环境变量覆盖（续接验证时会换成追问） */
const PROMPT = process.env.PROMPT ?? '请回复 OK 两个字';

if (!token) {
    console.error('用法: node scripts/ws-smoke.mjs <token> [projectId] [sessionId]');
    process.exit(1);
}

function step(n, text) {
    console.log(`\n[${n}] ${text}`);
}

/** 不带 token 连接，期望被拒 */
function testUnauthorized() {
    return new Promise((resolve) => {
        const ws = new WebSocket(BASE);
        ws.on('open', () => {
            console.log('  ✗ 竟然连上了，鉴权没生效');
            ws.close();
            resolve(false);
        });
        ws.on('error', (e) => {
            const ok = String(e.message).includes('401');
            console.log(ok ? '  ✓ 被正确拒绝 (401)' : `  ? 拒绝了但原因是: ${e.message}`);
            resolve(ok);
        });
    });
}

/** 带 token 连接并跑完整流程 */
function testSession() {
    return new Promise((resolve) => {
        const ws = new WebSocket(`${BASE}?token=${encodeURIComponent(token)}`);
        const seen = [];
        let done = false;
        // attached 会来两次（先占位、后补真实 id），提示只发一次
        let sentPrompt = false;

        const finish = (result) => {
            if (done) return;
            done = true;
            ws.close();
            resolve(result);
        };

        ws.on('open', () => {
            console.log('  ✓ 连接已建立');
            if (!projectId) {
                console.log('  (未提供 projectId，跳过 attach)');
                finish(true);
                return;
            }
            const attach = { type: 'attach', projectId };
            if (sessionId) attach.sessionId = sessionId;
            console.log(`  → attach ${projectId}${sessionId ? ` (续接 ${sessionId})` : ' (新会话)'}`);
            ws.send(JSON.stringify(attach));
        });

        ws.on('message', (raw) => {
            let msg;
            try {
                msg = JSON.parse(String(raw));
            } catch {
                return;
            }
            seen.push(msg.type);

            if (msg.type === 'attached') {
                // 新会话首次 attached 时 sessionId 是空的，真实 id 稍后补发
                console.log(`  ← attached sessionId=${msg.sessionId || '(待定)'}`);
                if (!sentPrompt) {
                    sentPrompt = true;
                    console.log(`  → send "${PROMPT}"`);
                    ws.send(JSON.stringify({ type: 'send', text: PROMPT }));
                }
            } else if (msg.type === 'event') {
                const e = msg.payload;
                if (e.kind === 'text') {
                    console.log(`  ← [${e.role}] ${(e.text ?? '').slice(0, 60)}`);
                } else if (e.kind === 'tool') {
                    console.log(`  ← [tool:${e.toolStatus}] ${e.toolSummary ?? ''}`);
                } else if (e.kind === 'result') {
                    console.log(`  ← [result] ok=${e.ok} ${e.durationMs}ms $${e.costUsd}`);
                    finish(true);
                } else if (e.kind === 'error') {
                    console.log(`  ← [error] ${e.text}`);
                }
            } else if (msg.type === 'thinking') {
                console.log(`  ← thinking=${msg.value}`);
            } else if (msg.type === 'fatal') {
                console.log(`  ← fatal: ${msg.message}`);
                finish(true);
            }
        });

        ws.on('error', (e) => {
            console.log(`  ✗ 连接出错: ${e.message}`);
            finish(false);
        });

        // 兜底超时，避免脚本挂死
        setTimeout(() => {
            console.log(`  (超时结束，收到过: ${seen.join(', ') || '无'})`);
            finish(true);
        }, 120_000);
    });
}

step(1, '不带 token 连接');
await testUnauthorized();

step(2, '带 token 连接并跑会话');
await testSession();

console.log('\n完成');
process.exit(0);
