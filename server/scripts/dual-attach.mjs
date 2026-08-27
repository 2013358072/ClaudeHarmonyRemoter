/**
 * 复现：两个客户端同时挂同一个会话会怎样。
 *
 * 用户报告「服务器端开着会话时，手机发的消息不同步，还报 No response requested」。
 * 怀疑是同一个 session 被两个 claude 进程同时持有 —— 我们的服务端是
 * spawn 一个新进程 --resume，和用户终端里那个是两个独立进程。
 *
 * 这个脚本用两个 WS 连接挂同一个 sessionId，模拟同样的冲突。
 *
 * 用法：node scripts/dual-attach.mjs <token> <projectId>
 */

import WebSocket from 'ws';

const [token, projectId] = process.argv.slice(2);
const PORT = process.env.CLAUDE_HARMONY_PORT ?? '4517';
const BASE = `ws://127.0.0.1:${PORT}/ws`;

if (!token || !projectId) {
    console.error('用法: node scripts/dual-attach.mjs <token> <projectId>');
    process.exit(1);
}

function connect(label) {
    const ws = new WebSocket(`${BASE}?token=${encodeURIComponent(token)}`);
    ws.on('error', (e) => console.log(`  [${label}] 连接错误: ${e.message}`));
    return ws;
}

function log(label, msg) {
    if (msg.type === 'event') {
        const e = msg.payload;
        if (e.kind === 'text') {
            console.log(`  [${label}] ${e.role}: ${(e.text ?? '').slice(0, 60)}`);
        } else if (e.kind === 'error') {
            console.log(`  [${label}] ❗ error: ${e.text}`);
        } else if (e.kind === 'tool') {
            console.log(`  [${label}] tool:${e.toolStatus} ${(e.toolSummary ?? '').slice(0, 40)}`);
        }
    } else if (msg.type === 'fatal') {
        console.log(`  [${label}] ❗ fatal: ${msg.message}`);
    } else if (msg.type === 'attached') {
        console.log(`  [${label}] attached ${msg.sessionId || '(待定)'}`);
    }
}

const A = connect('A');
let sessionId = '';

A.on('open', () => {
    console.log('[1] A 连接，新建会话');
    A.send(JSON.stringify({ type: 'attach', projectId }));
    setTimeout(() => {
        console.log('[2] A 发第一条消息（这会真正拉起 claude）');
        A.send(JSON.stringify({ type: 'send', text: '回复两个字：就绪' }));
    }, 500);
});

A.on('message', (raw) => {
    const msg = JSON.parse(String(raw));
    if (msg.type === 'attached' && msg.sessionId) {
        sessionId = msg.sessionId;
    }
    log('A', msg);

    // A 跑完一轮后，让 B 挂同一个会话
    if (msg.type === 'thinking' && msg.value === false && sessionId && !global.__bStarted) {
        global.__bStarted = true;
        setTimeout(startB, 1000);
    }
});

function startB() {
    console.log(`\n[3] B 连接，挂同一个会话 ${sessionId.slice(0, 8)}`);
    const B = connect('B');
    B.on('open', () => {
        B.send(JSON.stringify({ type: 'attach', projectId, sessionId }));
        setTimeout(() => {
            console.log('[4] B 发消息 —— 此时 A 的 claude 进程还活着，同一会话有两个进程');
            B.send(JSON.stringify({ type: 'send', text: '回复两个字：冲突' }));
        }, 500);
    });
    B.on('message', (raw) => log('B', JSON.parse(String(raw))));

    setTimeout(() => {
        console.log('\n[5] 同时让 A 再发一条，看两边是否互相可见');
        A.send(JSON.stringify({ type: 'send', text: '回复两个字：并发' }));
    }, 12000);

    setTimeout(() => {
        console.log('\n结束');
        A.close();
        B.close();
        process.exit(0);
    }, 40000);
}
