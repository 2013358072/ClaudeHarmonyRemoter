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
    | 'skill'     // 引用了某个 skill（正文已折叠）
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

    /** kind='skill' 时有效：skill 名称，如 claude-api */
    skillName?: string;

    /** kind='result' 时有效 */
    ok?: boolean;
    /** kind='result' 时有效：本轮耗时（毫秒） */
    durationMs?: number;
    /** kind='result' 时有效：本轮花费（美元） */
    costUsd?: number;
}

// ============================================================================
// 权限请求
// ============================================================================

/**
 * Claude 想调用工具时向手机发起的确认请求。
 *
 * 字段大部分直接来自 SDK 的 canUseTool 回调 —— 它已经把提示语渲染好了
 * （title / displayName / description），不需要我们从工具名和参数硬拼，
 * 拼出来的措辞还容易和 Claude Code 本体不一致。
 */
export interface PermissionRequest {
    /** SDK 的 requestId，回复时必须原样带回 */
    id: string;
    toolName: string;
    /** 主提示句，如 "Claude wants to read foo.txt" */
    title: string;
    /** 短名词，如 "Read file"，适合按钮和紧凑 UI */
    displayName: string;
    /** 副标题，说明这次授权的影响范围 */
    description: string;
    /** 工具参数的可读摘要，如完整的 bash 命令 */
    detail: string;
    /** 是否支持「总是允许」。SDK 给了 suggestions 才为真 */
    canRemember: boolean;
}

/** 用户的决定 */
export type PermissionDecision = 'allow' | 'always' | 'deny';

// ============================================================================
// 上行消息（客户端 → 服务端）
// ============================================================================

export type ClientMessageType =
    | 'attach'
    | 'send'
    | 'interrupt'
    | 'detach'
    | 'permission_response';

export interface ClientMessage {
    type: ClientMessageType;
    /** type='attach' 时必填 */
    projectId?: string;
    /** type='attach' 时选填。不填=新建会话，填了=续接该会话 */
    sessionId?: string;
    /** type='send' 时必填 */
    text?: string;
    /** type='permission_response' 时必填 */
    requestId?: string;
    /** type='permission_response' 时必填 */
    decision?: PermissionDecision;
}

// ============================================================================
// 下行消息（服务端 → 客户端）
// ============================================================================

export type ServerMessageType =
    | 'attached'            // 会话已就绪，回传真实 sessionId
    | 'event'               // 一条 WireEvent
    | 'thinking'            // Claude 是否正在思考，用于客户端显示加载态
    | 'permission_request'  // 需要用户批准工具调用
    | 'permission_closed'   // 该权限请求已失效，客户端应收起弹窗
    | 'fatal';              // 致命错误，会话已终止

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
    /** type='permission_request' 时有效 */
    request?: PermissionRequest;
    /** type='permission_closed' 时有效 */
    requestId?: string;
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
    /** 名下是否有正在运行的会话 */
    running: boolean;
}

export interface SessionInfo {
    sessionId: string;
    /** 首条用户消息的前 60 字，用作列表标题 */
    title: string;
    gitBranch: string;
    messageCount: number;
    lastActiveAt: number;
    /**
     * 是否正在运行。
     *
     * 两个来源取或：本服务持有 runner（精确），
     * 或 transcript 在最近 90 秒内被写入过（启发式，覆盖
     * 用户直接在服务器终端跑 claude 的情况）。
     * 详见 claude/activeSessions.ts。
     */
    running: boolean;
}

export interface PairResponse {
    token: string;
    serverName: string;
}
