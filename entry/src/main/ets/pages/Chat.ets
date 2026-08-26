/**
 * 聊天页：与某个 Claude 会话的实时对话。
 *
 * 进页面时：先拉历史消息铺底（如果是续接的会话），再建 WebSocket 并 attach。
 * 这两件事顺序不能反 —— 先连 WS 的话，实时事件可能先于历史到达，
 * 时间线会乱。
 */

import { apiClient, ApiException } from '../net/ApiClient';
import { wsClient, WsState } from '../net/WsClient';
import { appStore, ChatItem } from '../store/AppStore';
import { WireEvent, EventKind, Role, ToolStatus } from '../net/Protocol';
import { formatDuration, formatCost } from '../utils/Format';

/** 路由参数 */
export interface ChatParam {
  projectId: string;
  projectName: string;
  /** 空字符串表示新建会话 */
  sessionId: string;
  title: string;
}

@Component
export struct ChatView {
  @Consume('pathStack') pathStack: NavPathStack;
  param: ChatParam = { projectId: '', projectName: '', sessionId: '', title: '' };

  @State draft: string = '';
  @State loadingHistory: boolean = true;

  private scroller: Scroller = new Scroller();

  async aboutToAppear(): Promise<void> {
    appStore.clearChat();
    appStore.currentProjectId = this.param.projectId;
    appStore.currentProjectName = this.param.projectName;
    appStore.currentSessionId = this.param.sessionId;

    // 续接会话先铺历史；新会话直接跳过
    if (this.param.sessionId.length > 0) {
      try {
        const history: WireEvent[] = await apiClient.loadHistory(this.param.sessionId);
        appStore.resetItems(history);
      } catch (e) {
        appStore.banner = `历史消息加载失败：${(e as ApiException).message}`;
      }
    }
    this.loadingHistory = false;

    this.connect();
  }

  aboutToDisappear(): void {
    wsClient.close();
    appStore.clearChat();
  }

  private connect(): void {
    wsClient.configure(apiClient.wsUrl(), apiClient.getToken(), {
      onStateChange: (state: WsState): void => {
        appStore.wsState = state;
      },
      onAttached: (sessionId: string): void => {
        if (sessionId.length > 0) {
          appStore.currentSessionId = sessionId;
        }
      },
      onEvent: (event: WireEvent): void => {
        appStore.appendEvent(event);
        this.scrollToBottom();
      },
      onThinking: (thinking: boolean): void => {
        appStore.thinking = thinking;
      },
      onFatal: (message: string): void => {
        appStore.banner = message;
        appStore.thinking = false;
      }
    });
    wsClient.connect();
    // connect 是异步的，attach 要等 open 之后；WsClient 内部会在 open 时
    // 自动补发 attach，所以这里先登记目标会话即可
    wsClient.attach(this.param.projectId, this.param.sessionId);
  }

  private scrollToBottom(): void {
    // 等这一帧渲染完再滚，否则拿到的还是旧高度
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 50);
  }

  private submit(): void {
    const text = this.draft.trim();
    if (text.length === 0) {
      return;
    }
    if (appStore.wsState !== WsState.OPEN) {
      this.getUIContext().getPromptAction().showToast({ message: '尚未连接到服务器' });
      return;
    }
    wsClient.sendText(text);
    this.draft = '';
  }

  // -------------------------------------------------------------------------
  // 渲染
  // -------------------------------------------------------------------------

  @Builder
  connectionBar() {
    if (appStore.wsState === WsState.RECONNECTING || appStore.wsState === WsState.CONNECTING) {
      Row({ space: 8 }) {
        LoadingProgress().width(14).height(14)
        Text(appStore.wsState === WsState.CONNECTING ? '连接中…' : '正在重连…')
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .backgroundColor($r('sys.color.comp_background_secondary'))
    }

    if (appStore.banner.length > 0) {
      Row() {
        Text(appStore.banner)
          .fontSize(12)
          .fontColor($r('sys.color.warning'))
          .layoutWeight(1)
        Text('✕')
          .fontSize(12)
          .onClick(() => { appStore.banner = ''; })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
    }
  }

  @Builder
  textBubble(item: ChatItem) {
    Row() {
      if (item.role === Role.USER) {
        Blank()
      }
      Text(item.text)
        .fontSize(15)
        .padding(12)
        .backgroundColor(
          item.role === Role.USER
            ? $r('sys.color.comp_background_emphasize')
            : $r('sys.color.comp_background_secondary')
        )
        .fontColor(
          item.role === Role.USER
            ? $r('sys.color.font_on_primary')
            : $r('sys.color.font_primary')
        )
        .borderRadius(12)
        .constraintSize({ maxWidth: '80%' })
      if (item.role !== Role.USER) {
        Blank()
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 4, bottom: 4 })
  }

  @Builder
  thinkingBlock(item: ChatItem) {
    Text(item.text)
      .fontSize(13)
      .fontColor($r('sys.color.font_tertiary'))
      .fontStyle(FontStyle.Italic)
      .padding({ left: 24, right: 24, top: 4, bottom: 4 })
      .width('100%')
  }

  @Builder
  toolRow(item: ChatItem) {
    Row({ space: 8 }) {
      if (item.toolStatus === ToolStatus.RUNNING) {
        LoadingProgress().width(14).height(14)
      } else if (item.toolStatus === ToolStatus.ERROR) {
        Text('✗').fontSize(13).fontColor($r('sys.color.warning'))
      } else {
        Text('✓').fontSize(13).fontColor($r('sys.color.font_tertiary'))
      }
      Text(item.toolSummary.length > 0 ? item.toolSummary : item.toolName)
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 24, right: 24, top: 3, bottom: 3 })
  }

  @Builder
  errorRow(item: ChatItem) {
    Text(item.text)
      .fontSize(13)
      .fontColor($r('sys.color.warning'))
      .padding({ left: 24, right: 24, top: 4, bottom: 4 })
      .width('100%')
  }

  @Builder
  itemView(item: ChatItem) {
    if (item.kind === EventKind.TEXT) {
      this.textBubble(item)
    } else if (item.kind === EventKind.THINKING) {
      this.thinkingBlock(item)
    } else if (item.kind === EventKind.TOOL) {
      this.toolRow(item)
    } else if (item.kind === EventKind.ERROR) {
      this.errorRow(item)
    }
  }

  build() {
    NavDestination() {
      Column() {
        this.connectionBar()

        if (this.loadingHistory) {
          Column() {
            LoadingProgress().width(40).height(40)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
            ForEach(appStore.items, (item: ChatItem) => {
              ListItem() {
                this.itemView(item)
              }
            }, (item: ChatItem) => item.id)

            if (appStore.thinking) {
              ListItem() {
                Row({ space: 8 }) {
                  LoadingProgress().width(16).height(16)
                  Text('Claude 正在处理…')
                    .fontSize(13)
                    .fontColor($r('sys.color.font_secondary'))
                }
                .padding({ left: 24, top: 8, bottom: 8 })
              }
            }
          }
          .layoutWeight(1)
          .width('100%')
          .listDirection(Axis.Vertical)
        }

        // ---- 输入区 ----
        Row({ space: 8 }) {
          TextInput({ placeholder: '发送指令给 Claude…', text: this.draft })
            .layoutWeight(1)
            .onChange((v: string) => { this.draft = v; })
            .onSubmit(() => this.submit())

          if (appStore.thinking) {
            Button('停止')
              .backgroundColor($r('sys.color.warning'))
              .onClick(() => wsClient.interrupt())
          } else {
            Button('发送')
              .enabled(this.draft.trim().length > 0)
              .onClick(() => this.submit())
          }
        }
        .width('100%')
        .padding(12)
      }
      .width('100%')
      .height('100%')
    }
    .title(this.param.title)
  }
}
