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
import { LazyDataSource } from '../utils/LazyDataSource';

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
  /**
   * 聊天内容的数据源。
   *
   * 用 LazyDataSource 而不是 @Trace 数组：ArkUI 的 ForEach 没有虚拟化，
   * 几百条消息会被一次性全部实例化。LazyForEach 只建可见区域附近的，
   * 而且追加消息时只通知增量，不会整表重建。
   *
   * 它不是 @Trace —— 刷新由 DataChangeListener 驱动，不走状态观察。
   */
  readonly itemSource: LazyDataSource<ChatItem> = new LazyDataSource<ChatItem>();
  /** 条数单独用 @Trace 暴露，供界面判断空态 */
  @Trace itemCount: number = 0;
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
    if (at !== undefined) {
      // 同 id 再来一次是状态更新（如工具从 running 变 ok）。
      // ChatItem 自身是 @ObservedV2，改字段就会刷新那一行；
      // 再通知一次数据源是为了让 LazyForEach 感知到该项已变。
      this.itemSource.getData(at).merge(e);
      this.itemSource.notifyChange(at);
      return;
    }

    this.itemSource.append(new ChatItem(e));
    this.index.set(e.id, this.itemSource.totalCount() - 1);
    this.itemCount = this.itemSource.totalCount();
  }

  /** 用历史消息重置列表 */
  resetItems(events: WireEvent[]): void {
    const next: ChatItem[] = [];
    this.index.clear();
    for (let i = 0; i < events.length; i++) {
      next.push(new ChatItem(events[i]));
      this.index.set(events[i].id, i);
    }
    this.itemSource.setAll(next);
    this.itemCount = next.length;
  }

  /** 按 id 找下标，供提问索引跳转 */
  indexOfItem(id: string): number {
    const at = this.index.get(id);
    return at === undefined ? -1 : at;
  }

  /** 只读快照，供提问索引等做遍历 */
  itemsSnapshot(): ChatItem[] {
    return this.itemSource.all();
  }

  clearChat(): void {
    this.itemSource.clear();
    this.itemCount = 0;
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
