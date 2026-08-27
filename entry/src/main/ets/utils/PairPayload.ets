/**
 * 配对二维码的载荷解析。
 *
 * 服务端打印的二维码内容形如：
 *   chr://pair?host=192.168.1.10&port=4517&code=123456
 * 见 server/src/index.ts 的 printBanner。
 *
 * 解析放在独立文件是为了能被单独推敲：扫码得到的是外部输入，
 * 任何字段都可能缺失或畸形，不该在界面代码里边渲染边校验。
 */

export class PairPayload {
  host: string = '';
  port: number = 0;
  code: string = '';

  constructor(host: string, port: number, code: string) {
    this.host = host;
    this.port = port;
    this.code = code;
  }
}

/** 自己解析 query，不依赖 URL 类 —— ArkTS 侧对它的支持不稳定 */
function parseQuery(q: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const pair of q.split('&')) {
    if (pair.length === 0) {
      continue;
    }
    const i = pair.indexOf('=');
    if (i <= 0) {
      continue;
    }
    const k = pair.substring(0, i);
    const v = pair.substring(i + 1);
    out.set(k, decodeURIComponent(v));
  }
  return out;
}

/**
 * 解析扫码结果。
 *
 * 宽松对待前缀：只要能取到 host 和 code 就认，不强求 scheme 完全匹配 ——
 * 二维码可能被别的扫码 App 转手过一道，或者用户从别处复制了链接。
 * 但字段本身严格校验，畸形值宁可判定失败也不要带着错数据往下走。
 */
export function parsePairPayload(raw: string): PairPayload | null {
  const s = raw.trim();
  if (s.length === 0) {
    return null;
  }

  const qi = s.indexOf('?');
  if (qi < 0) {
    return null;
  }
  const params = parseQuery(s.substring(qi + 1));

  const host = (params.get('host') ?? '').trim();
  const code = (params.get('code') ?? '').trim();
  if (host.length === 0 || code.length === 0) {
    return null;
  }

  const portRaw = (params.get('port') ?? '').trim();
  const port = Number.parseInt(portRaw, 10);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    return null;
  }

  // 配对码固定 6 位数字，不符就不是我们的码
  if (code.length !== 6) {
    return null;
  }
  for (let i = 0; i < code.length; i++) {
    const c = code.charAt(i);
    if (c < '0' || c > '9') {
      return null;
    }
  }

  return new PairPayload(host, port, code);
}
