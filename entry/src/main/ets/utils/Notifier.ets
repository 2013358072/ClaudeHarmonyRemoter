/**
 * 本地通知。
 *
 * 用途很具体：你发出一条指令后把 App 切到后台，Claude 需要授权
 * 或者干完了，这时候提醒你一下。这是远程操控最需要通知的场景 ——
 * 长任务本来就该让人走开，而不是盯着屏幕等。
 *
 * ⚠ 这是**本地通知**，不是 Push Kit 的远程推送。
 * App 进程被系统回收后收不到 —— 真正的离线推送需要接入华为 Push Kit，
 * 涉及 AGC 应用配置和服务端下发 token，是另一个量级的工作。
 * 当前实现覆盖"切后台等结果"这个主要场景，代价是诚实可控。
 *
 * 几个 API 21 起的坑（都会导致编译失败，见 SKILL 的踩坑清单）：
 *  - addSlot 传 SlotType 枚举，不是 NotificationSlot 对象
 *  - 枚举常量必须显式标注类型，否则会窄化成字面量类型
 *  - NotificationRequest.slotType 和 notificationManager.SlotType
 *    是两个模块的同名类型，互不兼容 —— 直接省略这个字段
 */

import { notificationManager } from '@kit.NotificationKit';

/** 显式标注，否则会被窄化成字面量类型而无法赋给 SlotType */
const SLOT: notificationManager.SlotType =
  notificationManager.SlotType.SOCIAL_COMMUNICATION;

/**
 * 通知 id 分配。
 *
 * 同一项目复用同一个 id，新的会覆盖旧的 —— 一个项目在通知栏里
 * 只留最新一条，不该堆成一串。
 */
const idMap = new Map<string, number>();
let nextId = 1000;

function idFor(key: string): number {
  const got = idMap.get(key);
  if (got !== undefined) {
    return got;
  }
  nextId += 1;
  idMap.set(key, nextId);
  return nextId;
}

export class Notifier {
  private ready: boolean = false;
  private slotAdded: boolean = false;

  /**
   * 首次发通知前调用。
   *
   * 权限没开就返回 false，调用方据此提示用户 ——
   * 静默失败会让人以为功能坏了。
   */
  async ensureReady(): Promise<boolean> {
    if (this.ready) {
      return true;
    }
    try {
      if (!this.slotAdded) {
        await notificationManager.addSlot(SLOT);
        this.slotAdded = true;
      }
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification();
      }
      this.ready = await notificationManager.isNotificationEnabled();
      return this.ready;
    } catch (_e) {
      // 模拟器或未授权环境下会抛，此时静默降级即可
      return false;
    }
  }

  /** 发一条通知。key 相同的会互相覆盖 */
  async post(key: string, title: string, text: string): Promise<void> {
    const ok = await this.ensureReady();
    if (!ok) {
      return;
    }
    const request: notificationManager.NotificationRequest = {
      id: idFor(key),
      // 刻意省略 slotType：它的类型来自旧模块，和 addSlot 用的新模块
      // 同名但不兼容，写上去编译不过。省略后会自动路由到已建的 slot
      content: {
        notificationContentType:
          notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: { title: title, text: text }
      },
      deliveryTime: Date.now(),
      showDeliveryTime: true,
      tapDismissed: true
    };
    try {
      await notificationManager.publish(request);
    } catch (_e) {
      // 发送失败不该影响对话本身
    }
  }

  /** 收起某个项目的通知，比如用户回到了那个会话 */
  async clear(key: string): Promise<void> {
    const got = idMap.get(key);
    if (got === undefined) {
      return;
    }
    try {
      await notificationManager.cancel(got);
    } catch (_e) {
      // 没有对应通知时会抛，忽略
    }
  }
}

/** 全局单例 */
export const notifier: Notifier = new Notifier();
