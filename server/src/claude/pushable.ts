/**
 * 可外部推送的异步迭代器。
 *
 * Agent SDK 的 query() 接受一个 AsyncIterable 作为 prompt，
 * 只要这个迭代器不结束，query 就会一直活着等下一条用户消息 ——
 * 这正是"一个长驻会话，手机随时发消息"所需要的形态。
 *
 * 换句话说：这个类是"HTTP 请求驱动"和"异步迭代驱动"之间的转接头。
 */

export class PushableAsyncIterable<T> implements AsyncIterableIterator<T> {
    /** 已推入但还没被消费的值 */
    private queue: T[] = [];
    /** 已在等待、但队列为空的消费者 */
    private waiters: Array<(result: IteratorResult<T>) => void> = [];
    private closed = false;

    push(value: T): void {
        if (this.closed) {
            throw new Error('迭代器已关闭，不能再推送');
        }
        const waiter = this.waiters.shift();
        if (waiter) {
            // 有消费者在等，直接交付，不进队列
            waiter({ done: false, value });
        } else {
            this.queue.push(value);
        }
    }

    /** 结束迭代，query() 会随之正常收尾 */
    close(): void {
        if (this.closed) return;
        this.closed = true;
        // 唤醒所有还在等的消费者
        for (const waiter of this.waiters) {
            waiter({ done: true, value: undefined });
        }
        this.waiters = [];
    }

    async next(): Promise<IteratorResult<T>> {
        const queued = this.queue.shift();
        if (queued !== undefined) {
            return { done: false, value: queued };
        }
        if (this.closed) {
            return { done: true, value: undefined };
        }
        return new Promise<IteratorResult<T>>((resolve) => {
            this.waiters.push(resolve);
        });
    }

    async return(): Promise<IteratorResult<T>> {
        this.close();
        return { done: true, value: undefined };
    }

    [Symbol.asyncIterator](): AsyncIterableIterator<T> {
        return this;
    }
}
