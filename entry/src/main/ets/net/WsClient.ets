/**
 * WebSocket 客户端：负责与服务端的实时对话通道。
 *
 * 职责有三个：
 *   1. 连接管理（含指数退避重连）
 *   2. 上行消息编码
 *   3. 下行消息解码并分发给回调
 *
 * 不持有任何界面状态 —— 事件合并、列表维护都交给 AppStore。
 */

import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  ClientMessage,
  ServerMessage,
  WireEvent,
  PermissionRequest,
  PermissionDecision,
  ClientMsgType,
  ServerMsgType
} from './Protocol';

/** 连接状态 */
export enum WsState {
  IDLE = 0,
  CONNECTING = 1,
  OPEN = 2,
  RECONNECTING = 3,
  CLOSED = 4
}

export interface WsCallbacks {
  onStateChange: (state: WsState) => void;
  onAttached: (sessionId: string) => void;
  onEvent: (event: WireEvent) => void;
  onThinking: (thinking: boolean) => void;
  /** Claude 要用工具，需要用户批准 */
  onPermissionRequest: (request: PermissionRequest) => void;
  /** 该权限请求已失效，收起弹窗 */
  onPermissionClosed: (requestId: string) => void;
  onFatal: (message: string) => void;
}

/** 重连退避：首次 1 秒，逐次翻倍，封顶 30 秒 */
const BACKOFF_BASE_MS = 1000;
const BACKOFF_MAX_MS = 30000;

export class WsClient {
  private ws: webSocket.WebSocket | null = null;
  private url: string = '';
  private token: string = '';
  private callbacks: WsCallbacks | null = null;

  private state: WsState = WsState.IDLE;
  private retryCount: number = 0;
  private retryTimer: number = -1;
  /** 主动关闭时置真，避免触发重连 */
  private manualClose: boolean = false;

  /** 重连后要自动恢复的会话，attach 成功过就会记下来 */
  private lastProjectId: string = '';
  private lastSessionId: string = '';

  configure(url: string, token: string, callbacks: WsCallbacks): void {
    this.url = url;
    this.token = token;
    this.callbacks = callbacks;
  }

  getState(): WsState {
    return this.state;
  }

  private setState(next: WsState): void {
    if (this.state === next) {
      return;
    }
    this.state = next;
    this.callbacks?.onStateChange(next);
  }

  // -------------------------------------------------------------------------
  // 连接
  // -------------------------------------------------------------------------

  connect(): void {
    if (this.state === WsState.CONNECTING || this.state === WsState.OPEN) {
      return;
    }
    this.manualClose = false;
    this.setState(this.retryCount > 0 ? WsState.RECONNECTING : WsState.CONNECTING);

    const ws = webSocket.createWebSocket();
    this.ws = ws;

    ws.on('open', () => {
      this.retryCount = 0;
      this.setState(WsState.OPEN);
      // 断线重连后自动恢复之前的会话，用户无感
      if (this.lastProjectId.length > 0) {
        this.attach(this.lastProjectId, this.lastSessionId);
      }
    });

    ws.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
      if (err) {
        return;
      }
      if (typeof data !== 'string') {
        return;
      }
      this.dispatch(data);
    });

    ws.on('close', () => {
      this.ws = null;
      if (this.manualClose) {
        this.setState(WsState.CLOSED);
        return;
      }
      this.scheduleReconnect();
    });

    ws.on('error', () => {
      // error 之后一定会来 close，重连逻辑统一放在 close 里，这里不重复处理
    });

    // 鸿蒙的 connect 支持自定义 header，token 走标准 Authorization
    const header: Record<string, string> = {
      'Authorization': `Bearer ${this.token}`
    };
    ws.connect(this.url, { header: header }, (err: BusinessError) => {
      if (err) {
        this.scheduleReconnect();
      }
    });
  }

  private scheduleReconnect(): void {
    if (this.manualClose) {
      return;
    }
    this.setState(WsState.RECONNECTING);

    // 指数退避，避免服务端没起来时疯狂重试
    const delay = Math.min(BACKOFF_BASE_MS * Math.pow(2, this.retryCount), BACKOFF_MAX_MS);
    this.retryCount++;

    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.connect();
    }, delay);
  }

  close(): void {
    this.manualClose = true;
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.ws?.close();
    this.ws = null;
    this.setState(WsState.CLOSED);
  }

  // -------------------------------------------------------------------------
  // 下行分发
  // -------------------------------------------------------------------------

  private dispatch(raw: string): void {
    let msg: ServerMessage;
    try {
      msg = JSON.parse(raw) as ServerMessage;
    } catch (_e) {
      return;
    }
    const cb = this.callbacks;
    if (cb === null) {
      return;
    }

    if (msg.type === ServerMsgType.ATTACHED) {
      const sid = msg.sessionId ?? '';
      // 新会话首次 attached 时 sessionId 为空，真实 id 稍后由第二条补上；
      // 记下来是为了断线重连时能续上同一个会话
      if (sid.length > 0) {
        this.lastSessionId = sid;
      }
      cb.onAttached(sid);
    } else if (msg.type === ServerMsgType.EVENT) {
      if (msg.payload !== undefined) {
        cb.onEvent(msg.payload);
      }
    } else if (msg.type === ServerMsgType.THINKING) {
      cb.onThinking(msg.value === true);
    } else if (msg.type === ServerMsgType.PERMISSION_REQUEST) {
      if (msg.request !== undefined) {
        cb.onPermissionRequest(msg.request);
      }
    } else if (msg.type === ServerMsgType.PERMISSION_CLOSED) {
      cb.onPermissionClosed(msg.requestId ?? '');
    } else if (msg.type === ServerMsgType.FATAL) {
      cb.onFatal(msg.message ?? '会话异常终止');
    }
  }

  // -------------------------------------------------------------------------
  // 上行
  // -------------------------------------------------------------------------

  private send(msg: ClientMessage): void {
    if (this.ws === null || this.state !== WsState.OPEN) {
      return;
    }
    this.ws.send(JSON.stringify(msg));
  }

  /** 挂载会话。sessionId 为空表示新建 */
  attach(projectId: string, sessionId: string): void {
    this.lastProjectId = projectId;
    this.lastSessionId = sessionId;

    const msg: ClientMessage = { type: ClientMsgType.ATTACH, projectId: projectId };
    if (sessionId.length > 0) {
      msg.sessionId = sessionId;
    }
    this.send(msg);
  }

  sendText(text: string): void {
    this.send({ type: ClientMsgType.SEND, text: text } as ClientMessage);
  }

  interrupt(): void {
    this.send({ type: ClientMsgType.INTERRUPT } as ClientMessage);
  }

  /** 回复权限请求 */
  respondPermission(requestId: string, decision: PermissionDecision): void {
    this.send({
      type: ClientMsgType.PERMISSION_RESPONSE,
      requestId: requestId,
      decision: decision
    } as ClientMessage);
  }

  detach(): void {
    this.lastProjectId = '';
    this.lastSessionId = '';
    this.send({ type: ClientMsgType.DETACH } as ClientMessage);
  }
}

/** 全局单例：同一时刻只维护一条对话通道 */
export const wsClient: WsClient = new WsClient();
