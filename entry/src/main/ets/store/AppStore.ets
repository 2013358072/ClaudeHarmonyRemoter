/**
 * 全局状态。
 *
 * 用 V2 状态管理（@ObservedV2 + @Trace）：聊天列表是频繁增删的深层数据，
 * V2 的深度观察能直接追踪到数组元素的属性变更。
 *
 * ⚠ 读这个 store 的组件必须是 @ComponentV2。
 *
 * @Trace 的变更只对 @ComponentV2 生效。用 V1 的 @Component 去读，
 * 首次渲染能拿到值，之后就再也不刷新了 —— 而且**不报任何错**。
 * 本项目就踩过：页面一开始是 @Component，表现为连接状态永远停在
 * "正在重连"、消息也不流式更新，看起来像 WebSocket 没连上，
 * 实际是界面压根不重渲染。所有页面已统一为 V2，新增页面也必须是 V2。
 */

import { WireEvent, ProjectInfo, SessionInfo, EventKind, PermissionRequest } from '../net/Protocol';
import { WsState } from '../net/WsClient';

/**
 * 聊天列表里的一条。
 *
 * 直接用 WireEvent 也能渲染，但工具事件需要「按 id 覆盖状态」，
 * 包一层可变类，配合 @Trace 让状态变更能精确触发对应行的刷新。
 */
@ObservedV2
export class ChatItem {
  readonly id: string;
  readonly kind: string;
  readonly ts: number;
  readonly role: string;

  @Trace text: string = '';
  @Trace toolName: string = '';
  @Trace toolSummary: string = '';
  @Trace toolStatus: string = '';
  @Trace skillName: string = '';
  @Trace ok: boolean = false;
  @Trace durationMs: number = 0;
  @Trace costUsd: number = 0;

  constructor(e: WireEvent) {
    this.id = e.id;
    this.kind = e.kind;
    this.ts = e.ts;
    this.role = e.role ?? '';
    this.text = e.text ?? '';
    this.toolName = e.toolName ?? '';
    this.toolSummary = e.toolSummary ?? '';
    this.toolStatus = e.toolStatus ?? '';
    this.skillName = e.skillName ?? '';
    this.ok = e.ok ?? false;
    this.durationMs = e.durationMs ?? 0;
    this.costUsd = e.costUsd ?? 0;
  }

  /** 用后到的同 id 事件更新自己。只覆盖非空字段 —— tool_result 只带状态 */
  merge(e: WireEvent): void {
    if (e.toolStatus !== undefined && e.toolStatus.length > 0) {
      this.toolStatus = e.toolStatus;
    }
    if (e.toolName !== undefined && e.toolName.length > 0) {
      this.toolName = e.toolName;
    }
    if (e.toolSummary !== undefined && e.toolSummary.length > 0) {
      this.toolSummary = e.toolSummary;
    }
    if (e.text !== undefined && e.text.length > 0) {
      this.text = e.text;
    }
  }
}

@ObservedV2
export class AppStore {
  // ---- 连接 ----
  @Trace serverName: string = '';
  @Trace wsState: WsState = WsState.IDLE;

  // ---- 列表 ----
  @Trace projects: ProjectInfo[] = [];
  @Trace sessions: SessionInfo[] = [];
  @Trace loadingProjects: boolean = false;
  @Trace loadingSessions: boolean = false;

  // ---- 当前会话 ----
  @Trace currentProjectId: string = '';
  @Trace currentProjectName: string = '';
  @Trace currentSessionId: string = '';
  @Trace thinking: boolean = false;
  @Trace items: ChatItem[] = [];
  /** 非空时在聊天页顶部显示错误条 */
  @Trace banner: string = '';

  // ---- 权限交互 ----
  /**
   * 当前待确认的权限请求，非空时聊天页弹出确认框。
   *
   * 只保留一条：Claude 一次只会问一个，多条并发时后到的会覆盖前一条，
   * 而服务端对未回复的请求有兜底拒绝，不会卡死。
   */
  @Trace pendingPermission: PermissionRequest | null = null;

  /** id -> items 下标，工具事件按 id 覆盖时用 */
  private index: Map<string, number> = new Map();

  // -------------------------------------------------------------------------
  // 聊天列表维护
  // -------------------------------------------------------------------------

  /** 追加或合并一条事件 */
  appendEvent(e: WireEvent): void {
    // result 事件只用来结束思考态和更新计费，不单独占一行
    if (e.kind === EventKind.RESULT) {
      this.thinking = false;
      return;
    }

    const at = this.index.get(e.id);
    if (at !== undefined && at < this.items.length) {
      this.items[at].merge(e);
      return;
    }

    const item = new ChatItem(e);
    // 直接 push 到 @Trace 数组即可触发刷新
    this.items.push(item);
    this.index.set(e.id, this.items.length - 1);
  }

  /** 用历史消息重置列表 */
  resetItems(events: WireEvent[]): void {
    const next: ChatItem[] = [];
    this.index.clear();
    for (let i = 0; i < events.length; i++) {
      next.push(new ChatItem(events[i]));
      this.index.set(events[i].id, i);
    }
    this.items = next;
  }

  clearChat(): void {
    this.items = [];
    this.index.clear();
    this.thinking = false;
    this.banner = '';
    this.currentSessionId = '';
    this.pendingPermission = null;
  }

  /** 收起指定的权限弹窗。requestId 为空表示无条件收起 */
  closePermission(requestId: string): void {
    const p = this.pendingPermission;
    if (p === null) {
      return;
    }
    if (requestId.length === 0 || p.id === requestId) {
      this.pendingPermission = null;
    }
  }
}

/** 全局单例 */
export const appStore: AppStore = new AppStore();
