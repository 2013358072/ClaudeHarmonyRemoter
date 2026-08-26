/**
 * 路由宿主。
 *
 * 持有唯一的 NavPathStack，并根据是否已配对决定根页面：
 *   未配对 → 配对页
 *   已配对 → 项目列表
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
@Component
struct Index {
  @Provide('pathStack') pathStack: NavPathStack = new NavPathStack();

  /** 启动时先读凭据，读完之前不渲染内容，避免配对页一闪而过 */
  @State ready: boolean = false;
  @State paired: boolean = false;

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
