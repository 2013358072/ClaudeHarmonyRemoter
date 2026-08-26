/**
 * 线协议定义 —— 服务端与鸿蒙客户端之间传输的数据结构。
 *
 * 设计原则：**扁平、稳定、ArkTS 友好**。
 *
 * Claude Agent SDK 吐出的 SDKMessage 里，assistant 消息的 content 是
 * Anthropic 的 content block 数组（text / thinking / tool_use 混排），
 * 联合类型嵌套很深。ArkTS 不支持 any、对动态对象和联合类型检查严格，
 * 直接透传会让客户端非常难写。
 *
 * 所以这里统一压平成 WireEvent：一个扁平接口 + kind 判别字段 + 可选字段。
 * 刻意不用可辨识联合类型 —— ArkTS 对联合窄化有限制，
 * 单一接口让客户端只需 `if (e.kind === 'text')` 就能安全取值。
 *
 * 本文件需要与 entry/src/main/ets/net/Protocol.ets 保持同步。
 */

// ============================================================================
// 事件（服务端 → 客户端）
// ============================================================================

export type WireEventKind =
    | 'text'      // 一段文本消息
    | 'thinking'  // 思考过程
    | 'tool'      // 工具调用
    | 'result'    // 一轮对话结束
    | 'error';    // 出错

export type WireRole = 'user' | 'assistant';

export type WireToolStatus = 'running' | 'ok' | 'error';

export interface WireEvent {
    /** 判别字段，客户端按它分支渲染 */
    kind: WireEventKind;
    /** 事件唯一 id，客户端用作列表 key，也用于 tool 事件的状态更新去重 */
    id: string;
    /** 毫秒时间戳 */
    ts: number;

    /** kind='text' 时有效 */
    role?: WireRole;
    /** kind='text' | 'thinking' | 'error' 时有效 */
    text?: string;

    /** kind='tool' 时有效：工具名，如 Read / Bash / Edit */
    toolName?: string;
    /** kind='tool' 时有效：一行摘要，如 "Read src/index.ts" */
    toolSummary?: string;
    /** kind='tool' 时有效 */
    toolStatus?: WireToolStatus;

    /** kind='result' 时有效 */
    ok?: boolean;
    /** kind='result' 时有效：本轮耗时（毫秒） */
    durationMs?: number;
    /** kind='result' 时有效：本轮花费（美元） */
    costUsd?: number;
}

// ============================================================================
// 上行消息（客户端 → 服务端）
// ============================================================================

export type ClientMessageType = 'attach' | 'send' | 'interrupt' | 'detach';

export interface ClientMessage {
    type: ClientMessageType;
    /** type='attach' 时必填 */
    projectId?: string;
    /** type='attach' 时选填。不填=新建会话，填了=续接该会话 */
    sessionId?: string;
    /** type='send' 时必填 */
    text?: string;
}

// ============================================================================
// 下行消息（服务端 → 客户端）
// ============================================================================

export type ServerMessageType =
    | 'attached'   // 会话已就绪，回传真实 sessionId
    | 'event'      // 一条 WireEvent
    | 'thinking'   // Claude 是否正在思考，用于客户端显示加载态
    | 'fatal';     // 致命错误，会话已终止

export interface ServerMessage {
    type: ServerMessageType;
    /** type='attached' 时有效 */
    sessionId?: string;
    /** type='event' 时有效 */
    payload?: WireEvent;
    /** type='thinking' 时有效 */
    value?: boolean;
    /** type='fatal' 时有效 */
    message?: string;
}

// ============================================================================
// HTTP 接口的数据结构
// ============================================================================

export interface ProjectInfo {
    /** Claude Code 的项目目录名，用作 URL 里的 id */
    id: string;
    /** 真实绝对路径，从会话文件内容里读出来的 */
    path: string;
    /** 展示名，取路径最后一段 */
    name: string;
    sessionCount: number;
    lastActiveAt: number;
}

export interface SessionInfo {
    sessionId: string;
    /** 首条用户消息的前 60 字，用作列表标题 */
    title: string;
    gitBranch: string;
    messageCount: number;
    lastActiveAt: number;
}

export interface PairResponse {
    token: string;
    serverName: string;
}
