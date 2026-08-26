/**
 * 会话列表：某个项目下的历史会话，外加「开新会话」入口。
 */

import { apiClient, ApiException } from '../net/ApiClient';
import { SessionInfo } from '../net/Protocol';
import { ChatParam } from './Chat';
import { formatRelativeTime } from '../utils/Format';

/** 路由参数 */
export interface SessionListParam {
  projectId: string;
  projectName: string;
}

@Component
export struct SessionListView {
  @Consume('pathStack') pathStack: NavPathStack;
  param: SessionListParam = { projectId: '', projectName: '' };

  @State sessions: SessionInfo[] = [];
  @State loading: boolean = true;
  @State errorText: string = '';

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
  sessionRow(item: SessionInfo) {
    Column({ space: 4 }) {
      Text(item.title)
        .fontSize(16)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Row({ space: 8 }) {
        Text(`${item.messageCount} 条`)
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
        if (item.gitBranch.length > 0) {
          Text(item.gitBranch)
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
        }
        Blank()
        Text(formatRelativeTime(item.lastActiveAt))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    NavDestination() {
      Column() {
        // ---- 新建会话 ----
        Row({ space: 8 }) {
          Text('＋').fontSize(20).fontColor($r('sys.color.font_emphasize'))
          Text('开始新会话')
            .fontSize(16)
            .fontColor($r('sys.color.font_emphasize'))
        }
        .width('100%')
        .padding(16)
        .onClick(() => this.openChat('', '新会话'))

        Divider().strokeWidth(0.5).color($r('sys.color.comp_divider'))

        if (this.loading) {
          Column() {
            LoadingProgress().width(40).height(40)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.errorText.length > 0) {
          Column({ space: 12 }) {
            Text(this.errorText).fontSize(14).textAlign(TextAlign.Center)
            Button('重试').onClick(() => {
              this.loading = true;
              this.load();
            })
          }
          .layoutWeight(1)
          .width('100%')
          .padding(32)
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            ForEach(this.sessions, (item: SessionInfo) => {
              ListItem() {
                this.sessionRow(item)
              }
              .onClick(() => this.openChat(item.sessionId, item.title))
            }, (item: SessionInfo) => item.sessionId)
          }
          .layoutWeight(1)
          .width('100%')
          .divider({ strokeWidth: 0.5, color: $r('sys.color.comp_divider') })
        }
      }
      .width('100%')
      .height('100%')
    }
    .title(this.param.projectName)
  }
}
