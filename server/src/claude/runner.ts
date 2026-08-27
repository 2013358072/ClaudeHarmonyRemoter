/**
 * Claude 会话驱动器 —— 一个 attach 对应一个实例。
 *
 * 用 @anthropic-ai/claude-agent-sdk 的 query() 拉起本机的 claude 二进制。
 * 注意这**不是**在调 Anthropic 官方 API：认证完全沿用 CLI 自己的配置，
 * 所以 ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN 指向的第三方中转原样生效。
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import { PushableAsyncIterable } from './pushable.js';
import { markActive, unmarkActive } from './activeSessions.js';
import { normalize, errorEvent, summarizeTool } from '../protocol/normalize.js';
import type {
    WireEvent,
    PermissionRequest,
    PermissionDecision,
} from '../protocol/wire.js';
import type { PermissionMode } from '../config.js';

/**
 * Claude Code 的 `--resume` 选择器会隐藏 entrypoint 属于
 * {sdk-cli, sdk-ts, sdk-py} 的会话，而 Agent SDK 默认就会把
 * CLAUDE_CODE_ENTRYPOINT 设成 sdk-ts。
 *
 * 不覆盖的话，手机上建的会话在服务器终端敲 `claude --resume` 时**看不见**，
 * 用户会以为会话丢了。这里换成一个自定义值绕开那个过滤集合。
 */
const ENTRYPOINT = 'harmony-remote';

/**
 * 权限请求的兜底超时。
 *
 * SDK 文档明确写着权限提示"没有 park deadline" —— 不回复就永久阻塞。
 * 正常情况下客户端断开时我们会立刻拒绝掉所有待决请求，
 * 这个超时只是防止出现谁也没想到的第三种情况让 runner 变成僵尸。
 * 取值偏大，是因为人真的可能把手机放下几分钟再回来。
 */
const PERMISSION_TIMEOUT_MS = 30 * 60 * 1000;

/** 一条待决的权限请求 */
interface PendingPermission {
    request: PermissionRequest;
    /** 兑现 canUseTool 返回的那个 Promise */
    settle: (decision: PermissionDecision) => void;
    timer: NodeJS.Timeout;
}

/** 把工具参数渲染成可读文本，供用户判断该不该批准 */
function renderDetail(toolName: string, input: Record<string, unknown>): string {
    // Bash 最需要看全文 —— 摘要截断过的命令不足以做安全判断
    const command = input['command'];
    if (toolName === 'Bash' && typeof command === 'string') {
        return command;
    }
    const summary = summarizeTool(toolName, input);
    // 摘要已经包含关键信息时就不再堆 JSON，手机屏幕装不下
    if (summary !== toolName) {
        return summary;
    }
    try {
        return JSON.stringify(input, null, 2).slice(0, 1200);
    } catch {
        return '';
    }
}

export interface RunnerOptions {
    /** 项目工作目录 */
    cwd: string;
    /** 要续接的会话 id；不传则新建会话 */
    resumeSessionId?: string;
    permissionMode: PermissionMode;
    /**
     * claude 可执行文件路径。留空则由 SDK 自己在 PATH 里找。
     *
     * Linux 上通常不用配。Windows 上必须配 —— SDK 默认会去 spawn 无扩展名的
     * claude shell 脚本，报 `spawn UNKNOWN`（errno -4094）。
     */
    executablePath?: string;
    /** 每产生一条可展示事件时调用 */
    onEvent: (event: WireEvent) => void;
    /** Claude 开始/结束思考时调用，供客户端显示加载态 */
    onThinking: (thinking: boolean) => void;
    /** 拿到真实 session id 时调用（新建会话时这是唯一的获知途径） */
    onSessionId: (sessionId: string) => void;
    /** Claude 要调用工具、需要用户批准时调用 */
    onPermissionRequest: (request: PermissionRequest) => void;
    /** 权限请求已失效（超时/会话结束），通知客户端收起弹窗 */
    onPermissionClosed: (requestId: string) => void;
    /** 会话因故终止 */
    onFatal: (message: string) => void;
}

export class ClaudeRunner {
    private readonly opts: RunnerOptions;
    private readonly input = new PushableAsyncIterable<unknown>();
    private readonly abort = new AbortController();

    private sessionId: string | undefined;
    private started = false;
    private stopped = false;
    /** requestId -> 待决请求 */
    private pending = new Map<string, PendingPermission>();
    /**
     * 用户勾了「总是允许」的工具，以及 SDK 给出的对应权限更新。
     *
     * SDK 的 suggestions 是"把这条规则加进会话级权限"的指令，
     * 返回给它之后本会话内同类调用就不会再问。但 SDK 只在**首次**询问时
     * 给 suggestions，所以要自己记住，后续同名工具直接放行。
     */
    private remembered = new Map<string, unknown[]>();
    /** query() 返回的对象，用于 interrupt */
    private handle: AsyncIterable<unknown> & { interrupt?: () => Promise<void> } = null as never;

    constructor(options: RunnerOptions) {
        this.opts = options;
        this.sessionId = options.resumeSessionId;
        // 续接已有会话时 id 一开始就知道，立刻登记为运行中；
        // 新建会话要等 SDK 回传 id，见 run() 里的 onSessionId 分支
        if (this.sessionId) {
            markActive(this.sessionId);
        }
    }

    /** 启动会话。立即返回，消息通过回调异步送出 */
    start(): void {
        if (this.started) return;
        this.started = true;
        void this.run();
    }

    private async run(): Promise<void> {
        const { opts } = this;

        // 复制当前进程环境（中转配置就在这里面），只覆盖 entrypoint
        const env: Record<string, string> = {};
        for (const [k, v] of Object.entries(process.env)) {
            if (typeof v === 'string') env[k] = v;
        }
        env['CLAUDE_CODE_ENTRYPOINT'] = ENTRYPOINT;

        console.log(
            `[runner] 启动会话 cwd=${opts.cwd} permissionMode=${opts.permissionMode}` +
                `${opts.resumeSessionId ? ` resume=${opts.resumeSessionId}` : ''}`,
        );

        try {
            const response = query({
                prompt: this.input as AsyncIterable<never>,
                options: {
                    cwd: opts.cwd,
                    resume: opts.resumeSessionId,
                    permissionMode: opts.permissionMode,
                    abortController: this.abort,
                    env,
                    canUseTool: this.canUseTool,
                    ...(opts.executablePath
                        ? { pathToClaudeCodeExecutable: opts.executablePath }
                        : {}),
                } as never,
            });

            this.handle = response as typeof this.handle;

            for await (const message of response) {
                if (this.stopped) break;

                const { events, sessionId } = normalize(message);

                // 新建会话时，真实 id 是在 system/init 消息里才出现的
                if (sessionId && sessionId !== this.sessionId) {
                    // 换 id 时要把旧的注销掉，否则运行中列表会留下幽灵条目
                    if (this.sessionId) {
                        unmarkActive(this.sessionId);
                    }
                    this.sessionId = sessionId;
                    markActive(sessionId);
                    opts.onSessionId(sessionId);
                }

                for (const event of events) {
                    // result 事件代表这一轮结束，思考态随之关闭
                    if (event.kind === 'result') opts.onThinking(false);
                    opts.onEvent(event);
                }
            }
        } catch (e) {
            if (this.stopped || this.abort.signal.aborted) {
                // 主动停止导致的异常，不当作错误
                return;
            }
            const message = e instanceof Error ? e.message : String(e);
            console.error('[runner] 会话出错:', e);
            opts.onEvent(errorEvent(message));
            opts.onFatal(message);
        } finally {
            opts.onThinking(false);
            // 消息循环结束后不会再有人来回答，留着只会挂死 SDK 那侧
            this.denyAllPending();
        }
    }

    // -------------------------------------------------------------------------
    // 权限交互
    // -------------------------------------------------------------------------

    /**
     * SDK 在每次工具调用前回调这里。
     *
     * 铁律：**这个 Promise 必须兑现**。SDK 文档写明权限提示没有超时机制，
     * 返回 null 或永不 resolve 会让工具永久阻塞、整个会话卡死。
     * 所以下面每一条分支——包括异常和中止——都必须走到 settle。
     *
     * 用箭头函数是为了绑定 this，SDK 会脱离实例直接调用它。
     */
    private canUseTool = (
        toolName: string,
        input: Record<string, unknown>,
        options: {
            signal: AbortSignal;
            suggestions?: unknown[];
            title?: string;
            displayName?: string;
            description?: string;
            requestId: string;
            toolUseID: string;
        },
    ): Promise<unknown> => {
        // 会话已停：立刻拒绝，别让 SDK 干等
        if (this.stopped) {
            return Promise.resolve({
                behavior: 'deny',
                message: '会话已结束',
            });
        }

        // 用户之前对这个工具选过「总是允许」
        const remembered = this.remembered.get(toolName);
        if (remembered) {
            return Promise.resolve({
                behavior: 'allow',
                updatedPermissions: remembered,
            });
        }

        const suggestions = options.suggestions;
        const canRemember = Array.isArray(suggestions) && suggestions.length > 0;

        const displayName = options.displayName ?? toolName;
        const request: PermissionRequest = {
            id: options.requestId,
            toolName,
            // SDK 说 title 是渲染好的完整提示句，优先用它 —— 自己按工具名拼
            // 措辞容易和 Claude Code 本体不一致。但实测它经常是 undefined
            // （description 里反而带着目标文件名），所以兜底不能省。
            title: options.title ?? `Claude 想要使用 ${displayName}`,
            displayName,
            description: options.description ?? '',
            detail: renderDetail(toolName, input),
            canRemember,
        };

        console.log(`[runner] 请求权限 ${toolName} (${options.requestId})`);

        return new Promise((resolve) => {
            let done = false;
            const settle = (decision: PermissionDecision): void => {
                if (done) return;
                done = true;
                this.pending.delete(options.requestId);
                clearTimeout(timer);

                console.log(`[runner] 权限 ${toolName} -> ${decision}`);

                if (decision === 'deny') {
                    resolve({
                        behavior: 'deny',
                        message: '用户在手机上拒绝了这次操作',
                    });
                    return;
                }
                if (decision === 'always' && canRemember) {
                    this.remembered.set(toolName, suggestions);
                    resolve({ behavior: 'allow', updatedPermissions: suggestions });
                    return;
                }
                resolve({ behavior: 'allow' });
            };

            // 兜底超时，防止出现意料之外的路径把 runner 挂成僵尸
            const timer = setTimeout(() => {
                console.warn(`[runner] 权限请求 ${options.requestId} 超时，按拒绝处理`);
                this.opts.onPermissionClosed(options.requestId);
                settle('deny');
            }, PERMISSION_TIMEOUT_MS);

            // 用户按了「停止」会触发 abort，此时也要放行这个 Promise
            options.signal.addEventListener(
                'abort',
                () => {
                    this.opts.onPermissionClosed(options.requestId);
                    settle('deny');
                },
                { once: true },
            );

            this.pending.set(options.requestId, { request, settle, timer });
            this.opts.onPermissionRequest(request);
        });
    };

    /** 客户端回复了某条权限请求 */
    resolvePermission(requestId: string, decision: PermissionDecision): boolean {
        const entry = this.pending.get(requestId);
        if (!entry) return false;
        entry.settle(decision);
        return true;
    }

    /** 当前所有待决请求，用于重连后补发 */
    listPending(): PermissionRequest[] {
        return [...this.pending.values()].map((p) => p.request);
    }

    /** 全部拒绝掉待决请求。会话结束或客户端断开时必须调用 */
    private denyAllPending(): void {
        for (const entry of [...this.pending.values()]) {
            entry.settle('deny');
        }
        this.pending.clear();
    }

    /** 发一条用户消息 */
    send(text: string): void {
        if (this.stopped) return;
        this.opts.onThinking(true);
        this.input.push({
            type: 'user',
            message: { role: 'user', content: text },
            parent_tool_use_id: null,
            session_id: this.sessionId ?? '',
        });
    }

    /** 打断当前这一轮 */
    async interrupt(): Promise<void> {
        if (this.stopped) return;
        // 打断时若正卡在权限确认上，先把弹窗关掉并拒绝，
        // 否则手机上会留着一个已经没有意义的确认框
        for (const entry of [...this.pending.values()]) {
            this.opts.onPermissionClosed(entry.request.id);
        }
        this.denyAllPending();
        try {
            await this.handle?.interrupt?.();
        } catch (e) {
            console.warn('[runner] 打断失败:', e);
        }
        this.opts.onThinking(false);
    }

    /** 结束会话并释放资源 */
    stop(): void {
        if (this.stopped) return;
        this.stopped = true;
        if (this.sessionId) {
            unmarkActive(this.sessionId);
        }
        // 顺序要紧：先把待决权限全部拒掉再 abort。
        // 否则 SDK 那边还挂着未兑现的 Promise，abort 不一定能把它唤醒。
        this.denyAllPending();
        this.input.close();
        this.abort.abort();
    }

    getSessionId(): string | undefined {
        return this.sessionId;
    }
}
