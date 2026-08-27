/**
 * App 前后台状态。
 *
 * 为什么需要它：判断"该不该发通知"必须知道 App 是否在前台，
 * 而组件级的 onPageShow / onPageHide **只对 @Entry 组件生效**。
 * 聊天页是 NavDestination，写了那两个回调也永远不会被调用 ——
 * 表现就是通知功能看似接好了却一条都发不出来，且不报任何错。
 *
 * 真正的前后台信号只有 UIAbility 的 onForeground / onBackground，
 * 所以由 EntryAbility 往这里写，界面从这里读。
 */

@ObservedV2
export class AppLifecycle {
  /** 初始为 true：App 能跑起来说明它就在前台 */
  @Trace foreground: boolean = true;

  setForeground(v: boolean): void {
    this.foreground = v;
  }
}

/** 全局单例 */
export const appLifecycle: AppLifecycle = new AppLifecycle();
