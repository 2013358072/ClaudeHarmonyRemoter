/**
 * 展示层的格式化工具。
 */

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

/** 把时间戳转成「刚刚 / 5 分钟前 / 3 小时前 / 2 天前 / 具体日期」 */
export function formatRelativeTime(ts: number): string {
  if (ts <= 0) {
    return '';
  }
  const diff = Date.now() - ts;

  if (diff < MINUTE) {
    return '刚刚';
  }
  if (diff < HOUR) {
    return `${Math.floor(diff / MINUTE)} 分钟前`;
  }
  if (diff < DAY) {
    return `${Math.floor(diff / HOUR)} 小时前`;
  }
  if (diff < 7 * DAY) {
    return `${Math.floor(diff / DAY)} 天前`;
  }

  const d = new Date(ts);
  const month = d.getMonth() + 1;
  return `${month}月${d.getDate()}日`;
}

/** 耗时：小于 1 秒显示毫秒，否则显示秒 */
export function formatDuration(ms: number): string {
  if (ms < 1000) {
    return `${ms}ms`;
  }
  return `${(ms / 1000).toFixed(1)}s`;
}

/** 花费：保留 4 位小数，太小就显示 <$0.0001 */
export function formatCost(usd: number): string {
  if (usd <= 0) {
    return '';
  }
  if (usd < 0.0001) {
    return '<$0.0001';
  }
  return `$${usd.toFixed(4)}`;
}
