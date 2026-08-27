/**
 * 线协议定义 —— 必须与 server/src/protocol/wire.ts 保持同步。
 *
 * 服务端已经把 Claude Agent SDK 的嵌套结构压平了，这里全是扁平接口，
 * 客户端只需按 kind 分支渲染，不用处理联合类型窄化。
 */

// ============================================================================
// 事件（服务端 → 客户端）
// ============================================================================

/** 'text' | 'thinking' | 'tool' | 'skill' | 'result' | 'error' */
export type WireEventKind = string;

/** 'user' | 'assistant' */
export type WireRole = string;

/** 'running' | 'ok' | 'error' */
export type WireToolStatus = string;

export interface WireEvent {
  kind: WireEventKind;
  id: string;
  ts: number;

  role?: WireRole;
  text?: string;

  toolName?: string;
  toolSummary?: string;
  toolStatus?: WireToolStatus;

  /** kind='skill' 时有效：被引用的 skill 名 */
  skillName?: string;

  ok?: boolean;
  durationMs?: number;
  costUsd?: number;
}

// ============================================================================
// 权限请求
// ============================================================================

/**
 * Claude 想调用工具时的确认请求。
 * title / displayName / description 都是服务端从 SDK 拿到的现成文案，
 * 客户端直接显示即可，不要自己拼措辞。
 */
export interface PermissionRequest {
  id: string;
  toolName: string;
  /** 主提示句 */
  title: string;
  /** 短名词，适合按钮 */
  displayName: string;
  /** 副标题，说明授权影响范围 */
  description: string;
  /** 工具参数详情，如完整的 bash 命令 */
  detail: string;
  /** 是否支持「总是允许」 */
  canRemember: boolean;
}

/** 'allow' | 'always' | 'deny' */
export type PermissionDecision = string;

// ============================================================================
// 上行消息（客户端 → 服务端）
// ============================================================================

/** 'attach' | 'send' | 'interrupt' | 'detach' | 'permission_response' */
export type ClientMessageType = string;

export interface ClientMessage {
  type: ClientMessageType;
  projectId?: string;
  sessionId?: string;
  text?: string;
  requestId?: string;
  decision?: PermissionDecision;
}

// ============================================================================
// 下行消息（服务端 → 客户端）
// ============================================================================

/** 'attached' | 'event' | 'thinking' | 'permission_request' | 'permission_closed' | 'fatal' */
export type ServerMessageType = string;

export interface ServerMessage {
  type: ServerMessageType;
  sessionId?: string;
  payload?: WireEvent;
  value?: boolean;
  message?: string;
  request?: PermissionRequest;
  requestId?: string;
}

// ============================================================================
// HTTP 接口的数据结构
// ============================================================================

export interface ProjectInfo {
  id: string;
  path: string;
  name: string;
  sessionCount: number;
  lastActiveAt: number;
  /** 名下是否有正在运行的会话。服务端已保证运行中的排在前面 */
  running: boolean;
}

export interface SessionInfo {
  sessionId: string;
  title: string;
  gitBranch: string;
  messageCount: number;
  lastActiveAt: number;
  /** 是否正在运行。服务端已保证运行中的排在前面 */
  running: boolean;
}

export interface PairResponse {
  token: string;
  serverName: string;
}

export interface PingResponse {
  ok: boolean;
  serverName: string;
  pairingOpen: boolean;
}

export interface ApiError {
  error: string;
}

// ============================================================================
// 常量
// ============================================================================

export class EventKind {
  static readonly TEXT: string = 'text';
  static readonly THINKING: string = 'thinking';
  static readonly TOOL: string = 'tool';
  static readonly SKILL: string = 'skill';
  static readonly RESULT: string = 'result';
  static readonly ERROR: string = 'error';
}

export class Role {
  static readonly USER: string = 'user';
  static readonly ASSISTANT: string = 'assistant';
}

export class ToolStatus {
  static readonly RUNNING: string = 'running';
  static readonly OK: string = 'ok';
  static readonly ERROR: string = 'error';
}

export class ClientMsgType {
  static readonly ATTACH: string = 'attach';
  static readonly SEND: string = 'send';
  static readonly INTERRUPT: string = 'interrupt';
  static readonly DETACH: string = 'detach';
  static readonly PERMISSION_RESPONSE: string = 'permission_response';
}

export class ServerMsgType {
  static readonly ATTACHED: string = 'attached';
  static readonly EVENT: string = 'event';
  static readonly THINKING: string = 'thinking';
  static readonly PERMISSION_REQUEST: string = 'permission_request';
  static readonly PERMISSION_CLOSED: string = 'permission_closed';
  static readonly FATAL: string = 'fatal';
}

export class Decision {
  static readonly ALLOW: string = 'allow';
  static readonly ALWAYS: string = 'always';
  static readonly DENY: string = 'deny';
}
