/**
 * 扫描 Claude Code 的本地会话，聚合出项目列表与会话列表。
 *
 * 会话存储布局：
 *   ~/.claude/projects/<projectId>/<sessionId>.jsonl
 *
 * 两个必须注意的点：
 *
 * 1. projectId 是 `resolve(cwd).replace(/[^a-zA-Z0-9-]/g, '-')` 得来的，
 *    这是**有损且不可逆**的（/a/b 和 -a-b 会撞到一起），
 *    所以真实路径只能从 jsonl 内容里读 —— 每行记录都带 cwd 字段。
 *
 * 2. `claude --resume` 只接受 UUID 格式的 sessionId（v2.0.65 起），
 *    `agent-*` 这类子会话必须过滤掉，否则续接会失败。
 */

import { readdirSync, statSync, createReadStream, openSync, readSync, closeSync } from 'node:fs';
import { join, basename, sep } from 'node:path';
import { createInterface } from 'node:readline';
import type { ProjectInfo, SessionInfo } from '../protocol/wire.js';

/** UUID v4 形态，与 Claude Code 对 --resume 的要求一致 */
const UUID_RE =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** 读首行时最多读这么多字节，足够覆盖一条记录 */
const HEAD_BYTES = 128 * 1024;

interface SessionMeta {
    sessionId: string;
    cwd: string;
    gitBranch: string;
    title: string;
    messageCount: number;
    lastActiveAt: number;
}

/** 按 文件路径 + mtime + size 缓存，避免每次请求都重扫全部会话 */
interface CacheEntry {
    mtimeMs: number;
    size: number;
    meta: SessionMeta;
}
const metaCache = new Map<string, CacheEntry>();

// ---------------------------------------------------------------------------
// 单个会话文件的解析
// ---------------------------------------------------------------------------

/** 只读文件头部，够解析出前几条记录即可 */
function readHead(path: string, bytes: number): string {
    const fd = openSync(path, 'r');
    try {
        const buf = Buffer.allocUnsafe(bytes);
        const read = readSync(fd, buf, 0, bytes, 0);
        return buf.subarray(0, read).toString('utf8');
    } finally {
        closeSync(fd);
    }
}

/** 流式数换行符，比整文件读入内存省得多 */
async function countLines(path: string): Promise<number> {
    return new Promise((resolve, reject) => {
        let count = 0;
        const stream = createReadStream(path);
        stream.on('data', (chunk: string | Buffer) => {
            const buf = typeof chunk === 'string' ? Buffer.from(chunk) : chunk;
            for (let i = 0; i < buf.length; i += 1) {
                if (buf[i] === 0x0a) count += 1;
            }
        });
        stream.on('end', () => resolve(count));
        stream.on('error', reject);
    });
}

/** 从一条记录里提取用户消息的纯文本，提取不到返回 undefined */
function extractUserText(record: Record<string, unknown>): string | undefined {
    if (record['type'] !== 'user') return undefined;
    // 子会话（sidechain）的消息不能代表整个会话的主题
    if (record['isSidechain'] === true) return undefined;

    const message = record['message'];
    if (typeof message !== 'object' || message === null) return undefined;
    const content = (message as Record<string, unknown>)['content'];

    if (typeof content === 'string') return content;
    if (!Array.isArray(content)) return undefined;

    for (const block of content) {
        if (typeof block !== 'object' || block === null) continue;
        const b = block as Record<string, unknown>;
        if (b['type'] === 'text' && typeof b['text'] === 'string') {
            return b['text'];
        }
    }
    return undefined;
}

/**
 * 解析一个会话文件的元信息。
 * 解析失败返回 null（文件可能正被写入、或格式不认识），调用方跳过即可。
 */
async function parseSession(
    filePath: string,
    sessionId: string,
): Promise<SessionMeta | null> {
    let stat;
    try {
        stat = statSync(filePath);
    } catch {
        return null;
    }

    const cached = metaCache.get(filePath);
    if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) {
        return cached.meta;
    }

    let head: string;
    try {
        head = readHead(filePath, HEAD_BYTES);
    } catch {
        return null;
    }

    let cwd = '';
    let gitBranch = '';
    let title = '';

    const lines = head.split('\n');
    for (const line of lines) {
        if (!line.trim()) continue;
        let record: Record<string, unknown>;
        try {
            const parsed: unknown = JSON.parse(line);
            if (typeof parsed !== 'object' || parsed === null) continue;
            record = parsed as Record<string, unknown>;
        } catch {
            // 最后一行可能被 HEAD_BYTES 截断，属正常情况
            continue;
        }

        if (!cwd && typeof record['cwd'] === 'string') cwd = record['cwd'];
        if (!gitBranch && typeof record['gitBranch'] === 'string') {
            gitBranch = record['gitBranch'];
        }
        if (!title) {
            const text = extractUserText(record);
            if (text && text.trim()) {
                title = text.replace(/\s+/g, ' ').trim().slice(0, 60);
            }
        }
        if (cwd && title) break;
    }

    // 拿不到 cwd 说明这不是一个可用的会话文件
    if (!cwd) return null;

    let messageCount = 0;
    try {
        messageCount = await countLines(filePath);
    } catch {
        messageCount = 0;
    }

    const meta: SessionMeta = {
        sessionId,
        cwd,
        gitBranch,
        title: title || '(无标题会话)',
        messageCount,
        lastActiveAt: stat.mtimeMs,
    };

    metaCache.set(filePath, {
        mtimeMs: stat.mtimeMs,
        size: stat.size,
        meta,
    });
    return meta;
}

// ---------------------------------------------------------------------------
// 目录级扫描
// ---------------------------------------------------------------------------

/** 列出某个项目目录下所有有效会话 */
async function scanProjectDir(
    projectsRoot: string,
    projectId: string,
): Promise<SessionMeta[]> {
    const dir = join(projectsRoot, projectId);
    let files: string[];
    try {
        files = readdirSync(dir);
    } catch {
        return [];
    }

    const out: SessionMeta[] = [];
    for (const file of files) {
        if (!file.endsWith('.jsonl')) continue;
        const sessionId = file.slice(0, -'.jsonl'.length);
        // --resume 只吃 UUID，agent-* 等一律跳过
        if (!UUID_RE.test(sessionId)) continue;

        const meta = await parseSession(join(dir, file), sessionId);
        if (meta) out.push(meta);
    }
    return out;
}

/** 判断某个路径是否落在白名单之内 */
function isAllowed(path: string, roots: readonly string[]): boolean {
    if (roots.length === 0) return true; // 未配置白名单 = 不限制
    return roots.some(
        (root) => path === root || path.startsWith(root.endsWith(sep) ? root : root + sep),
    );
}

export class SessionScanner {
    private readonly projectsRoot: string;
    private readonly projectRoots: readonly string[];

    constructor(claudeConfigDir: string, projectRoots: readonly string[]) {
        this.projectsRoot = join(claudeConfigDir, 'projects');
        this.projectRoots = projectRoots;
    }

    /** 列出所有项目 */
    async listProjects(): Promise<ProjectInfo[]> {
        let dirs: string[];
        try {
            dirs = readdirSync(this.projectsRoot, { withFileTypes: true })
                .filter((d) => d.isDirectory())
                .map((d) => d.name);
        } catch {
            // projects 目录不存在 = 这台机器还没跑过 Claude Code
            return [];
        }

        const projects: ProjectInfo[] = [];
        for (const projectId of dirs) {
            const sessions = await scanProjectDir(this.projectsRoot, projectId);
            if (sessions.length === 0) continue;

            // 同一目录下所有会话的 cwd 应该一致，取第一个即可
            const path = sessions[0]!.cwd;
            if (!isAllowed(path, this.projectRoots)) continue;

            projects.push({
                id: projectId,
                path,
                name: basename(path) || path,
                sessionCount: sessions.length,
                lastActiveAt: Math.max(...sessions.map((s) => s.lastActiveAt)),
            });
        }

        projects.sort((a, b) => b.lastActiveAt - a.lastActiveAt);
        return projects;
    }

    /** 列出某个项目下的会话，按最近活跃排序 */
    async listSessions(projectId: string): Promise<SessionInfo[] | null> {
        const sessions = await scanProjectDir(this.projectsRoot, projectId);
        if (sessions.length === 0) return null;
        if (!isAllowed(sessions[0]!.cwd, this.projectRoots)) return null;

        return sessions
            .sort((a, b) => b.lastActiveAt - a.lastActiveAt)
            .map((s) => ({
                sessionId: s.sessionId,
                title: s.title,
                gitBranch: s.gitBranch,
                messageCount: s.messageCount,
                lastActiveAt: s.lastActiveAt,
            }));
    }

    /**
     * 解析项目 id 对应的真实工作目录。
     * 返回 null 表示项目不存在或不在白名单内 —— 调用方应一律当作 404 处理，
     * 不要把"存在但不允许"和"不存在"区分开，避免泄漏服务器目录结构。
     */
    async resolveProjectPath(projectId: string): Promise<string | null> {
        const sessions = await scanProjectDir(this.projectsRoot, projectId);
        if (sessions.length === 0) return null;
        const path = sessions[0]!.cwd;
        return isAllowed(path, this.projectRoots) ? path : null;
    }

    /** 找到某个 sessionId 所属的项目目录，用于历史消息接口 */
    async findSessionFile(sessionId: string): Promise<string | null> {
        if (!UUID_RE.test(sessionId)) return null;

        let dirs: string[];
        try {
            dirs = readdirSync(this.projectsRoot, { withFileTypes: true })
                .filter((d) => d.isDirectory())
                .map((d) => d.name);
        } catch {
            return null;
        }

        for (const projectId of dirs) {
            const filePath = join(this.projectsRoot, projectId, `${sessionId}.jsonl`);
            const meta = await parseSession(filePath, sessionId);
            if (meta && isAllowed(meta.cwd, this.projectRoots)) {
                return filePath;
            }
        }
        return null;
    }
}

/** 逐行读取 jsonl，供 history 模块复用 */
export async function* readJsonlRecords(
    filePath: string,
): AsyncGenerator<Record<string, unknown>> {
    const rl = createInterface({
        input: createReadStream(filePath),
        crlfDelay: Infinity,
    });
    for await (const line of rl) {
        if (!line.trim()) continue;
        try {
            const parsed: unknown = JSON.parse(line);
            if (typeof parsed === 'object' && parsed !== null) {
                yield parsed as Record<string, unknown>;
            }
        } catch {
            // 单行损坏不影响其余记录
        }
    }
}
