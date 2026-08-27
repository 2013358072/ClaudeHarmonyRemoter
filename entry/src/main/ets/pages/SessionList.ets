/**
 * 会话列表：某个项目下的历史会话，外加「开新会话」入口。
 *
 * 新建入口做成虚线卡片 —— 和实线的历史会话卡片形成"待填充 vs 已存在"
 * 的直觉对比，不用加图标或分组标题就能区分。
 */

import { apiClient, ApiException } from '../net/ApiClient';
import { SessionInfo } from '../net/Protocol';
import { ChatParam } from './Chat';
import { formatTimestamp } from '../utils/Format';
import { theme, FontSize, RUNNING_GREEN } from '../theme/Theme';

/** 路由参数 */
export interface SessionListParam {
  projectId: string;
  projectName: string;
}

@ComponentV2
export struct SessionListView {
  @Consumer() pathStack: NavPathStack = new NavPathStack();
  @Param param: SessionListParam = { projectId: '', projectName: '' };

  @Local sessions: SessionInfo[] = [];
  @Local loading: boolean = true;
  @Local errorText: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.errorText = '';
    try {
      this.sessions = await apiClient.listSessions(this.param.projectId);
    } catch (e) {
      this.errorText = (e as ApiException).message;
    } finally {
      this.loading = false;
    }
  }

  private openChat(sessionId: string, title: string): void {
    const p: ChatParam = {
      projectId: this.param.projectId,
      projectName: this.param.projectName,
      sessionId: sessionId,
      title: title
    };
    this.pathStack.pushPath({ name: 'Chat', param: p });
  }

  @Builder
  header() {
    Row({ space: 10 }) {
      Text('‹')
        .fontSize(theme.fs(28))
        .fontColor(theme.palette.text)
        .width(30)
        .textAlign(TextAlign.Center)
        .onClick(() => { this.pathStack.pop(); })

      Text(this.param.projectName)
        .fontSize(theme.fs(FontSize.HEADING))
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.palette.text)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 8, right: 20, top: 10, bottom: 12 })
  }

  @Builder
  newSessionCard() {
    Row({ space: 10 }) {
      Text('+')
        .fontSize(theme.fs(20))
        .fontColor(theme.palette.accent)
        .width(24)
        .textAlign(TextAlign.Center)
      Text('开始新会话')
        .fontSize(theme.fs(FontSize.BODY))
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.palette.accent)
      Blank()
    }
    .width('100%')
    .padding(15)
    .borderRadius(16)
    .backgroundColor(theme.palette.surface)
    .border({
      width: 1,
      color: theme.palette.accent,
      style: BorderStyle.Dashed
    })
    .onClick(() => this.openChat('', '新会话'))
  }

  @Builder
  sessionCard(item: SessionInfo) {
    // Stack 是为了把运行绿点压在卡片左上角
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 7 }) {
        Text(item.title)
          .fontSize(theme.fs(FontSize.BODY))
          .fontColor(theme.palette.text)
          .lineHeight(theme.fs(FontSize.BODY) * 1.45)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row({ space: 10 }) {
          if (item.running) {
            Text('运行中')
              .fontSize(theme.fs(FontSize.TINY))
              .fontColor(RUNNING_GREEN)
              .fontWeight(FontWeight.Medium)
          }

          Text(`${item.messageCount} 条`)
            .fontSize(theme.fs(FontSize.TINY))
            .fontColor(theme.palette.textTertiary)

          if (item.gitBranch.length > 0) {
            Text(item.gitBranch)
              .fontSize(theme.fs(FontSize.TINY))
              .fontColor(theme.palette.textSecondary)
              .padding({ left: 7, right: 7, top: 2, bottom: 2 })
              .borderRadius(5)
              .backgroundColor(theme.palette.surfaceAlt)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .constraintSize({ maxWidth: 110 })
          }

          Blank()
          Text(formatTimestamp(item.lastActiveAt))
            .fontSize(theme.fs(FontSize.TINY))
            .fontColor(theme.palette.textTertiary)
        }
        .width('100%')
      }
      .width('100%')
      .padding(15)
      .alignItems(HorizontalAlign.Start)

      if (item.running) {
        // 外圈用卡片底色描边，让绿点像贴在角上的徽标而不是一个色块
        Row()
          .width(9)
          .height(9)
          .borderRadius(5)
          .backgroundColor(RUNNING_GREEN)
          .border({ width: 2, color: theme.palette.surface })
          .margin({ left: 7, top: 7 })
      }
    }
    .width('100%')
    .borderRadius(16)
    .backgroundColor(theme.palette.surface)
    .border({
      width: 1,
      color: item.running ? RUNNING_GREEN : theme.palette.border
    })
  }

  build() {
    NavDestination() {
      Column() {
        this.header()

        if (this.loading) {
          Column() {
            LoadingProgress().width(36).height(36).color(theme.palette.accent)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.errorText.length > 0) {
          Column({ space: 14 }) {
            Text(this.errorText)
              .fontSize(theme.fs(FontSize.LABEL))
              .fontColor(theme.palette.textSecondary)
              .textAlign(TextAlign.Center)
            Button('重试')
              .height(40)
              .fontSize(theme.fs(FontSize.LABEL))
              .fontColor(theme.palette.onAccent)
              .backgroundColor(theme.palette.accent)
              .borderRadius(20)
              .padding({ left: 26, right: 26 })
              .onClick(() => {
                this.loading = true;
                this.load();
              })
          }
          .layoutWeight(1)
          .width('100%')
          .padding(36)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 10 }) {
            ListItem() {
              this.newSessionCard()
            }

            ForEach(this.sessions, (item: SessionInfo) => {
              ListItem() {
                this.sessionCard(item)
              }
              .onClick(() => this.openChat(item.sessionId, item.title))
            }, (item: SessionInfo) => item.sessionId)

            ListItem() {
              Row().height(8)
            }
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 16, right: 16 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(theme.palette.bg)
    }
    .hideTitleBar(true)
    .backgroundColor(theme.palette.bg)
  }
}
