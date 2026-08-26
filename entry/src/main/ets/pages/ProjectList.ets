/**
 * 项目列表：服务器上有 Claude 会话记录的项目。
 */

import { apiClient, ApiException } from '../net/ApiClient';
import { appStore } from '../store/AppStore';
import { tokenStore } from '../store/TokenStore';
import { ProjectInfo } from '../net/Protocol';
import { SessionListParam } from './SessionList';
import { formatRelativeTime } from '../utils/Format';

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
  projectRow(item: ProjectInfo) {
    Column({ space: 4 }) {
      Row() {
        Text(item.name)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(formatRelativeTime(item.lastActiveAt))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')

      Text(item.path)
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      Text(`${item.sessionCount} 个会话`)
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      // ---- 标题栏 ----
      Row() {
        Column({ space: 2 }) {
          Text('项目').fontSize(24).fontWeight(FontWeight.Bold)
          if (appStore.serverName.length > 0) {
            Text(appStore.serverName)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })

      if (this.loading) {
        Column() {
          LoadingProgress().width(40).height(40)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.errorText.length > 0) {
        Column({ space: 12 }) {
          Text(this.errorText)
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .textAlign(TextAlign.Center)
          Button('重试').onClick(() => {
            this.loading = true;
            this.load();
          })
        }
        .layoutWeight(1)
        .width('100%')
        .padding(32)
        .justifyContent(FlexAlign.Center)
      } else if (this.projects.length === 0) {
        Column() {
          Text('服务器上还没有 Claude 会话记录')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.projects, (item: ProjectInfo) => {
            ListItem() {
              this.projectRow(item)
            }
            .onClick(() => {
              const param: SessionListParam = {
                projectId: item.id,
                projectName: item.name
              };
              this.pathStack.pushPath({ name: 'SessionList', param: param });
            })
          }, (item: ProjectInfo) => item.id)
        }
        .layoutWeight(1)
        .width('100%')
        .divider({ strokeWidth: 0.5, color: $r('sys.color.comp_divider') })
      }
    }
    .width('100%')
    .height('100%')
  }
}
