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

import { readdirSync, statSync, createReadStream } from 'node:fs';
import { join, basename, sep } from 'node:path';
import { createInterface } from 'node:readline';
import type { ProjectInfo, SessionInfo } from '../protocol/wire.js';
import { isActive } from './activeSessions.js';

/**
 * transcript 多久没更新就不算"正在运行"。
 *
 * Claude Code 干活时会持续写 transcript，所以文件新鲜度是个不错的
 * 活跃信号。90 秒是权衡：太短会让思考中的长任务被误判为已停，
 * 太长则刚结束的会话还挂着绿点。
 */
const FRESH_WINDOW_MS = 90 * 1000;

/** UUID v4 形态，与 Claude Code 对 --resume 的要求一致 */
const UUID_RE =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * 扫描文件头时最多看这么多行。
 *
 * 不用"读固定字节数"那种写法：cwd 出现在第几行没有任何保证 ——
 * 实测有的会话开头是一串不带 cwd 的 queue-operation 记录，
 * 窗口定小了就会解析失败，把整个会话判成无效。
 * 流式逐行读、拿到需要的字段立刻停，既没有窗口大小的赌注，
 * 正常情况下也只读头一两行。
 */
const HEAD_MAX_LINES = 400;

/**
 * 找自定义标题时读的尾部字节数。
 *
 * renameSession 是追加写的，标题在文件末尾。取 64KB 是因为重命名
 * 记录本身很短，而整文件读一遍对 6.9MB 的大会话开销不可接受。
 */
const TAIL_TITLE_BYTES = 64 * 1024;

/** 扫描项目目录的并发上限 */
const SCAN_CONCURRENCY = 12;

interface SessionMeta {
    sessionId: string;
    cwd: string;
    gitBranch: string;
    title: string;
    /** -1 表示还没数过。项目列表用不到这个值，所以默认不算 */
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
    needCount: boolean = false,
): Promise<SessionMeta | null> {
    let stat;
    try {
        stat = statSync(filePath);
    } catch {
        return null;
    }

    const cached = metaCache.get(filePath);
    if (cached && cached.mtimeMs === stat.mtimeMs && cached.size === stat.size) {
        // 缓存里没数过行数、而这次又要用，就补算一次并回填
        if (needCount && cached.meta.messageCount < 0) {
            try {
                cached.meta.messageCount = await countLines(filePath);
            } catch {
                cached.meta.messageCount = 0;
            }
        }
        return cached.meta;
    }

    let cwd = '';
    let gitBranch = '';
    let title = '';
    /**
     * 用户通过 /rename 或我们的重命名接口设置的标题。
     * 它优先于「首条用户消息」—— 用户特意改过名字，就该显示那个。
     */
    let customTitle = '';

    // 逐行流式扫描，拿齐 cwd 和标题就停 —— 绝大多数会话第一行就够了
    try {
        let seen = 0;
        for await (const record of readJsonlRecords(filePath)) {
            seen += 1;
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
            if ((cwd && title) || seen >= HEAD_MAX_LINES) break;
        }
    } catch {
        // 文件可能正被写入或已被删除，交给调用方跳过
        return null;
    }

    // 重命名是**追加**写的，标题落在文件末尾，扫头部读不到。
    // 所以单独读一小段尾巴。窗口取 64KB：重命名记录很短，
    // 而整文件读一遍对 6.9MB 的会话是不可接受的开销。
    try {
        for await (const record of readJsonlTail(filePath, TAIL_TITLE_BYTES)) {
            const ct = record['customTitle'];
            if (typeof ct === 'string' && ct.trim().length > 0) {
                // 不 break：同一会话可能被改名多次，最后一条才是当前标题
                customTitle = ct.trim().slice(0, 60);
            }
        }
    } catch {
        // 读不到就退化成用首条用户消息当标题，不影响会话可用
    }

    // 拿不到 cwd 说明这不是一个可用的会话文件
    if (!cwd) return null;

    // 数行数要把整个文件流一遍。项目列表根本不显示这个值
    // （它显示的是"几个会话"而不是"几条消息"），
    // 所以默认跳过 —— 这一项此前让 /api/projects 白读了几十 MB。
    let messageCount = -1;
    if (needCount) {
        try {
            messageCount = await countLines(filePath);
        } catch {
            messageCount = 0;
        }
    }

    const meta: SessionMeta = {
        sessionId,
        cwd,
        gitBranch,
        title: customTitle || title || '(无标题会话)',
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
    needCount: boolean = false,
): Promise<SessionMeta[]> {
    const dir = join(projectsRoot, projectId);
    let files: string[];
    try {
        files = readdirSync(dir);
    } catch {
        return [];
    }

    const targets: string[] = [];
    for (const file of files) {
        if (!file.endsWith('.jsonl')) continue;
        const sessionId = file.slice(0, -'.jsonl'.length);
        // --resume 只吃 UUID，agent-* 等一律跳过
        if (!UUID_RE.test(sessionId)) continue;
        targets.push(sessionId);
    }

    // 同目录下的会话彼此独立，并行解析
    const metas = await Promise.all(
        targets.map((sessionId) =>
            parseSession(join(dir, `${sessionId}.jsonl`), sessionId, needCount),
        ),
    );
    return metas.filter((m): m is SessionMeta => m !== null);
}

/**
 * 带并发上限地并行跑一批任务。
 *
 * 不用裸 Promise.all：110 个项目同时打开文件句柄会把 IO 打满，
 * 反而比适度并发更慢，极端情况还可能触发 EMFILE。
 */
async function mapWithLimit<T, R>(
    items: T[],
    limit: number,
    fn: (item: T) => Promise<R>,
): Promise<R[]> {
    const out: R[] = new Array(items.length);
    let next = 0;
    const workers: Promise<void>[] = [];
    const n = Math.min(limit, items.length);

    for (let i = 0; i < n; i += 1) {
        workers.push(
            (async () => {
                for (;;) {
                    const idx = next;
                    next += 1;
                    if (idx >= items.length) return;
                    out[idx] = await fn(items[idx]!);
                }
            })(),
        );
    }
    await Promise.all(workers);
    return out;
}

/**
 * 会话是否正在运行。
 *
 * 注意这个判断**不能进 metaCache** —— 它和当前时间相关，
 * 缓存住会让绿点永远停在第一次扫描时的状态。
 */
function isRunning(sessionId: string, lastActiveAt: number): boolean {
    if (isActive(sessionId)) {
        return true;
    }
    return Date.now() - lastActiveAt < FRESH_WINDOW_MS;
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

        // 并行扫描各项目目录。needCount=false：项目列表不显示消息条数
        const scanned = await mapWithLimit(dirs, SCAN_CONCURRENCY, (projectId) =>
            scanProjectDir(this.projectsRoot, projectId, false).then((sessions) => ({
                projectId,
                sessions,
            })),
        );

        const projects: ProjectInfo[] = [];
        for (const entry of scanned) {
            const projectId = entry.projectId;
            const sessions = entry.sessions;
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
                running: sessions.some((s) => isRunning(s.sessionId, s.lastActiveAt)),
            });
        }

        // 运行中的排最前，其余按最近活跃
        projects.sort((a, b) => {
            if (a.running !== b.running) {
                return a.running ? -1 : 1;
            }
            return b.lastActiveAt - a.lastActiveAt;
        });
        return projects;
    }

    /** 列出某个项目下的会话，按最近活跃排序 */
    async listSessions(projectId: string): Promise<SessionInfo[] | null> {
        // needCount=true：会话列表会显示「N 条」，这里确实要数
        const sessions = await scanProjectDir(this.projectsRoot, projectId, true);
        if (sessions.length === 0) return null;
        if (!isAllowed(sessions[0]!.cwd, this.projectRoots)) return null;

        return sessions
            .map((s): SessionInfo => ({
                sessionId: s.sessionId,
                title: s.title,
                gitBranch: s.gitBranch,
                messageCount: s.messageCount,
                lastActiveAt: s.lastActiveAt,
                running: isRunning(s.sessionId, s.lastActiveAt),
            }))
            // 运行中的排最前，其余按最近活跃
            .sort((a, b) => {
                if (a.running !== b.running) {
                    return a.running ? -1 : 1;
                }
                return b.lastActiveAt - a.lastActiveAt;
            });
    }

    /**
     * 解析项目 id 对应的真实工作目录。
     * 返回 null 表示项目不存在或不在白名单内 —— 调用方应一律当作 404 处理，
     * 不要把"存在但不允许"和"不存在"区分开，避免泄漏服务器目录结构。
     */
    async resolveProjectPath(projectId: string): Promise<string | null> {
        const sessions = await scanProjectDir(this.projectsRoot, projectId, false);
        if (sessions.length === 0) return null;
        const path = sessions[0]!.cwd;
        return isAllowed(path, this.projectRoots) ? path : null;
    }

    /**
     * 找到某个 sessionId 的真实工作目录（不是 .claude/projects 下的编码目录）。
     *
     * renameSession 的 dir 参数要的是**项目路径本身**，
     * 编码成 projects 下的目录名由 SDK 自己做 —— 传编码后的路径会报
     * "Session ... not found in project directory"。
     */
    async findSessionCwd(sessionId: string): Promise<string | null> {
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
            const meta = await parseSession(filePath, sessionId, false);
            if (meta && isAllowed(meta.cwd, this.projectRoots)) {
                return meta.cwd;
            }
        }
        return null;
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
            const meta = await parseSession(filePath, sessionId, false);
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
    const stream = createReadStream(filePath);
    const rl = createInterface({ input: stream, crlfDelay: Infinity });
    try {
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
    } finally {
        // 调用方 break 提前退出时，生成器的 return() 会走到这里。
        // 没有这段清理，每次提前中断都会漏掉一个文件句柄和 readline 实例 ——
        // 对持续增长、每次都缓存未命中的大文件尤其致命。
        rl.close();
        stream.destroy();
    }
}

/**
 * 只读文件尾部的若干字节并逐行解析。
 *
 * 历史消息接口只要最后 N 条，从头读完再切片是纯浪费 ——
 * 实测最大的会话文件有 6.8 MB，而 200 条消息通常只占几百 KB。
 *
 * 第一行大概率被截断，直接丢弃。文件比 tailBytes 小就整篇读。
 */
export async function* readJsonlTail(
    filePath: string,
    tailBytes: number,
): AsyncGenerator<Record<string, unknown>> {
    let size = 0;
    try {
        size = statSync(filePath).size;
    } catch {
        return;
    }

    const start = size > tailBytes ? size - tailBytes : 0;
    const stream = createReadStream(filePath, { start });
    const rl = createInterface({ input: stream, crlfDelay: Infinity });

    try {
        let first = true;
        for await (const line of rl) {
            // 从中间切进去的第一行必然不完整
            if (first) {
                first = false;
                if (start > 0) continue;
            }
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
    } finally {
        rl.close();
        stream.destroy();
    }
}
