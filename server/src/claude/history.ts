/**
 * 把会话的 jsonl 转成 WireEvent 列表，供客户端展示历史消息。
 *
 * 会话文件里每条记录的形状和 SDKMessage 基本一致（都是
 * `{type, message:{role, content}, uuid, ...}`），所以直接复用
 * normalize()，不另写一套解析逻辑 —— 两边的渲染结果也因此保证一致。
 */

import { readJsonlTail } from './scanner.js';
import { normalize } from '../protocol/normalize.js';
import type { WireEvent } from '../protocol/wire.js';

/**
 * 读取尾部多少字节。
 *
 * 按实测语料，200 条消息大约几百 KB，2 MB 有充分余量；
 * 而最大的会话文件有 6.8 MB，从头读完再切片是三倍以上的浪费。
 * 万一尾部不足 limit 条，少显示几条历史远比让用户等着强。
 */
const TAIL_BYTES = 2 * 1024 * 1024;

export interface HistoryOptions {
    /** 最多返回多少条事件，取最新的 */
    limit: number;
}

/**
 * 读取历史消息。
 *
 * 只保留主线消息：子会话（isSidechain）是 Task 工具内部的对话，
 * 混进主时间线会让手机上的会话记录变得难以阅读。
 */
export async function loadHistory(
    filePath: string,
    options: HistoryOptions,
): Promise<WireEvent[]> {
    const events: WireEvent[] = [];

    for await (const record of readJsonlTail(filePath, TAIL_BYTES)) {
        if (record['isSidechain'] === true) continue;

        const { events: produced } = normalize(record);
        for (const e of produced) events.push(e);
    }

    // 历史记录里 result 事件没有意义（是当时那一轮的耗时/花费），过滤掉
    const filtered = events.filter((e) => e.kind !== 'result');

    const merged = mergeToolEvents(filtered);

    return merged.length > options.limit
        ? merged.slice(merged.length - options.limit)
        : merged;
}

/**
 * 合并同一 id 的 tool 事件。
 *
 * normalize() 对一次工具调用会产出两条：tool_use 那条带名字和摘要、状态 running，
 * tool_result 那条只带最终状态。实时流里客户端按 id 覆盖即可（要的就是那个
 * "先转圈再出结果"的效果），但历史是批量返回的，服务端这边直接合并成一条，
 * 客户端拿到就能直接渲染，limit 的语义也才对得上（N 条 = N 个可见条目）。
 */
function mergeToolEvents(events: WireEvent[]): WireEvent[] {
    const out: WireEvent[] = [];
    /** tool 事件 id -> 它在 out 里的下标 */
    const toolIndex = new Map<string, number>();

    for (const event of events) {
        if (event.kind !== 'tool') {
            out.push(event);
            continue;
        }

        const existing = toolIndex.get(event.id);
        if (existing === undefined) {
            out.push(event);
            toolIndex.set(event.id, out.length - 1);
            continue;
        }

        // 后到的那条只带状态，把状态并到已有条目上，保留名字和摘要
        const target = out[existing]!;
        if (event.toolStatus) target.toolStatus = event.toolStatus;
        if (event.toolName) target.toolName = event.toolName;
        if (event.toolSummary) target.toolSummary = event.toolSummary;
    }

    return out;
}
