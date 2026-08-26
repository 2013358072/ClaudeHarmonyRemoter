/**
 * 服务端配置。
 *
 * 配置来源优先级（后者覆盖前者）：
 *   1. 内置默认值
 *   2. 配置文件 ~/.claude-harmony/config.json
 *   3. 环境变量
 */

import { homedir, hostname } from 'node:os';
import { join, resolve } from 'node:path';
import { readFileSync, existsSync } from 'node:fs';

/** Claude Code 支持的权限模式 */
export type PermissionMode =
    | 'default'
    | 'acceptEdits'
    | 'bypassPermissions'
    | 'plan';

export interface AppConfig {
    /** 监听端口 */
    port: number;
    /** 监听地址。默认 0.0.0.0，方便同网段手机访问 */
    host: string;
    /** 服务器展示名，配对成功后显示在手机上 */
    serverName: string;
    /**
     * 允许暴露给手机端的项目根目录白名单（绝对路径）。
     * scanner 只会返回位于这些目录之下的项目。
     * 留空表示不做限制 —— 强烈不建议，见 README 的安全说明。
     */
    projectRoots: string[];
    /**
     * 传给 Claude Code 的权限模式。
     *
     * 默认 default：客户端已实现权限交互，Claude 要改文件或跑命令时
     * 手机上会弹确认框，用户可以选允许 / 总是允许 / 拒绝。
     *
     * 想回到"全部自动放行"可以显式配成 bypassPermissions，
     * 但那意味着手机指令会在服务器上无确认执行 shell 命令，
     * 务必配合 projectRoots 白名单。
     */
    permissionMode: PermissionMode;
    /** 配对码有效期（毫秒） */
    pairingTtlMs: number;
    /** 数据目录，存放 token 等 */
    dataDir: string;
    /** Claude Code 配置目录，默认 ~/.claude */
    claudeConfigDir: string;
    /**
     * claude 可执行文件路径。留空则由 SDK 自己在 PATH 里找。
     *
     * Linux 上一般不用配。Windows 上必须配，否则 SDK 会去 spawn 无扩展名的
     * shell 脚本并报 `spawn UNKNOWN` —— 默认取 CLAUDE_CODE_EXECPATH，
     * 那是 Claude Code 自己设的，指向真正的可执行文件。
     */
    claudeExecutablePath?: string;
}

/** 配置文件里允许出现的字段，全部可选 */
type ConfigFileShape = Partial<{
    port: number;
    host: string;
    serverName: string;
    projectRoots: string[];
    permissionMode: PermissionMode;
    pairingTtlMs: number;
    claudeExecutablePath: string;
}>;

const VALID_PERMISSION_MODES: readonly PermissionMode[] = [
    'default',
    'acceptEdits',
    'bypassPermissions',
    'plan',
];

const DEFAULT_DATA_DIR = join(homedir(), '.claude-harmony');

function readConfigFile(dataDir: string): ConfigFileShape {
    const path = join(dataDir, 'config.json');
    if (!existsSync(path)) return {};
    try {
        const parsed: unknown = JSON.parse(readFileSync(path, 'utf8'));
        if (typeof parsed !== 'object' || parsed === null) {
            console.warn(`[config] ${path} 不是一个对象，已忽略`);
            return {};
        }
        return parsed as ConfigFileShape;
    } catch (e) {
        console.warn(`[config] 解析 ${path} 失败，已忽略：`, e);
        return {};
    }
}

function parsePort(raw: string | undefined, fallback: number): number {
    if (!raw) return fallback;
    const n = Number.parseInt(raw, 10);
    if (!Number.isInteger(n) || n < 1 || n > 65535) {
        console.warn(`[config] 端口 "${raw}" 非法，回退到 ${fallback}`);
        return fallback;
    }
    return n;
}

function parsePermissionMode(
    raw: string | undefined,
    fallback: PermissionMode,
): PermissionMode {
    if (!raw) return fallback;
    if (!VALID_PERMISSION_MODES.includes(raw as PermissionMode)) {
        console.warn(
            `[config] 权限模式 "${raw}" 非法，可选值：${VALID_PERMISSION_MODES.join(' / ')}。回退到 ${fallback}`,
        );
        return fallback;
    }
    return raw as PermissionMode;
}

/** 把白名单里的路径统一成绝对路径 */
function normalizeRoots(roots: string[] | undefined): string[] {
    if (!Array.isArray(roots)) return [];
    return roots
        .filter((r): r is string => typeof r === 'string' && r.length > 0)
        .map((r) => resolve(r.startsWith('~') ? r.replace('~', homedir()) : r));
}

export function loadConfig(): AppConfig {
    const dataDir = process.env.CLAUDE_HARMONY_DATA_DIR
        ? resolve(process.env.CLAUDE_HARMONY_DATA_DIR)
        : DEFAULT_DATA_DIR;

    const file = readConfigFile(dataDir);

    // 环境变量里的白名单用冒号分隔，与 PATH 习惯一致
    const envRoots = process.env.CLAUDE_HARMONY_PROJECT_ROOTS
        ? process.env.CLAUDE_HARMONY_PROJECT_ROOTS.split(':')
        : undefined;

    return {
        port: parsePort(process.env.CLAUDE_HARMONY_PORT, file.port ?? 4517),
        host: process.env.CLAUDE_HARMONY_HOST ?? file.host ?? '0.0.0.0',
        serverName:
            process.env.CLAUDE_HARMONY_NAME ?? file.serverName ?? hostname(),
        projectRoots: normalizeRoots(envRoots ?? file.projectRoots),
        permissionMode: parsePermissionMode(
            process.env.CLAUDE_HARMONY_PERMISSION_MODE,
            file.permissionMode ?? 'default',
        ),
        pairingTtlMs: file.pairingTtlMs ?? 5 * 60 * 1000,
        dataDir,
        // 与 Claude Code 本身的行为保持一致：尊重 CLAUDE_CONFIG_DIR
        claudeConfigDir:
            process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), '.claude'),
        claudeExecutablePath:
            process.env.CLAUDE_HARMONY_CLAUDE_PATH ??
            file.claudeExecutablePath ??
            process.env.CLAUDE_CODE_EXECPATH,
    };
}
