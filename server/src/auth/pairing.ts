/**
 * 配对码：一次性、短期有效的 6 位数字码，用来把长期 token 交给手机。
 *
 * 流程：
 *   服务端启动 → 生成配对码并打印到终端（含二维码）
 *   手机 POST /api/pair {code, deviceName} → 校验通过 → 签发 token
 *   配对码立即作废，并生成下一个，方便再配对第二台设备
 */

import { randomInt, timingSafeEqual } from 'node:crypto';

export interface PairingCode {
    code: string;
    expiresAt: number;
}

export class PairingManager {
    private current: PairingCode | null = null;
    private readonly ttlMs: number;
    /** 连续失败计数，用于简单的暴力破解限速 */
    private failures = 0;
    private lockedUntil = 0;

    constructor(ttlMs: number) {
        this.ttlMs = ttlMs;
    }

    /** 生成一个新的配对码，覆盖旧的 */
    rotate(): PairingCode {
        // randomInt 是密码学安全的，不要用 Math.random
        const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
        this.current = { code, expiresAt: Date.now() + this.ttlMs };
        this.failures = 0;
        this.lockedUntil = 0;
        return this.current;
    }

    /** 当前配对码，已过期则返回 null */
    peek(): PairingCode | null {
        if (!this.current) return null;
        if (Date.now() > this.current.expiresAt) return null;
        return this.current;
    }

    /**
     * 校验配对码。成功后配对码立即作废。
     *
     * 返回值区分几种失败原因，方便客户端给出准确提示。
     */
    consume(
        input: string,
    ): { ok: true } | { ok: false; reason: 'locked' | 'expired' | 'mismatch' } {
        const now = Date.now();

        if (now < this.lockedUntil) {
            return { ok: false, reason: 'locked' };
        }
        const active = this.peek();
        if (!active) {
            return { ok: false, reason: 'expired' };
        }

        const a = Buffer.from(input.trim());
        const b = Buffer.from(active.code);
        const matched = a.length === b.length && timingSafeEqual(a, b);

        if (!matched) {
            this.failures += 1;
            // 连错 5 次锁 60 秒。6 位码空间只有 100 万，不限速会被轻易穷举
            if (this.failures >= 5) {
                this.lockedUntil = now + 60_000;
                this.failures = 0;
            }
            return { ok: false, reason: 'mismatch' };
        }

        this.current = null;
        this.failures = 0;
        return { ok: true };
    }
}
