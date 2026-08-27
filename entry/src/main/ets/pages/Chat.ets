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
 *
 * 模型回复走 Markdown 渲染（utils/Markdown.ets），用户消息保持纯文本 ——
 * 用户输入里的 * 和 # 通常就是字面意思，不该被当标记解析。
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
import { theme, FontSize, RUNNING_GREEN } from '../theme/Theme';
import { parseMarkdown, parseInline, MdBlock, MdSpan, MdType } from '../utils/Markdown';
import { projectPrefs } from '../store/ProjectPrefs';
import { notifier } from '../utils/Notifier';
import { appLifecycle } from '../store/AppLifecycle';

/** 路由参数 */
export interface ChatParam {
  projectId: string;
  projectName: string;
  /** 空字符串表示新建会话 */
  sessionId: string;
  title: string;
}

/** 侧栏里的一条提问索引 */
class QueryEntry {
  index: number = 0;
  text: string = '';
  itemId: string = '';

  constructor(index: number, text: string, itemId: string) {
    this.index = index;
    this.text = text;
    this.itemId = itemId;
  }
}

/** 输入框高度范围。超过上限就内部滚动，不再顶高 */
const COMPOSER_MIN_H: number = 44;
const COMPOSER_MAX_H: number = 132;

@ComponentV2
export struct ChatView {
  @Consumer() pathStack: NavPathStack = new NavPathStack();
  @Param param: ChatParam = { projectId: '', projectName: '', sessionId: '', title: '' };

  @Local draft: string = '';
  @Local loadingHistory: boolean = true;
  /** 输入框当前高度，随内容行数增长到上限为止 */
  @Local composerHeight: number = COMPOSER_MIN_H;
  /** 提问索引侧栏是否展开 */
  @Local drawerOpen: boolean = false;

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
    // 进到这个会话就把它遗留的通知收起来，别在通知栏留个已读的
    notifier.clear(this.param.projectId);

    // 历史铺完直接定位到最新一条 —— 进来就看到最近的对话，
    // 而不是从几百条之前开始往下翻
    this.scrollToBottom(220);

    this.connect();
  }

  aboutToDisappear(): void {
    wsClient.close();
    appStore.clearChat();
  }

  /**
   * 该发通知吗：开了开关、且 App 不在前台。
   *
   * 前台状态取自 appLifecycle（由 UIAbility 写入），不能用组件的
   * onPageShow —— 那个只对 @Entry 生效，聊天页是 NavDestination。
   */
  private shouldNotify(): boolean {
    return !appLifecycle.foreground && projectPrefs.isNotifyOn(this.param.projectId);
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
        // 从思考中变为空闲，说明这一轮跑完了
        const finished = appStore.thinking && !thinking;
        appStore.thinking = thinking;
        if (finished && this.shouldNotify()) {
          notifier.post(
            this.param.projectId,
            `${this.param.projectName} 已完成`,
            this.lastAssistantLine()
          );
        }
      },
      onPermissionRequest: (request: PermissionRequest): void => {
        appStore.pendingPermission = request;
        // 需要授权是最该打断用户的时刻 —— 不批准的话任务就卡在这
        if (this.shouldNotify()) {
          notifier.post(
            this.param.projectId,
            `${this.param.projectName} 需要授权`,
            request.title
          );
        }
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
    this.composerHeight = COMPOSER_MIN_H;
    this.scrollToBottom(120);
  }

  /**
   * 按内容行数估算输入框高度。
   *
   * ArkUI 的 TextArea 不会自动把高度回报给外部，只能按行数估。
   * 换行符和按宽度折行都算 —— 后者按每行约 22 个全角字符估，
   * 宽度不精确没关系，超过上限就滚动了。
   */
  private recalcComposerHeight(v: string): void {
    let lines = 1;
    let col = 0;
    for (let i = 0; i < v.length; i++) {
      if (v.charAt(i) === '\n') {
        lines++;
        col = 0;
      } else {
        col++;
        if (col >= 22) {
          lines++;
          col = 0;
        }
      }
    }
    const h = COMPOSER_MIN_H + (lines - 1) * 20;
    this.composerHeight = h > COMPOSER_MAX_H ? COMPOSER_MAX_H : h;
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

  /** 最后一条模型回复的首行，用作通知正文 */
  private lastAssistantLine(): string {
    const items = appStore.itemsSnapshot();
    for (let i = items.length - 1; i >= 0; i--) {
      const it = items[i];
      if (it.kind === EventKind.TEXT && it.role !== Role.USER && it.text.length > 0) {
        const line = it.text.replace(/\s+/g, ' ').trim();
        return line.length > 60 ? `${line.substring(0, 60)}…` : line;
      }
    }
    return '任务已结束';
  }

  /** 提取所有用户提问，供侧栏索引 */
  private queries(): QueryEntry[] {
    const out: QueryEntry[] = [];
    let n = 0;
    for (const item of appStore.itemsSnapshot()) {
      if (item.kind === EventKind.TEXT && item.role === Role.USER) {
        n++;
        out.push(new QueryEntry(n, item.text.replace(/\s+/g, ' ').trim(), item.id));
      }
    }
    return out;
  }

  /** 跳到指定消息 */
  private jumpTo(itemId: string): void {
    const idx = appStore.indexOfItem(itemId);
    if (idx < 0) {
      return;
    }
    this.drawerOpen = false;
    setTimeout(() => {
      this.scroller.scrollToIndex(idx, true);
    }, 120);
  }

  // -------------------------------------------------------------------------
  // Markdown 渲染
  // -------------------------------------------------------------------------

  /** 一行行内内容。链接暂不可点，只做视觉区分 */
  @Builder
  inlineText(src: string, size: number, color: string) {
    Text() {
      ForEach(parseInline(src), (sp: MdSpan) => {
        if (sp.code) {
          Span(sp.text)
            .fontFamily('monospace')
            .fontSize(size - 1)
            .fontColor(theme.palette.accent)
        } else if (sp.link.length > 0) {
          Span(sp.text)
            .fontColor(theme.palette.accent)
            .decoration({ type: TextDecorationType.Underline, color: theme.palette.accent })
        } else {
          Span(sp.text)
            .fontWeight(sp.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontStyle(sp.italic ? FontStyle.Italic : FontStyle.Normal)
        }
      }, (sp: MdSpan, i: number) => `${i}_${sp.text.length}`)
    }
    .fontSize(size)
    .fontColor(color)
    .lineHeight(size * 1.7)
    .width('100%')
  }

  @Builder
  mdBlock(b: MdBlock, size: number) {
    if (b.type === MdType.HEADING) {
      // 标题按级别递减，但差距压得比网页小 —— 手机上层级太夸张会割裂阅读
      this.inlineText(b.text, size + (b.level <= 2 ? 4 : 2), theme.palette.text)
    } else if (b.type === MdType.CODE) {
      Column() {
        if (b.lang.length > 0) {
          Text(b.lang)
            .fontSize(size - 2)
            .fontColor(theme.palette.textTertiary)
            .width('100%')
            .padding({ bottom: 4 })
        }
        Scroll() {
          Text(b.text)
            .fontFamily('monospace')
            .fontSize(size - 1)
            .fontColor(theme.palette.text)
            .lineHeight((size - 1) * 1.55)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .align(Alignment.TopStart)
      }
      .width('100%')
      .padding(12)
      .borderRadius(10)
      .backgroundColor(theme.palette.surfaceAlt)
    } else if (b.type === MdType.QUOTE) {
      Row({ space: 10 }) {
        Row()
          .width(3)
          .borderRadius(2)
          .backgroundColor(theme.palette.accent)
        Column() {
          this.inlineText(b.text, size, theme.palette.textSecondary)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else if (b.type === MdType.LIST_ITEM) {
      Row({ space: 8 }) {
        Text(b.ordered ? `${b.index}.` : '•')
          .fontSize(size)
          .fontColor(theme.palette.textTertiary)
          .lineHeight(size * 1.7)
          .width(b.ordered ? 20 : 12)
        Column() {
          this.inlineText(b.text, size, theme.palette.text)
        }
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else if (b.type === MdType.DIVIDER) {
      Divider()
        .strokeWidth(0.5)
        .color(theme.palette.border)
        .margin({ top: 4, bottom: 4 })
    } else {
      this.inlineText(b.text, size, theme.palette.text)
    }
  }

  // -------------------------------------------------------------------------
  // 渲染
  // -------------------------------------------------------------------------

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

      // 提问索引入口。侧栏靠左滑也能开，这里给一个显式入口
      Text('☰')
        .fontSize(theme.fs(16))
        .fontColor(theme.palette.textSecondary)
        .padding({ left: 8, right: 8 })
        .onClick(() => { this.drawerOpen = true; })

      Row()
        .width(7)
        .height(7)
        .borderRadius(4)
        .backgroundColor(
          this.connected() ? RUNNING_GREEN
            : (appStore.wsState === WsState.CLOSED ? theme.palette.textTertiary : theme.palette.accent)
        )
    }
    .width('100%')
    .padding({ left: 8, right: 16, top: 10, bottom: 10 })
    .backgroundColor(theme.palette.bg)
  }

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

  /** 用户消息：右对齐气泡，纯文本不做 Markdown 解析 */
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

  /** 模型回复：不套气泡，Markdown 渲染，字号小一档 */
  @Builder
  assistantText(item: ChatItem) {
    Column({ space: 8 }) {
      ForEach(parseMarkdown(item.text), (b: MdBlock, i: number) => {
        this.mdBlock(b, theme.fs(FontSize.ASSISTANT))
      }, (b: MdBlock, i: number) => `${i}_${b.type}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 20, right: 20, top: 6, bottom: 10 })
  }

  /**
   * skill 引用标记。
   *
   * skill 被调用时 Claude Code 会把整份 SKILL.md 注入成一条用户消息
   * （实测有 9 万字符），服务端已折叠成这个事件，这里只显示个圆角标签。
   */
  @Builder
  skillChip(item: ChatItem) {
    Row() {
      Blank()
      Row({ space: 6 }) {
        Text('◆')
          .fontSize(theme.fs(9))
          .fontColor(theme.palette.accent)
        Text(item.skillName)
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.accent)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(10)
      .backgroundColor(theme.palette.surfaceAlt)
      .border({ width: 1, color: theme.palette.border })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 2, bottom: 6 })
  }

  @Builder
  thinkingBlock(item: ChatItem) {
    Row({ space: 8 }) {
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

  @Builder
  toolRow(item: ChatItem) {
    Row({ space: 8 }) {
      if (item.toolStatus === ToolStatus.RUNNING) {
        LoadingProgress().width(12).height(12).color(theme.palette.accent)
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
    } else if (item.kind === EventKind.SKILL) {
      this.skillChip(item)
    } else if (item.kind === EventKind.THINKING) {
      this.thinkingBlock(item)
    } else if (item.kind === EventKind.TOOL) {
      this.toolRow(item)
    } else if (item.kind === EventKind.ERROR) {
      this.errorRow(item)
    }
  }

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

  /** 提问索引侧栏 */
  @Builder
  queryDrawer() {
    Row() {
      Column() {
        Row() {
          Text('提问索引')
            .fontSize(theme.fs(FontSize.HEADING))
            .fontWeight(FontWeight.Medium)
            .fontColor(theme.palette.text)
          Blank()
          Text(`${this.queries().length}`)
            .fontSize(theme.fs(FontSize.TINY))
            .fontColor(theme.palette.textTertiary)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 18, bottom: 12 })

        Divider().strokeWidth(0.5).color(theme.palette.border)

        if (this.queries().length === 0) {
          Column() {
            Text('还没有提问')
              .fontSize(theme.fs(FontSize.LABEL))
              .fontColor(theme.palette.textTertiary)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.queries(), (q: QueryEntry) => {
              ListItem() {
                Row({ space: 10 }) {
                  Text(`${q.index}`)
                    .fontSize(theme.fs(FontSize.TINY))
                    .fontColor(theme.palette.textTertiary)
                    .width(20)
                    .textAlign(TextAlign.End)
                  Text(q.text)
                    .fontSize(theme.fs(FontSize.LABEL))
                    .fontColor(theme.palette.text)
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .alignItems(VerticalAlign.Top)
              }
              .onClick(() => this.jumpTo(q.itemId))
            }, (q: QueryEntry) => q.itemId)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .divider({ strokeWidth: 0.5, color: theme.palette.border })
        }
      }
      .width('78%')
      .height('100%')
      .backgroundColor(theme.palette.surface)

      // 右侧留白区点击关闭
      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor('#59000000')
        .onClick(() => { this.drawerOpen = false; })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  permissionSheet(req: PermissionRequest) {
    Column() {
      Column()
        .layoutWeight(1)
        .width('100%')
        .backgroundColor('#59000000')

      Column({ space: 14 }) {
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

  /**
   * 输入区。
   *
   * 用 TextArea 而不是 TextInput：回车换行而非发送。
   * 手机上写多行指令是常态，回车即发会让人不敢换行。
   * 高度随内容增长到上限后内部滚动，参照 GPT 的做法。
   */
  @Builder
  composer() {
    Row({ space: 8 }) {
      TextArea({ placeholder: '发送指令…', text: this.draft })
        .layoutWeight(1)
        .height(this.composerHeight)
        .constraintSize({ minHeight: COMPOSER_MIN_H, maxHeight: COMPOSER_MAX_H })
        .fontSize(theme.fs(FontSize.BODY))
        .fontColor(theme.palette.text)
        .placeholderColor(theme.palette.textTertiary)
        .backgroundColor(theme.palette.surfaceAlt)
        .borderRadius(20)
        .padding({ left: 14, right: 14, top: 11, bottom: 11 })
        .onChange((v: string) => {
          this.draft = v;
          this.recalcComposerHeight(v);
        })

      // 按钮固定 44 见方，和输入框底部对齐。
      // 之前它被压在 Row 末尾又没留右边距，窄屏上会被切掉一角。
      Column() {
        Blank()
        if (appStore.thinking) {
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
      .width(44)
      .height(this.composerHeight)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 14 })
    .alignItems(VerticalAlign.Bottom)
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
          } else if (appStore.itemCount === 0 && !appStore.thinking) {
            Column() {
              this.emptyState()
            }
            .layoutWeight(1)
            .width('100%')
          } else {
            List({ scroller: this.scroller }) {
              // LazyForEach 而非 ForEach：后者会把几百条消息一次性全部
              // 实例化，首屏卡顿。这里只建可见区域附近的。
              LazyForEach(appStore.itemSource, (item: ChatItem) => {
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

              ListItem() {
                Row().height(12)
              }
            }
            .layoutWeight(1)
            .width('100%')
            // 上下各多建 6 条，快速滑动时不会出现空白
            .cachedCount(6)
            // 右侧滑动杆：可拖动定位。长对话里一条条滑太慢
            .scrollBar(BarState.On)
            .scrollBarWidth(4)
            .scrollBarColor(theme.palette.border)
            .listDirection(Axis.Vertical)
          }

          this.composer()
        }
        .width('100%')
        .height('100%')
        .backgroundColor(theme.palette.bg)

        if (appStore.pendingPermission !== null) {
          this.permissionSheet(appStore.pendingPermission)
        }

        if (this.drawerOpen) {
          this.queryDrawer()
        }
      }
      .width('100%')
      .height('100%')
      .alignContent(Alignment.Bottom)
      // 从左边缘右滑打开提问索引
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: 24 })
          .onActionEnd((e: GestureEvent) => {
            if (e.offsetX > 60 && !this.drawerOpen) {
              this.drawerOpen = true;
            } else if (e.offsetX < -60 && this.drawerOpen) {
              this.drawerOpen = false;
            }
          })
      )
    }
    .hideTitleBar(true)
    .backgroundColor(theme.palette.bg)
  }
}
