/**
 * LazyForEach 用的通用数据源。
 *
 * 为什么必须用 LazyForEach 而不是 ForEach：
 * ArkUI 的 ForEach 会把**所有**子组件一次性实例化，没有虚拟化。
 * 110 个项目卡片、几百条聊天消息全部建出来，首屏卡顿和内存占用
 * 都是实打实的 —— 接口再快也救不了渲染。
 * LazyForEach 只建可见区域附近的，配合 cachedCount 预留缓冲。
 *
 * 注意 IDataSource 的实现类**不要**去 implements DataChangeListener：
 * API 21 起那个接口要求同时实现新旧两套方法名（onDataAdd 和
 * onDataAdded 等），少一个都编译不过。这里只持有监听器，不实现它。
 */

export class LazyDataSource<T> implements IDataSource {
  private items: T[] = [];
  private listeners: DataChangeListener[] = [];

  // -------------------------------------------------------------------------
  // IDataSource
  // -------------------------------------------------------------------------

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }

  // -------------------------------------------------------------------------
  // 变更入口
  // -------------------------------------------------------------------------

  /** 整体替换。用于首次加载和刷新 */
  setAll(next: T[]): void {
    this.items = next;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }

  /** 追加一条。只通知增量，不会让整个列表重建 */
  append(item: T): void {
    this.items.push(item);
    const at = this.items.length - 1;
    for (const l of this.listeners) {
      l.onDataAdd(at);
    }
  }

  /** 某条内容变了（比如工具事件从 running 变 ok） */
  notifyChange(index: number): void {
    if (index < 0 || index >= this.items.length) {
      return;
    }
    for (const l of this.listeners) {
      l.onDataChange(index);
    }
  }

  clear(): void {
    this.items = [];
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }

  /** 只读访问，供上层做查找、统计等 */
  all(): T[] {
    return this.items;
  }

  isEmpty(): boolean {
    return this.items.length === 0;
  }
}
