/**
 * Claude 会话驱动器 —— 一个 attach 对应一个实例。
 *
 * 用 @anthropic-ai/claude-agent-sdk 的 query() 拉起本机的 claude 二进制。
 * 注意这**不是**在调 Anthropic 官方 API：认证完全沿用 CLI 自己的配置，
 * 所以 ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN 指向的第三方中转原样生效。
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import { PushableAsyncIterable } from './pushable.js';
import { normalize, errorEvent } from '../protocol/normalize.js';
import type { WireEvent } from '../protocol/wire.js';
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
    /** query() 返回的对象，用于 interrupt */
    private handle: AsyncIterable<unknown> & { interrupt?: () => Promise<void> } = null as never;

    constructor(options: RunnerOptions) {
        this.opts = options;
        this.sessionId = options.resumeSessionId;
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

        try {
            const response = query({
                prompt: this.input as AsyncIterable<never>,
                options: {
                    cwd: opts.cwd,
                    resume: opts.resumeSessionId,
                    permissionMode: opts.permissionMode,
                    abortController: this.abort,
                    env,
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
                    this.sessionId = sessionId;
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
        }
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
        this.input.close();
        this.abort.abort();
    }

    getSessionId(): string | undefined {
        return this.sessionId;
    }
}
