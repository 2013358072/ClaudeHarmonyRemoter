/**
 * ClaudeHarmonyRemoter 服务端入口。
 *
 * 启动后：
 *   1. 在配置的端口上监听 HTTP（接口）与 WebSocket（对话流）
 *   2. 生成一个 6 位配对码，连同访问地址和二维码打印到终端
 *   3. 手机扫码或手输地址 + 配对码完成配对，换取长期 token
 */

import { createServer } from 'node:http';
import { networkInterfaces } from 'node:os';
import qrcode from 'qrcode-terminal';

import { loadConfig } from './config.js';
import { TokenStore } from './auth/tokens.js';
import { PairingManager } from './auth/pairing.js';
import { SessionScanner } from './claude/scanner.js';
import { createHttpHandler } from './transport/httpApi.js';
import { attachWebSocket } from './transport/wsHub.js';

// ---------------------------------------------------------------------------
// 环境检查
// ---------------------------------------------------------------------------

/**
 * 不做 Node 版本门槛。
 *
 * Claude Agent SDK 的传递依赖 @hono/node-server 声明 engines >= 20，
 * 但那只是声明 —— 实测在 Node 18.20.1 上 SDK 完整可用（scripts/sdk-probe.mjs）。
 * 按声明去硬拦会误伤能正常工作的环境，所以这里什么都不做，
 * 真出问题让 SDK 自己报错，错误会通过 fatal 消息送到客户端。
 */

// ---------------------------------------------------------------------------
// 终端提示
// ---------------------------------------------------------------------------

/** 找出本机在局域网里的 IPv4 地址，供手机访问 */
function lanAddresses(): string[] {
    const out: string[] = [];
    for (const addrs of Object.values(networkInterfaces())) {
        if (!addrs) continue;
        for (const addr of addrs) {
            if (addr.family === 'IPv4' && !addr.internal) {
                out.push(addr.address);
            }
        }
    }
    return out;
}

const DIM = '\x1b[2m';
const BOLD = '\x1b[1m';
const YELLOW = '\x1b[33m';
const RED = '\x1b[31m';
const CYAN = '\x1b[36m';
const RESET = '\x1b[0m';

function printBanner(opts: {
    port: number;
    serverName: string;
    code: string;
    ttlMs: number;
    permissionMode: string;
    projectRoots: readonly string[];
}): void {
    const addrs = lanAddresses();
    const primary = addrs[0] ?? '127.0.0.1';
    const base = `http://${primary}:${opts.port}`;

    console.log('');
    console.log(`${BOLD}ClaudeHarmonyRemoter${RESET} ${DIM}(${opts.serverName})${RESET}`);
    console.log('');
    console.log(`  ${BOLD}访问地址${RESET}`);
    if (addrs.length === 0) {
        console.log(`    ${DIM}未检测到局域网地址${RESET}`);
    }
    for (const a of addrs) {
        console.log(`    http://${a}:${opts.port}`);
    }
    console.log('');
    console.log(
        `  ${BOLD}配对码${RESET}  ${CYAN}${BOLD}${opts.code}${RESET}   ` +
            `${DIM}${Math.round(opts.ttlMs / 60000)} 分钟内有效${RESET}`,
    );
    console.log('');

    // 二维码内容就是配对所需的全部信息，手机扫了直接进
    const payload = `chr://pair?host=${primary}&port=${opts.port}&code=${opts.code}`;
    qrcode.generate(payload, { small: true }, (qr: string) => {
        console.log(
            qr
                .split('\n')
                .map((l) => `  ${l}`)
                .join('\n'),
        );
    });

    console.log(`  ${DIM}也可在 App 里手动输入上面的地址和配对码${RESET}`);
    console.log('');

    // ---- 安全提示 ----
    if (opts.permissionMode === 'bypassPermissions') {
        console.log(
            `  ${RED}${BOLD}⚠ 权限模式 bypassPermissions${RESET}`,
        );
        console.log(
            `  ${YELLOW}手机发出的指令将在本机无确认地执行文件修改和 shell 命令。${RESET}`,
        );
        if (opts.projectRoots.length === 0) {
            console.log(
                `  ${RED}且未配置项目白名单，Claude 的全部本地会话都会暴露给已配对设备。${RESET}`,
            );
            console.log(
                `  ${DIM}建议在 ~/.claude-harmony/config.json 里设置 projectRoots${RESET}`,
            );
        } else {
            console.log(`  ${DIM}项目白名单：${opts.projectRoots.join(', ')}${RESET}`);
        }
        console.log('');
    }
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
    const config = loadConfig();
    const tokens = new TokenStore(config.dataDir);
    const pairing = new PairingManager(config.pairingTtlMs);
    const scanner = new SessionScanner(config.claudeConfigDir, config.projectRoots);

    const code = pairing.rotate();

    const handleHttp = createHttpHandler({
        config,
        tokens,
        pairing,
        scanner,
        onPaired: (deviceName) => {
            console.log(`\n  ${BOLD}✓ 已配对新设备：${deviceName}${RESET}`);
            // 轮换出新码，方便接着配第二台设备
            const next = pairing.rotate();
            console.log(
                `  ${DIM}新配对码${RESET} ${CYAN}${BOLD}${next.code}${RESET}\n`,
            );
        },
    });

    const server = createServer((req, res) => {
        void handleHttp(req, res);
    });

    const closeWs = attachWebSocket(server, { config, tokens, scanner });

    server.listen(config.port, config.host, () => {
        printBanner({
            port: config.port,
            serverName: config.serverName,
            code: code.code,
            ttlMs: config.pairingTtlMs,
            permissionMode: config.permissionMode,
            projectRoots: config.projectRoots,
        });
    });

    server.on('error', (e: NodeJS.ErrnoException) => {
        if (e.code === 'EADDRINUSE') {
            console.error(
                `[启动失败] 端口 ${config.port} 已被占用，` +
                    `可用 CLAUDE_HARMONY_PORT 换一个端口`,
            );
        } else {
            console.error('[启动失败]', e);
        }
        process.exit(1);
    });

    // 退出前把 lastSeenAt 落盘
    const shutdown = (signal: string) => {
        console.log(`\n${DIM}收到 ${signal}，正在退出…${RESET}`);
        tokens.flush();
        closeWs();
        server.close(() => process.exit(0));
        // 兜底：5 秒内没关干净就强退
        setTimeout(() => process.exit(0), 5000).unref();
    };
    process.on('SIGINT', () => shutdown('SIGINT'));
    process.on('SIGTERM', () => shutdown('SIGTERM'));
}

void main();
