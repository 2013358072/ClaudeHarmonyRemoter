/**
 * 聊天页：与某个 Claude 会话的实时对话。
 *
 * 进页面时：先拉历史消息铺底（如果是续接的会话），再建 WebSocket 并 attach。
 * 这两件事顺序不能反 —— 先连 WS 的话，实时事件可能先于历史到达，
 * 时间线会乱。
 *
 * 版式沿用 Claude 的做法：模型回复**不套气泡**，整幅铺开，
 * 只有用户消息用气泡右对齐。长回复套气泡会让阅读变得拥挤，
 * 而对话里真正需要"分清是谁说的"的其实只有用户那一侧。
 */

import { apiClient, ApiException } from '../net/ApiClient';
import { wsClient, WsState } from '../net/WsClient';
import { appStore, ChatItem } from '../store/AppStore';
import {
  WireEvent,
  EventKind,
  Role,
  ToolStatus,
  PermissionRequest,
  PermissionDecision,
  Decision
} from '../net/Protocol';
import { theme, FontSize } from '../theme/Theme';

/** 路由参数 */
export interface ChatParam {
  projectId: string;
  projectName: string;
  /** 空字符串表示新建会话 */
  sessionId: string;
  title: string;
}

@ComponentV2
export struct ChatView {
  @Consumer() pathStack: NavPathStack = new NavPathStack();
  @Param param: ChatParam = { projectId: '', projectName: '', sessionId: '', title: '' };

  @Local draft: string = '';
  @Local loadingHistory: boolean = true;

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

    // 历史铺完直接定位到最新一条 —— 进来就看到最近的对话，
    // 而不是从几百条之前开始往下翻。
    // 延时比实时消息那次长：这里要等整个列表首次布局完成。
    this.scrollToBottom(220);

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
      onPermissionRequest: (request: PermissionRequest): void => {
        appStore.pendingPermission = request;
      },
      onPermissionClosed: (requestId: string): void => {
        appStore.closePermission(requestId);
      },
      onFatal: (message: string): void => {
        appStore.banner = message;
        appStore.thinking = false;
        appStore.closePermission('');
      }
    });
    // fresh=true：这是用户主动进入聊天页，清掉上个会话遗留的重试计数，
    // 否则一进来就显示"正在重连"
    wsClient.connect(true);
    // connect 是异步的，attach 要等 open 之后；WsClient 内部会在 open 时
    // 自动补发 attach，所以这里先登记目标会话即可
    wsClient.attach(this.param.projectId, this.param.sessionId);
  }

  /** 滚到底部。delay 要留够渲染时间，否则拿到的还是旧高度 */
  private scrollToBottom(delay: number = 50): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, delay);
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
    this.scrollToBottom(120);
  }

  /** 回复权限请求并收起弹窗 */
  private decide(decision: PermissionDecision): void {
    const p = appStore.pendingPermission;
    if (p === null) {
      return;
    }
    wsClient.respondPermission(p.id, decision);
    appStore.pendingPermission = null;
  }

  private connected(): boolean {
    return appStore.wsState === WsState.OPEN;
  }

  // -------------------------------------------------------------------------
  // 渲染
  // -------------------------------------------------------------------------

  /** 顶栏：返回 + 标题 + 连接状态点 */
  @Builder
  header() {
    Row({ space: 10 }) {
      Text('‹')
        .fontSize(theme.fs(28))
        .fontColor(theme.palette.text)
        .width(30)
        .textAlign(TextAlign.Center)
        .onClick(() => { this.pathStack.pop(); })

      Column({ space: 1 }) {
        Text(this.param.title)
          .fontSize(theme.fs(FontSize.BODY))
          .fontWeight(FontWeight.Medium)
          .fontColor(theme.palette.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(this.param.projectName)
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 连接状态用一个小圆点表达，比文字更安静
      Row()
        .width(7)
        .height(7)
        .borderRadius(4)
        .backgroundColor(
          this.connected() ? '#4CAF7D'
            : (appStore.wsState === WsState.CLOSED ? theme.palette.textTertiary : theme.palette.accent)
        )
    }
    .width('100%')
    .padding({ left: 8, right: 20, top: 10, bottom: 10 })
    .backgroundColor(theme.palette.bg)
  }

  /** 断线提示条。仅在真的在重连时出现 */
  @Builder
  statusBar() {
    if (appStore.wsState === WsState.RECONNECTING || appStore.wsState === WsState.CONNECTING) {
      Row({ space: 8 }) {
        LoadingProgress().width(13).height(13).color(theme.palette.textSecondary)
        Text(appStore.wsState === WsState.CONNECTING ? '连接中' : '正在重连')
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.textSecondary)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: 6, bottom: 6 })
      .backgroundColor(theme.palette.surfaceAlt)
    }

    if (appStore.banner.length > 0) {
      Row({ space: 8 }) {
        Text(appStore.banner)
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.danger)
          .layoutWeight(1)
        Text('✕')
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.danger)
          .onClick(() => { appStore.banner = ''; })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 8 })
      .backgroundColor(theme.palette.surfaceAlt)
    }
  }

  /** 用户消息：右对齐气泡 */
  @Builder
  userBubble(item: ChatItem) {
    Row() {
      Blank()
      Text(item.text)
        .fontSize(theme.fs(FontSize.BODY))
        .fontColor(theme.palette.text)
        .lineHeight(theme.fs(FontSize.BODY) * 1.5)
        .padding({ left: 14, right: 14, top: 10, bottom: 10 })
        .backgroundColor(theme.palette.userBubble)
        .borderRadius(16)
        .constraintSize({ maxWidth: '85%' })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 8 })
  }

  /** 模型回复：不套气泡，整幅铺开，字号小一档 */
  @Builder
  assistantText(item: ChatItem) {
    Text(item.text)
      .fontSize(theme.fs(FontSize.ASSISTANT))
      .fontColor(theme.palette.text)
      .lineHeight(theme.fs(FontSize.ASSISTANT) * 1.7)
      .width('100%')
      .padding({ left: 20, right: 20, top: 6, bottom: 10 })
  }

  /** 思考过程：更弱的存在感，斜体 */
  @Builder
  thinkingBlock(item: ChatItem) {
    Row({ space: 8 }) {
      // 左侧竖线，暗示这是"旁白"而非正文
      Row()
        .width(2)
        .borderRadius(1)
        .backgroundColor(theme.palette.border)
      Text(item.text)
        .fontSize(theme.fs(FontSize.TINY))
        .fontColor(theme.palette.textTertiary)
        .fontStyle(FontStyle.Italic)
        .lineHeight(theme.fs(FontSize.TINY) * 1.6)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 20, right: 20, top: 4, bottom: 6 })
  }

  /** 工具调用：紧凑单行，状态用图标区分 */
  @Builder
  toolRow(item: ChatItem) {
    Row({ space: 8 }) {
      if (item.toolStatus === ToolStatus.RUNNING) {
        LoadingProgress()
          .width(12)
          .height(12)
          .color(theme.palette.accent)
      } else if (item.toolStatus === ToolStatus.ERROR) {
        Text('✕')
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.danger)
          .width(12)
          .textAlign(TextAlign.Center)
      } else {
        Text('✓')
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.textTertiary)
          .width(12)
          .textAlign(TextAlign.Center)
      }

      Text(item.toolSummary.length > 0 ? item.toolSummary : item.toolName)
        .fontSize(theme.fs(FontSize.TINY))
        .fontColor(theme.palette.textSecondary)
        .fontFamily('monospace')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 20, right: 20, top: 5, bottom: 5 })
  }

  @Builder
  errorRow(item: ChatItem) {
    Text(item.text)
      .fontSize(theme.fs(FontSize.TINY))
      .fontColor(theme.palette.danger)
      .lineHeight(theme.fs(FontSize.TINY) * 1.6)
      .width('100%')
      .padding({ left: 20, right: 20, top: 6, bottom: 6 })
  }

  @Builder
  itemView(item: ChatItem) {
    if (item.kind === EventKind.TEXT) {
      if (item.role === Role.USER) {
        this.userBubble(item)
      } else {
        this.assistantText(item)
      }
    } else if (item.kind === EventKind.THINKING) {
      this.thinkingBlock(item)
    } else if (item.kind === EventKind.TOOL) {
      this.toolRow(item)
    } else if (item.kind === EventKind.ERROR) {
      this.errorRow(item)
    }
  }

  /** 空会话的引导 */
  @Builder
  emptyState() {
    Column({ space: 10 }) {
      Text('开始新对话')
        .fontSize(theme.fs(FontSize.HEADING))
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.palette.text)
      Text(`工作目录 ${this.param.projectName}`)
        .fontSize(theme.fs(FontSize.LABEL))
        .fontColor(theme.palette.textTertiary)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .padding(40)
  }

  /** 权限确认弹层 */
  @Builder
  permissionSheet(req: PermissionRequest) {
    Column() {
      // 遮罩点击不关闭 —— 权限必须明确表态，
      // 误触关掉会让 Claude 那边一直等着
      Column()
        .layoutWeight(1)
        .width('100%')
        .backgroundColor('#59000000')

      Column({ space: 14 }) {
        // 顶部小横条，暗示这是一个可交互的弹层
        Row()
          .width(36)
          .height(4)
          .borderRadius(2)
          .backgroundColor(theme.palette.border)

        Column({ space: 6 }) {
          Text(req.title)
            .fontSize(theme.fs(FontSize.HEADING))
            .fontWeight(FontWeight.Medium)
            .fontColor(theme.palette.text)
            .width('100%')

          if (req.description.length > 0) {
            Text(req.description)
              .fontSize(theme.fs(FontSize.LABEL))
              .fontColor(theme.palette.textSecondary)
              .width('100%')
          }
        }
        .width('100%')

        if (req.detail.length > 0) {
          // 参数详情可能很长（比如整条 bash 命令），给独立滚动区，
          // 避免把按钮挤出屏幕
          Scroll() {
            Text(req.detail)
              .fontSize(theme.fs(FontSize.TINY))
              .fontFamily('monospace')
              .fontColor(theme.palette.textSecondary)
              .lineHeight(theme.fs(FontSize.TINY) * 1.6)
              .width('100%')
              .textAlign(TextAlign.Start)
          }
          .constraintSize({ maxHeight: 150 })
          .width('100%')
          .padding(12)
          .backgroundColor(theme.palette.surfaceAlt)
          .borderRadius(10)
          .align(Alignment.TopStart)
          .scrollBar(BarState.Off)
        }

        Row({ space: 10 }) {
          Button('拒绝')
            .layoutWeight(1)
            .height(46)
            .fontSize(theme.fs(FontSize.BODY))
            .fontColor(theme.palette.text)
            .backgroundColor(theme.palette.surfaceAlt)
            .borderRadius(12)
            .onClick(() => this.decide(Decision.DENY))

          Button('允许')
            .layoutWeight(1)
            .height(46)
            .fontSize(theme.fs(FontSize.BODY))
            .fontColor(theme.palette.onAccent)
            .backgroundColor(theme.palette.accent)
            .borderRadius(12)
            .onClick(() => this.decide(Decision.ALLOW))
        }
        .width('100%')

        if (req.canRemember) {
          Text(`本次会话内不再询问「${req.displayName}」`)
            .fontSize(theme.fs(FontSize.LABEL))
            .fontColor(theme.palette.accent)
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 2, bottom: 6 })
            .onClick(() => this.decide(Decision.ALWAYS))
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 24 })
      .backgroundColor(theme.palette.surface)
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .width('100%')
    .height('100%')
  }

  /** 输入区 */
  @Builder
  composer() {
    Row({ space: 10 }) {
      TextInput({ placeholder: '发送指令…', text: this.draft })
        .layoutWeight(1)
        .height(44)
        .fontSize(theme.fs(FontSize.BODY))
        .fontColor(theme.palette.text)
        .placeholderColor(theme.palette.textTertiary)
        .backgroundColor(theme.palette.surfaceAlt)
        .borderRadius(22)
        .padding({ left: 16, right: 16 })
        .onChange((v: string) => { this.draft = v; })
        .onSubmit(() => this.submit())

      if (appStore.thinking) {
        // 思考中把发送换成停止 —— 同一个位置，减少误触
        Button('■')
          .width(44)
          .height(44)
          .fontSize(theme.fs(FontSize.LABEL))
          .fontColor(theme.palette.onAccent)
          .backgroundColor(theme.palette.danger)
          .borderRadius(22)
          .onClick(() => wsClient.interrupt())
      } else {
        Button('↑')
          .width(44)
          .height(44)
          .fontSize(theme.fs(20))
          .fontColor(theme.palette.onAccent)
          .backgroundColor(
            this.draft.trim().length > 0 ? theme.palette.accent : theme.palette.border
          )
          .borderRadius(22)
          .enabled(this.draft.trim().length > 0)
          .onClick(() => this.submit())
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 14 })
    .backgroundColor(theme.palette.bg)
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          this.header()
          Divider().strokeWidth(0.5).color(theme.palette.border)
          this.statusBar()

          if (this.loadingHistory) {
            Column() {
              LoadingProgress().width(36).height(36).color(theme.palette.accent)
            }
            .layoutWeight(1)
            .width('100%')
            .justifyContent(FlexAlign.Center)
          } else if (appStore.items.length === 0 && !appStore.thinking) {
            Column() {
              this.emptyState()
            }
            .layoutWeight(1)
            .width('100%')
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
                    LoadingProgress().width(14).height(14).color(theme.palette.accent)
                    Text('思考中')
                      .fontSize(theme.fs(FontSize.TINY))
                      .fontColor(theme.palette.textTertiary)
                  }
                  .padding({ left: 20, top: 10, bottom: 10 })
                }
              }

              // 底部留白，最后一条消息不至于贴着输入框
              ListItem() {
                Row().height(12)
              }
            }
            .layoutWeight(1)
            .width('100%')
            .scrollBar(BarState.Off)
            .listDirection(Axis.Vertical)
          }

          this.composer()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(theme.palette.bg)

        // 权限确认覆盖在聊天界面之上
        if (appStore.pendingPermission !== null) {
          this.permissionSheet(appStore.pendingPermission)
        }
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Bottom)
    }
    .hideTitleBar(true)
    .backgroundColor(theme.palette.bg)
  }
}
