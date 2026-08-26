/**
 * 最小复现：验证 canUseTool 在什么条件下会被调用。
 *
 * 服务端里 canUseTool 一直没触发，先用这个脚本把问题从业务代码里隔离出来：
 * 分别用「字符串 prompt」和「流式 prompt」跑同一条需要权限的命令，
 * 看回调是否被调用。
 *
 * 用法：node scripts/permission-probe.mjs [string|stream]
 */

import { query } from '@anthropic-ai/claude-agent-sdk';

const MODE = process.argv[2] ?? 'string';
const execPath = process.env.CLAUDE_CODE_EXECPATH;

let called = 0;

const canUseTool = async (toolName, input, options) => {
    called += 1;
    console.log(`  🔒 canUseTool 触发！tool=${toolName}`);
    console.log(`     title       = ${options.title}`);
    console.log(`     displayName = ${options.displayName}`);
    console.log(`     description = ${options.description}`);
    console.log(`     suggestions = ${options.suggestions ? options.suggestions.length + ' 条' : '无'}`);
    console.log(`     requestId   = ${options.requestId}`);
    return { behavior: 'allow' };
};

function makeStreamPrompt(text) {
    // 和服务端一样的形态：可外部推送的异步迭代器
    async function* gen() {
        yield {
            type: 'user',
            message: { role: 'user', content: text },
            parent_tool_use_id: null,
            session_id: '',
        };
        // 不结束迭代器，模拟长驻会话
        await new Promise((r) => setTimeout(r, 60_000));
    }
    return gen();
}

const TEXT = process.env.PTEXT ?? '请运行 shell 命令 echo probe-test';

console.log(`模式: ${MODE}`);

const response = query({
    prompt: MODE === 'stream' ? makeStreamPrompt(TEXT) : TEXT,
    options: {
        cwd: process.cwd(),
        permissionMode: process.env.MODE ?? 'default',
        canUseTool,
        ...(execPath ? { pathToClaudeCodeExecutable: execPath } : {}),
    },
});

const timer = setTimeout(() => {
    console.log(`\n超时结束。canUseTool 调用次数 = ${called}`);
    process.exit(called > 0 ? 0 : 1);
}, 90_000);

try {
    for await (const m of response) {
        if (m.type === 'assistant') {
            for (const b of m.message?.content ?? []) {
                if (b.type === 'text') console.log(`  ← ${b.text.slice(0, 80)}`);
                if (b.type === 'tool_use') console.log(`  ← [tool_use] ${b.name}`);
            }
        } else if (m.type === 'result') {
            console.log(`  ← result is_error=${m.is_error}`);
            break;
        }
    }
} catch (e) {
    console.error('运行出错:', e?.message ?? e);
}

clearTimeout(timer);
console.log(`\ncanUseTool 调用次数 = ${called}`);
process.exit(called > 0 ? 0 : 1);
