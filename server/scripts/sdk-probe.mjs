/**
 * 探测 Claude Agent SDK 在当前 Node 版本上到底能不能跑。
 *
 * @hono/node-server 声明 engines >= 20，但 npm 对 engines 只是警告不是强制，
 * 声明和实际能力常常对不上 —— 与其信声明，不如直接跑一次最小请求。
 *
 * 用法：node scripts/sdk-probe.mjs
 */

console.log(`Node ${process.versions.node}`);
console.log(
    `ANTHROPIC_BASE_URL = ${process.env.ANTHROPIC_BASE_URL ? '(已设置)' : '(未设置)'}`,
);
console.log(
    `ANTHROPIC_AUTH_TOKEN = ${process.env.ANTHROPIC_AUTH_TOKEN ? '(已设置)' : '(未设置)'}`,
);

let query;
try {
    ({ query } = await import('@anthropic-ai/claude-agent-sdk'));
    console.log('✓ SDK 模块加载成功');
} catch (e) {
    console.error('✗ SDK 模块加载失败:', e.message);
    process.exit(1);
}

const env = { ...process.env, CLAUDE_CODE_ENTRYPOINT: 'harmony-remote' };

// Windows 上 SDK 默认会去 spawn 无扩展名的 claude shell 脚本，报 spawn UNKNOWN。
// CLAUDE_CODE_EXECPATH 指向的是真正的可执行文件，优先用它。
const execPath = process.env.CLAUDE_CODE_EXECPATH;
if (execPath) console.log(`使用可执行文件: ${execPath}`);

const response = query({
    prompt: '只回复两个字符：OK',
    options: {
        cwd: process.cwd(),
        permissionMode: 'bypassPermissions',
        env,
        ...(execPath ? { pathToClaudeCodeExecutable: execPath } : {}),
    },
});

const timer = setTimeout(() => {
    console.error('✗ 90 秒无响应，判定超时');
    process.exit(1);
}, 90_000);

try {
    for await (const message of response) {
        if (message.type === 'system') {
            console.log(`✓ 会话已建立 session_id=${message.session_id}`);
        } else if (message.type === 'assistant') {
            const blocks = message.message?.content ?? [];
            for (const b of blocks) {
                if (b.type === 'text') console.log(`← ${b.text}`);
            }
        } else if (message.type === 'result') {
            console.log(
                `✓ 完成 is_error=${message.is_error} ${message.duration_ms}ms $${message.total_cost_usd}`,
            );
            break;
        }
    }
    clearTimeout(timer);
    console.log('\n结论：SDK 在 Node ' + process.versions.node + ' 上可用');
    process.exit(0);
} catch (e) {
    clearTimeout(timer);
    console.error('✗ 运行失败:', e?.message ?? e);
    console.error(e?.stack ?? '');
    process.exit(1);
}
