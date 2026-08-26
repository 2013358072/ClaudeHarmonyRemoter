/**
 * 项目列表：服务器上有 Claude 会话记录的项目。
 *
 * 列表用卡片而不是通栏分割线 —— 每个项目带路径和会话数两行副信息，
 * 通栏排下来密度太高，卡片之间的留白能让扫读更轻松。
 */

import { apiClient, ApiException } from '../net/ApiClient';
import { appStore } from '../store/AppStore';
import { tokenStore } from '../store/TokenStore';
import { ProjectInfo } from '../net/Protocol';
import { SessionListParam } from './SessionList';
import { formatRelativeTime } from '../utils/Format';
import { theme, FontSize } from '../theme/Theme';

@ComponentV2
export struct ProjectListView {
  @Consumer() pathStack: NavPathStack = new NavPathStack();
  @Local projects: ProjectInfo[] = [];
  @Local loading: boolean = true;
  @Local errorText: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.errorText = '';
    try {
      this.projects = await apiClient.listProjects();
    } catch (e) {
      const err = e as ApiException;
      // token 失效就清掉凭据，下次启动会回到配对页
      if (err.isUnauthorized()) {
        await tokenStore.clear();
        this.errorText = '登录已失效，请重启应用重新配对';
      } else {
        this.errorText = err.message;
      }
    } finally {
      this.loading = false;
    }
  }

  @Builder
  projectCard(item: ProjectInfo) {
    Row({ space: 12 }) {
      // 首字母方块，给列表一个视觉锚点
      Text(item.name.substring(0, 1).toUpperCase())
        .fontSize(theme.fs(FontSize.HEADING))
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.palette.accent)
        .width(42)
        .height(42)
        .textAlign(TextAlign.Center)
        .borderRadius(12)
        .backgroundColor(theme.palette.surfaceAlt)

      Column({ space: 3 }) {
        Row() {
          Text(item.name)
            .fontSize(theme.fs(FontSize.BODY))
            .fontWeight(FontWeight.Medium)
            .fontColor(theme.palette.text)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(formatRelativeTime(item.lastActiveAt))
            .fontSize(theme.fs(FontSize.TINY))
            .fontColor(theme.palette.textTertiary)
        }
        .width('100%')

        Text(item.path)
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(`${item.sessionCount} 个会话`)
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.textSecondary)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(14)
    .borderRadius(16)
    .backgroundColor(theme.palette.surface)
    .border({ width: 1, color: theme.palette.border })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  placeholder(text: string, showRetry: boolean) {
    Column({ space: 14 }) {
      Text(text)
        .fontSize(theme.fs(FontSize.LABEL))
        .fontColor(theme.palette.textSecondary)
        .textAlign(TextAlign.Center)
      if (showRetry) {
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
    }
    .layoutWeight(1)
    .width('100%')
    .padding(36)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      // ---- 标题 ----
      Row() {
        Column({ space: 2 }) {
          Text('对话')
            .fontSize(theme.fs(FontSize.TITLE))
            .fontWeight(FontWeight.Bold)
            .fontColor(theme.palette.text)
          if (appStore.serverName.length > 0) {
            Text(appStore.serverName)
              .fontSize(theme.fs(FontSize.TINY))
              .fontColor(theme.palette.textTertiary)
          }
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 14 })

      if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color(theme.palette.accent)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.errorText.length > 0) {
        this.placeholder(this.errorText, true)
      } else if (this.projects.length === 0) {
        this.placeholder('服务器上还没有 Claude 会话记录', true)
      } else {
        List({ space: 10 }) {
          ForEach(this.projects, (item: ProjectInfo) => {
            ListItem() {
              this.projectCard(item)
            }
            .onClick(() => {
              const param: SessionListParam = {
                projectId: item.id,
                projectName: item.name
              };
              this.pathStack.pushPath({ name: 'SessionList', param: param });
            })
          }, (item: ProjectInfo) => item.id)

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
}
