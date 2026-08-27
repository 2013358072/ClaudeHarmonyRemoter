/**
 * 「正在运行」的会话登记表。
 *
 * 判定一个会话是否在运行有两个来源，各自覆盖不同场景：
 *
 * 1. **本服务持有的 runner**（这个模块）—— 精确、无歧义。
 *    手机 attach 上来的会话一定在这里。
 *
 * 2. **会话文件的新鲜度**（scanner 里用 mtime 判断）—— 启发式。
 *    用来覆盖"用户直接在服务器终端敲 claude"的情况，
 *    那种会话我们没有 runner，只能靠 transcript 还在被写入来推断。
 *
 * 第二种有个已知局限：**开着但闲着的会话检测不到**。
 * Claude Code 只在真正干活时写 transcript，用户开了终端却没发消息，
 * 文件就不会更新。做到"精确知道进程是否存活"需要扫进程表并解析 cwd，
 * 跨平台成本高、收益低 —— 用户真正关心的是"哪个在忙"，
 * 而不是"哪个窗口还开着"，所以这个局限是可以接受的。
 */

/** sessionId -> 引用计数。同一会话可能被多个客户端同时 attach */
const active = new Map<string, number>();

/** 登记一个正在运行的会话 */
export function markActive(sessionId: string): void {
    if (!sessionId) return;
    active.set(sessionId, (active.get(sessionId) ?? 0) + 1);
}

/** 注销。计数归零才真正移除 */
export function unmarkActive(sessionId: string): void {
    if (!sessionId) return;
    const n = active.get(sessionId);
    if (n === undefined) return;
    if (n <= 1) {
        active.delete(sessionId);
    } else {
        active.set(sessionId, n - 1);
    }
}

export function isActive(sessionId: string): boolean {
    return active.has(sessionId);
}

/** 当前所有运行中的会话 id，用于调试与状态接口 */
export function activeIds(): string[] {
    return [...active.keys()];
}
