/**
 * 路由宿主。
 *
 * 持有唯一的 NavPathStack，并根据是否已配对决定根页面：
 *   未配对 → 配对页
 *   已配对 → 项目列表
 *
 * 全部页面统一用状态管理 V2（@ComponentV2 / @Local / @Provider）。
 * 这一点不能和 V1 混：appStore 是 @ObservedV2 + @Trace，
 * 而 @Trace 的变更只对 @ComponentV2 生效 —— 用 V1 的 @Component 去读，
 * 首次渲染拿得到值，之后就再也不刷新了。
 */

import { common } from '@kit.AbilityKit';
import { tokenStore, Credentials } from '../store/TokenStore';
import { appStore } from '../store/AppStore';
import { apiClient } from '../net/ApiClient';
import { PairingView } from './Pairing';
import { ProjectListView } from './ProjectList';
import { SessionListView, SessionListParam } from './SessionList';
import { ChatView, ChatParam } from './Chat';

@Entry
@ComponentV2
struct Index {
  @Provider() pathStack: NavPathStack = new NavPathStack();

  /** 启动时先读凭据，读完之前不渲染内容，避免配对页一闪而过 */
  @Local ready: boolean = false;
  @Local paired: boolean = false;

  async aboutToAppear(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await tokenStore.init(ctx);

    const creds: Credentials | null = await tokenStore.load();
    if (creds !== null) {
      apiClient.configure(creds.host, creds.port, creds.token);
      appStore.serverName = creds.serverName;
      this.paired = true;
    }
    this.ready = true;
  }

  /** 配对成功后由配对页回调，切到项目列表 */
  onPaired(): void {
    this.paired = true;
  }

  @Builder
  destinations(name: string, param: object) {
    if (name === 'SessionList') {
      SessionListView({ param: param as SessionListParam })
    } else if (name === 'Chat') {
      ChatView({ param: param as ChatParam })
    }
  }

  build() {
    Navigation(this.pathStack) {
      if (!this.ready) {
        Column() {
          LoadingProgress().width(48).height(48)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else if (this.paired) {
        ProjectListView()
      } else {
        PairingView({ onPaired: (): void => this.onPaired() })
      }
    }
    .navDestination(this.destinations)
    .hideTitleBar(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
  }
}
