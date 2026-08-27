/**
 * 轻量 Markdown 解析。
 *
 * 只解析成结构，不负责渲染 —— 渲染交给 ArkUI 的 Text/Span 组合。
 * 没有引第三方库：ArkTS 生态里的 markdown 库要么依赖 DOM，要么体积
 * 远超需要。模型回复用到的语法其实很有限，自己解析反而可控。
 *
 * 支持：标题、代码块、引用、有序/无序列表、分割线、表格、段落，
 * 行内支持 **粗体**、*斜体*、`代码`、[文字](链接)。
 * 不支持嵌套列表 —— 手机窄屏上本来也难读。
 */

/** 块级类型 */
export class MdType {
  static readonly PARAGRAPH: string = 'p';
  static readonly HEADING: string = 'h';
  static readonly CODE: string = 'code';
  static readonly QUOTE: string = 'quote';
  static readonly LIST_ITEM: string = 'li';
  static readonly DIVIDER: string = 'hr';
  static readonly TABLE: string = 'table';
}

export class MdBlock {
  type: string = MdType.PARAGRAPH;
  /** 块内原始文本（代码块是原样，其余待行内解析） */
  text: string = '';
  /** 标题级别 1-6 */
  level: number = 0;
  /** 代码块语言标注 */
  lang: string = '';
  /** 列表项是否有序 */
  ordered: boolean = false;
  /** 有序列表的序号 */
  index: number = 0;
  /** 表格：表头单元格 */
  header: string[] = [];
  /** 表格：数据行 */
  rows: string[][] = [];

  constructor(type: string, text: string) {
    this.type = type;
    this.text = text;
  }
}

/** 行内片段 */
export class MdSpan {
  text: string = '';
  bold: boolean = false;
  italic: boolean = false;
  code: boolean = false;
  /** 非空表示这是链接 */
  link: string = '';

  constructor(text: string) {
    this.text = text;
  }
}

// ---------------------------------------------------------------------------
// 块级解析
// ---------------------------------------------------------------------------

function headingLevel(line: string): number {
  let n = 0;
  while (n < line.length && line.charAt(n) === '#') {
    n++;
  }
  // "#### " 后面必须有空格才算标题，否则可能是正文里的 # 号
  if (n >= 1 && n <= 6 && n < line.length && line.charAt(n) === ' ') {
    return n;
  }
  return 0;
}

/** 无序列表标记：- * + 后跟空格 */
function unorderedMark(line: string): boolean {
  if (line.length < 2) {
    return false;
  }
  const c = line.charAt(0);
  return (c === '-' || c === '*' || c === '+') && line.charAt(1) === ' ';
}

/** 有序列表标记：数字 + . + 空格，返回序号，0 表示不是 */
function orderedMark(line: string): number {
  let i = 0;
  while (i < line.length && line.charAt(i) >= '0' && line.charAt(i) <= '9') {
    i++;
  }
  if (i === 0 || i + 1 >= line.length) {
    return 0;
  }
  if (line.charAt(i) !== '.' || line.charAt(i + 1) !== ' ') {
    return 0;
  }
  const n = Number.parseInt(line.substring(0, i), 10);
  return Number.isInteger(n) ? n : 0;
}

function isDivider(line: string): boolean {
  const t = line.trim();
  if (t.length < 3) {
    return false;
  }
  const c = t.charAt(0);
  if (c !== '-' && c !== '*' && c !== '_') {
    return false;
  }
  for (let i = 0; i < t.length; i++) {
    if (t.charAt(i) !== c) {
      return false;
    }
  }
  return true;
}

/**
 * 表格分隔行：只由 | - : 空格组成，且至少有一个 -。
 * 例如 |---|:--:|---|
 */
function isTableDivider(line: string): boolean {
  if (line.indexOf('|') < 0 || line.indexOf('-') < 0) {
    return false;
  }
  for (let i = 0; i < line.length; i++) {
    const c = line.charAt(i);
    if (c !== '|' && c !== '-' && c !== ':' && c !== ' ') {
      return false;
    }
  }
  return true;
}

/** 按 | 切分一行单元格，去掉首尾的空格与空单元 */
function splitRow(line: string): string[] {
  let t = line.trim();
  if (t.startsWith('|')) {
    t = t.substring(1);
  }
  if (t.endsWith('|')) {
    t = t.substring(0, t.length - 1);
  }
  const out: string[] = [];
  for (const cell of t.split('|')) {
    out.push(cell.trim());
  }
  return out;
}

export function parseMarkdown(src: string): MdBlock[] {
  const blocks: MdBlock[] = [];
  const lines = src.split('\n');

  let para: string[] = [];

  const flushPara = () => {
    if (para.length > 0) {
      blocks.push(new MdBlock(MdType.PARAGRAPH, para.join('\n')));
      para = [];
    }
  };

  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    // ---- 代码块 ----
    if (trimmed.startsWith('```')) {
      flushPara();
      const lang = trimmed.substring(3).trim();
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        body.push(lines[i]);
        i++;
      }
      i++; // 跳过收尾的 ```
      const b = new MdBlock(MdType.CODE, body.join('\n'));
      b.lang = lang;
      blocks.push(b);
      continue;
    }

    // ---- 空行：段落分隔 ----
    if (trimmed.length === 0) {
      flushPara();
      i++;
      continue;
    }

    // ---- 分割线 ----
    if (isDivider(trimmed)) {
      flushPara();
      blocks.push(new MdBlock(MdType.DIVIDER, ''));
      i++;
      continue;
    }

    // ---- 标题 ----
    const hl = headingLevel(trimmed);
    if (hl > 0) {
      flushPara();
      const b = new MdBlock(MdType.HEADING, trimmed.substring(hl + 1).trim());
      b.level = hl;
      blocks.push(b);
      i++;
      continue;
    }

    // ---- 引用 ----
    if (trimmed.startsWith('> ')) {
      flushPara();
      const body: string[] = [];
      while (i < lines.length && lines[i].trim().startsWith('> ')) {
        body.push(lines[i].trim().substring(2));
        i++;
      }
      blocks.push(new MdBlock(MdType.QUOTE, body.join('\n')));
      continue;
    }

    // ---- 表格 ----
    //
    // 判定条件是「本行含 |」且「下一行是分隔行」（形如 |---|:--:|）。
    // 只看当前行含 | 会把正文里带竖线的句子误判成表格。
    if (trimmed.indexOf('|') >= 0 && i + 1 < lines.length
      && isTableDivider(lines[i + 1].trim())) {
      flushPara();
      const b = new MdBlock(MdType.TABLE, '');
      b.header = splitRow(trimmed);
      i += 2; // 跳过表头和分隔行
      while (i < lines.length) {
        const row = lines[i].trim();
        if (row.length === 0 || row.indexOf('|') < 0) {
          break;
        }
        b.rows.push(splitRow(row));
        i++;
      }
      blocks.push(b);
      continue;
    }

    // ---- 列表 ----
    if (unorderedMark(trimmed)) {
      flushPara();
      const b = new MdBlock(MdType.LIST_ITEM, trimmed.substring(2).trim());
      b.ordered = false;
      blocks.push(b);
      i++;
      continue;
    }
    const on = orderedMark(trimmed);
    if (on > 0) {
      flushPara();
      const dot = trimmed.indexOf('. ');
      const b = new MdBlock(MdType.LIST_ITEM, trimmed.substring(dot + 2).trim());
      b.ordered = true;
      b.index = on;
      blocks.push(b);
      i++;
      continue;
    }

    // ---- 普通正文 ----
    para.push(line);
    i++;
  }
  flushPara();

  return blocks;
}

// ---------------------------------------------------------------------------
// 行内解析
// ---------------------------------------------------------------------------

/**
 * 把一段文本拆成带样式的片段。
 *
 * 手写扫描而不是正则：ArkTS 的正则能力足够，但多种标记交叉时
 * 用正则很难保证不吃错边界，扫描器更好推理也更好调试。
 */
export function parseInline(src: string): MdSpan[] {
  const out: MdSpan[] = [];
  let buf = '';

  const flush = () => {
    if (buf.length > 0) {
      out.push(new MdSpan(buf));
      buf = '';
    }
  };

  let i = 0;
  while (i < src.length) {
    const c = src.charAt(i);

    // ---- 行内代码 ----
    if (c === '`') {
      const end = src.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        const s = new MdSpan(src.substring(i + 1, end));
        s.code = true;
        out.push(s);
        i = end + 1;
        continue;
      }
    }

    // ---- 粗体 ----
    if (c === '*' && i + 1 < src.length && src.charAt(i + 1) === '*') {
      const end = src.indexOf('**', i + 2);
      if (end > i + 2) {
        flush();
        const s = new MdSpan(src.substring(i + 2, end));
        s.bold = true;
        out.push(s);
        i = end + 2;
        continue;
      }
    }

    // ---- 斜体 ----
    if (c === '*') {
      const end = src.indexOf('*', i + 1);
      if (end > i + 1) {
        flush();
        const s = new MdSpan(src.substring(i + 1, end));
        s.italic = true;
        out.push(s);
        i = end + 1;
        continue;
      }
    }

    // ---- 链接 [文字](地址) ----
    if (c === '[') {
      const close = src.indexOf(']', i + 1);
      if (close > i && close + 1 < src.length && src.charAt(close + 1) === '(') {
        const paren = src.indexOf(')', close + 2);
        if (paren > close + 1) {
          flush();
          const s = new MdSpan(src.substring(i + 1, close));
          s.link = src.substring(close + 2, paren);
          out.push(s);
          i = paren + 1;
          continue;
        }
      }
    }

    buf += c;
    i++;
  }
  flush();

  // 整段无任何标记时也要返回一个片段，避免渲染出空
  if (out.length === 0) {
    out.push(new MdSpan(src));
  }
  return out;
}
