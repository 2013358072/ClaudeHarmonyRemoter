/**
 * 展示层的格式化工具。
 */

const MINUTE = 60 * 1000;
/** 3 分钟以内算「刚刚」 */
const JUST_NOW = 3 * MINUTE;

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

/**
 * 时间戳格式化。
 *
 * 显示**实际时间**而不是「几小时前」—— 相对时间读起来要在脑子里做一次
 * 减法才知道具体是什么时候，而用户看会话列表时通常想知道的是
 * "这是今天下午那次还是昨天那次"。
 *
 * 只有 3 分钟以内例外，显示「刚刚」：这个区间说时:分反而累赘，
 * 且这时候用户关心的确实是"就在不久前"这个模糊概念。
 *
 * 规则：
 *   3 分钟内   刚刚
 *   今天       14:32
 *   昨天       昨天 14:32
 *   今年       8月26日 14:32
 *   更早       2025/8/26
 */
export function formatTimestamp(ts: number): string {
  if (ts <= 0) {
    return '';
  }

  const now = new Date();
  const d = new Date(ts);
  const diff = now.getTime() - ts;

  if (diff >= 0 && diff < JUST_NOW) {
    return '刚刚';
  }

  const hm = `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;

  // 按日历日比较，不用 24 小时窗口 —— 凌晨 1 点看昨晚 11 点的会话，
  // 说「昨天 23:00」比说「2 小时前」更符合直觉
  const sameDay = d.getFullYear() === now.getFullYear()
    && d.getMonth() === now.getMonth()
    && d.getDate() === now.getDate();
  if (sameDay) {
    return hm;
  }

  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
  const isYesterday = d.getFullYear() === yesterday.getFullYear()
    && d.getMonth() === yesterday.getMonth()
    && d.getDate() === yesterday.getDate();
  if (isYesterday) {
    return `昨天 ${hm}`;
  }

  if (d.getFullYear() === now.getFullYear()) {
    return `${d.getMonth() + 1}月${d.getDate()}日 ${hm}`;
  }

  return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`;
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
