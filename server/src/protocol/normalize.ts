/**
 * 把 Claude Agent SDK 的 SDKMessage 压平成 WireEvent。
 *
 * 这里刻意全程按 unknown 处理再逐层收窄，不直接依赖 SDK 的类型名：
 * 归一化层的职责就是"隔离上游结构变化"，
 * 如果它自己跟 SDK 类型强耦合，一次 SDK 升级就会同时打穿服务端和客户端。
 * 遇到不认识的结构就跳过，绝不抛异常 —— 一条消息解析失败不该中断整个会话。
 */

import type { WireEvent, WireToolStatus } from './wire.js';

// ---------------------------------------------------------------------------
// unknown 收窄的小工具
// ---------------------------------------------------------------------------

type Dict = Record<string, unknown>;

function isDict(v: unknown): v is Dict {
    return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function str(v: unknown): string | undefined {
    return typeof v === 'string' ? v : undefined;
}

function num(v: unknown): number | undefined {
    return typeof v === 'number' && Number.isFinite(v) ? v : undefined;
}

/** 截断并把换行压成空格，用于生成单行摘要 */
function oneLine(s: string, max: number): string {
    const flat = s.replace(/\s+/g, ' ').trim();
    return flat.length <= max ? flat : `${flat.slice(0, max - 1)}…`;
}

// ---------------------------------------------------------------------------
// 事件 id
// ---------------------------------------------------------------------------

let seq = 0;

/**
 * 生成事件 id。
 *
 * 优先用上游给的稳定 id（tool_use 的 id、消息的 uuid），
 * 这样 tool 事件的 running → ok/error 状态更新能在客户端对上号。
 * 拿不到就退化成自增序号。
 */
function eventId(stable: string | undefined, suffix?: string): string {
    if (stable) return suffix ? `${stable}:${suffix}` : stable;
    seq += 1;
    return `ev-${seq}`;
}

// ---------------------------------------------------------------------------
// 工具摘要
// ---------------------------------------------------------------------------

/**
 * 给工具调用生成一行人类可读的摘要。
 * 手机屏幕窄，展示完整的 input JSON 没有意义。
 */
export function summarizeTool(name: string, input: unknown): string {
    if (!isDict(input)) return name;

    const filePath = str(input['file_path']);
    const pattern = str(input['pattern']);
    const command = str(input['command']);
    const description = str(input['description']);
    const url = str(input['url']);
    const query = str(input['query']);

    switch (name) {
        case 'Read':
        case 'Write':
        case 'NotebookEdit':
            return filePath ? `${name} ${filePath}` : name;
        case 'Edit':
            return filePath ? `Edit ${filePath}` : name;
        case 'Bash':
            return command ? oneLine(command, 80) : name;
        case 'Grep':
            return pattern ? `Grep ${oneLine(pattern, 60)}` : name;
        case 'Glob':
            return pattern ? `Glob ${pattern}` : name;
        case 'Task':
        case 'Agent':
            return description ? `Task ${oneLine(description, 60)}` : name;
        case 'WebFetch':
            return url ? `WebFetch ${oneLine(url, 60)}` : name;
        case 'WebSearch':
            return query ? `WebSearch ${oneLine(query, 60)}` : name;
        default: {
            // 未知工具：挑第一个字符串参数当摘要，比只显示工具名有用
            for (const value of Object.values(input)) {
                const s = str(value);
                if (s) return `${name} ${oneLine(s, 60)}`;
            }
            return name;
        }
    }
}

// ---------------------------------------------------------------------------
// Skill 注入的识别
// ---------------------------------------------------------------------------

/**
 * skill 被调用时，Claude Code 会把整份 SKILL.md 当作一条用户消息注入。
 * 实测最长的一条有 91114 个字符 —— 原样显示会在手机上糊出一整屏墙。
 *
 * 它的首行形如：
 *   Base directory for this skill: C:\...\bundled-skills\<hash>\claude-api
 * 路径最后一段就是 skill 名。
 */
const SKILL_MARKER = 'Base directory for this skill:';

/** 认出 skill 注入就返回它的名字，否则返回 undefined */
function detectSkill(text: string): string | undefined {
    if (!text.startsWith(SKILL_MARKER)) return undefined;
    const firstLine = text.slice(0, text.indexOf('\n') >= 0 ? text.indexOf('\n') : text.length);
    const dir = firstLine.slice(SKILL_MARKER.length).trim();
    if (!dir) return undefined;
    // 兼容两种分隔符：服务端可能是 Linux，skill 路径却来自 Windows 客户端
    const parts = dir.split(/[\\/]/).filter((p) => p.length > 0);
    return parts.length > 0 ? parts[parts.length - 1] : undefined;
}

/**
 * 其他不该出现在对话里的注入内容。
 *
 * system-reminder 是 Claude Code 给模型的旁白，用户从没输入过它；
 * command-name/command-message 是斜杠命令的内部结构。
 * 这些混在消息流里只会干扰阅读。
 */
function isInjectedNoise(text: string): boolean {
    const t = text.trimStart();
    return (
        t.startsWith('<system-reminder>')
        || t.startsWith('<command-name>')
        || t.startsWith('<command-message>')
        || t.startsWith('<local-command-stdout>')
    );
}

/**
 * 把一段文本变成事件：先过滤注入噪声，再识别 skill，最后才当普通文本。
 * 返回 null 表示这段内容不该出现在对话流里。
 */
function makeUserTextEvent(
    text: string,
    role: 'user' | 'assistant',
    id: string,
    ts: number,
): WireEvent | null {
    if (text.trim().length === 0) return null;

    // 只有用户侧的消息会被注入，模型输出原样保留
    if (role === 'user') {
        const skill = detectSkill(text);
        if (skill) {
            return { kind: 'skill', id, ts, skillName: skill };
        }
        if (isInjectedNoise(text)) return null;
    }

    return { kind: 'text', id, ts, role, text };
}

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------

export interface NormalizeResult {
    events: WireEvent[];
    /** SDK 在 system/init 里回传的真实 session id */
    sessionId?: string;
}

/**
 * 把一条 SDKMessage 转成零到多条 WireEvent。
 *
 * 一条 assistant 消息可能同时含 thinking、text 和多个 tool_use，
 * 所以返回的是数组。
 */
export function normalize(message: unknown): NormalizeResult {
    const events: WireEvent[] = [];
    const ts = Date.now();

    if (!isDict(message)) return { events };

    const type = str(message['type']);
    const sessionId = str(message['session_id']);

    switch (type) {
        case 'system':
            // init 消息只用来拿 session id，本身不产生可见事件
            return { events, sessionId };

        case 'assistant':
        case 'user': {
            const role = type === 'assistant' ? 'assistant' : 'user';
            const inner = message['message'];
            if (!isDict(inner)) return { events, sessionId };

            const content = inner['content'];

            // content 可能是纯字符串（用户消息常见）
            const asText = str(content);
            if (asText !== undefined) {
                const e = makeUserTextEvent(asText, role, eventId(str(message['uuid'])), ts);
                if (e) events.push(e);
                return { events, sessionId };
            }

            if (!Array.isArray(content)) return { events, sessionId };

            for (let i = 0; i < content.length; i += 1) {
                const block = content[i];
                if (!isDict(block)) continue;
                const blockType = str(block['type']);
                const uuid = str(message['uuid']);

                if (blockType === 'text') {
                    const text = str(block['text']);
                    if (text) {
                        const e = makeUserTextEvent(text, role, eventId(uuid, `t${i}`), ts);
                        if (e) events.push(e);
                    }
                } else if (blockType === 'thinking') {
                    const text = str(block['thinking']);
                    // 思考内容可能被配置成不返回，此时是空串，没必要下发
                    if (text && text.trim().length > 0) {
                        events.push({
                            kind: 'thinking',
                            id: eventId(uuid, `k${i}`),
                            ts,
                            text,
                        });
                    }
                } else if (blockType === 'tool_use') {
                    const name = str(block['name']) ?? 'unknown';
                    events.push({
                        kind: 'tool',
                        // 用 tool_use 的 id，好让后续 tool_result 更新到同一条
                        id: eventId(str(block['id']), undefined),
                        ts,
                        toolName: name,
                        toolSummary: summarizeTool(name, block['input']),
                        toolStatus: 'running',
                    });
                } else if (blockType === 'tool_result') {
                    const toolUseId = str(block['tool_use_id']);
                    if (!toolUseId) continue;
                    const isError = block['is_error'] === true;
                    const status: WireToolStatus = isError ? 'error' : 'ok';
                    events.push({
                        kind: 'tool',
                        // 复用 tool_use 的 id，客户端按 id 覆盖已有条目
                        id: toolUseId,
                        ts,
                        toolStatus: status,
                    });
                }
            }
            return { events, sessionId };
        }

        case 'result': {
            const isError = message['is_error'] === true;
            const subtype = str(message['subtype']);
            events.push({
                kind: 'result',
                id: eventId(undefined),
                ts,
                ok: !isError && subtype === 'success',
                durationMs: num(message['duration_ms']) ?? 0,
                costUsd: num(message['total_cost_usd']) ?? 0,
            });
            return { events, sessionId };
        }

        default:
            // stream_event 等其他类型首版不处理
            return { events, sessionId };
    }
}

/** 构造一条错误事件 */
export function errorEvent(message: string): WireEvent {
    return {
        kind: 'error',
        id: eventId(undefined),
        ts: Date.now(),
        text: message,
    };
}
