/**
 * 路由宿主 + 底部导航。
 *
 * 结构：Navigation 包住 Tabs。
 *   根内容 = Tabs（对话 / 我的）
 *   会话列表和聊天页作为 NavDestination 压在上面，会盖住 Tab 栏
 *
 * 这样安排是因为聊天是沉浸式场景 —— 进到具体对话里不该再看到导航栏
 * 抢占本就不多的垂直空间。
 *
 * 全部页面统一用状态管理 V2（@ComponentV2 / @Local / @Provider）。
 * 这一点不能和 V1 混：appStore 和 theme 都是 @ObservedV2 + @Trace，
 * 而 @Trace 的变更只对 @ComponentV2 生效 —— 用 V1 的 @Component 去读，
 * 首次渲染拿得到值，之后就再也不刷新了，且不报任何错。
 */

import { common } from '@kit.AbilityKit';
import { tokenStore, Credentials } from '../store/TokenStore';
import { appStore } from '../store/AppStore';
import { apiClient } from '../net/ApiClient';
import { theme, FontSize } from '../theme/Theme';
import { projectPrefs } from '../store/ProjectPrefs';
import { PairingView } from './Pairing';
import { ProjectListView } from './ProjectList';
import { ProfileView } from './Profile';
import { SessionListView, SessionListParam } from './SessionList';
import { ChatView, ChatParam } from './Chat';

@Entry
@ComponentV2
struct Index {
  @Provider() pathStack: NavPathStack = new NavPathStack();

  /** 启动时先读凭据，读完之前不渲染内容，避免配对页一闪而过 */
  @Local ready: boolean = false;
  @Local paired: boolean = false;
  @Local currentTab: number = 0;

  private tabsController: TabsController = new TabsController();

  async aboutToAppear(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    // 主题要先于界面就位，否则会先闪一下默认配色
    await theme.init(ctx);
    await projectPrefs.init(ctx);
    await tokenStore.init(ctx);

    const creds: Credentials | null = await tokenStore.load();
    if (creds !== null) {
      apiClient.configure(creds.host, creds.port, creds.token);
      appStore.serverName = creds.serverName;
      this.paired = true;
    }
    this.ready = true;
  }

  onPaired(): void {
    this.paired = true;
    this.currentTab = 0;
  }

  async onSignOut(): Promise<void> {
    await tokenStore.clear();
    appStore.serverName = '';
    this.paired = false;
    this.currentTab = 0;
  }

  @Builder
  tabBar(index: number, label: string, icon: Resource, iconActive: Resource) {
    Column({ space: 3 }) {
      Image(this.currentTab === index ? iconActive : icon)
        .width(24)
        .height(24)
        // SVG 用 fillColor 染色，一套图标适配三种主题
        .fillColor(
          this.currentTab === index ? theme.palette.accent : theme.palette.textTertiary
        )
      Text(label)
        .fontSize(theme.fs(FontSize.TINY))
        .fontColor(
          this.currentTab === index ? theme.palette.accent : theme.palette.textTertiary
        )
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  destinations(name: string, param: object) {
    if (name === 'SessionList') {
      SessionListView({ param: param as SessionListParam })
    } else if (name === 'Chat') {
      ChatView({ param: param as ChatParam })
    }
  }

  @Builder
  rootContent() {
    if (!this.ready) {
      Column() {
        LoadingProgress().width(44).height(44).color(theme.palette.accent)
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(theme.palette.bg)
    } else if (!this.paired) {
      // 未配对时不显示 Tab —— 此时「我的」里没有任何有意义的内容
      PairingView({ onPaired: (): void => this.onPaired() })
    } else {
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
        TabContent() {
          ProjectListView()
        }
        .tabBar(this.tabBar(0, '对话', $r('app.media.ic_chat'), $r('app.media.ic_chat_fill')))

        TabContent() {
          ProfileView({ onSignOut: (): Promise<void> => this.onSignOut() })
        }
        .tabBar(this.tabBar(1, '我的', $r('app.media.ic_profile'), $r('app.media.ic_profile_fill')))
      }
      .barHeight(58)
      .barBackgroundColor(theme.palette.navBg)
      .barMode(BarMode.Fixed)
      .scrollable(false)
      .divider({
        strokeWidth: 0.5,
        color: theme.palette.border
      })
      .onChange((index: number) => { this.currentTab = index; })
      .width('100%')
      .height('100%')
      .backgroundColor(theme.palette.bg)
    }
  }

  build() {
    Navigation(this.pathStack) {
      this.rootContent()
    }
    .navDestination(this.destinations)
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .backgroundColor(theme.palette.bg)
  }
}
