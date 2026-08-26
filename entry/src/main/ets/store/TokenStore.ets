/**
 * 连接凭据的本地持久化。
 *
 * 存的是服务器地址 + 长期 token，配对成功后写入，
 * 之后每次启动直接读出来用，不必重复配对。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME = 'claude_harmony_conn';

const KEY_HOST = 'host';
const KEY_PORT = 'port';
const KEY_TOKEN = 'token';
const KEY_SERVER_NAME = 'serverName';

export interface Credentials {
  host: string;
  port: number;
  token: string;
  serverName: string;
}

export class TokenStore {
  private store: preferences.Preferences | null = null;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, STORE_NAME);
  }

  /** 读取已保存的凭据，没有则返回 null */
  async load(): Promise<Credentials | null> {
    if (this.store === null) {
      return null;
    }
    const host = await this.store.get(KEY_HOST, '') as string;
    const token = await this.store.get(KEY_TOKEN, '') as string;
    // host 和 token 缺一不可，任一为空都视为未配对
    if (host.length === 0 || token.length === 0) {
      return null;
    }
    const port = await this.store.get(KEY_PORT, 4517) as number;
    const serverName = await this.store.get(KEY_SERVER_NAME, '') as string;

    return {
      host: host,
      port: port,
      token: token,
      serverName: serverName
    } as Credentials;
  }

  async save(creds: Credentials): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.put(KEY_HOST, creds.host);
    await this.store.put(KEY_PORT, creds.port);
    await this.store.put(KEY_TOKEN, creds.token);
    await this.store.put(KEY_SERVER_NAME, creds.serverName);
    await this.store.flush();
  }

  /** 清除凭据，用于「退出登录」或 token 失效时 */
  async clear(): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.clear();
    await this.store.flush();
  }
}

/** 全局单例：整个 App 只需要一份凭据 */
export const tokenStore: TokenStore = new TokenStore();
