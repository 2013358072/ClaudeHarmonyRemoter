/**
 * 长期访问 token 的签发、校验与持久化。
 *
 * token 是 32 字节随机数的 base64url 编码，落盘在 <dataDir>/tokens.json。
 * 校验用 timingSafeEqual，避免因比较耗时泄漏信息。
 */

import { randomBytes, timingSafeEqual } from 'node:crypto';
import { join } from 'node:path';
import { mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';

export interface DeviceToken {
    /** token 本体 */
    token: string;
    /** 设备展示名，由客户端配对时上报 */
    deviceName: string;
    /** 签发时间戳 */
    createdAt: number;
    /** 最近一次使用时间戳 */
    lastSeenAt: number;
}

interface TokenFile {
    version: 1;
    tokens: DeviceToken[];
}

const EMPTY: TokenFile = { version: 1, tokens: [] };

export class TokenStore {
    private readonly filePath: string;
    private data: TokenFile = EMPTY;
    /** token -> 记录，避免每次校验都遍历数组 */
    private index = new Map<string, DeviceToken>();

    constructor(dataDir: string) {
        this.filePath = join(dataDir, 'tokens.json');
        mkdirSync(dataDir, { recursive: true });
        this.load();
    }

    private load(): void {
        if (!existsSync(this.filePath)) {
            this.data = { version: 1, tokens: [] };
            this.reindex();
            return;
        }
        try {
            const parsed: unknown = JSON.parse(readFileSync(this.filePath, 'utf8'));
            const tokens =
                typeof parsed === 'object' &&
                parsed !== null &&
                Array.isArray((parsed as TokenFile).tokens)
                    ? (parsed as TokenFile).tokens
                    : [];
            this.data = { version: 1, tokens };
        } catch (e) {
            console.warn(`[auth] 读取 ${this.filePath} 失败，将以空列表启动：`, e);
            this.data = { version: 1, tokens: [] };
        }
        this.reindex();
    }

    private reindex(): void {
        this.index = new Map(this.data.tokens.map((t) => [t.token, t]));
    }

    private persist(): void {
        // mode 0600：token 等价于服务器的远程执行权限，不能让同机其他用户读到
        writeFileSync(this.filePath, JSON.stringify(this.data, null, 2), {
            mode: 0o600,
        });
    }

    /** 签发一个新 token */
    issue(deviceName: string): DeviceToken {
        const now = Date.now();
        const record: DeviceToken = {
            token: randomBytes(32).toString('base64url'),
            deviceName: deviceName.slice(0, 64) || '未命名设备',
            createdAt: now,
            lastSeenAt: now,
        };
        this.data.tokens.push(record);
        this.index.set(record.token, record);
        this.persist();
        return record;
    }

    /**
     * 校验 token。命中则更新 lastSeenAt 并返回记录，否则返回 null。
     *
     * 先用 Map 查找（O(1)），再对命中项做一次 timingSafeEqual 确认。
     * Map 查找本身不是常量时间，但 token 有 256 bit 熵，
     * 靠时序爆破不现实；这里的 timingSafeEqual 主要防御长度截断类构造。
     */
    verify(token: string | undefined): DeviceToken | null {
        if (!token) return null;
        const record = this.index.get(token);
        if (!record) return null;

        const a = Buffer.from(token);
        const b = Buffer.from(record.token);
        if (a.length !== b.length || !timingSafeEqual(a, b)) return null;

        record.lastSeenAt = Date.now();
        // lastSeenAt 每次请求都变，不必每次落盘，退出时或撤销时再写
        return record;
    }

    /** 撤销一个 token */
    revoke(token: string): boolean {
        if (!this.index.delete(token)) return false;
        this.data.tokens = this.data.tokens.filter((t) => t.token !== token);
        this.persist();
        return true;
    }

    list(): readonly DeviceToken[] {
        return this.data.tokens;
    }

    /** 把内存里的 lastSeenAt 落盘，进程退出前调用 */
    flush(): void {
        this.persist();
    }
}
