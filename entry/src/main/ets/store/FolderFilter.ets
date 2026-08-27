/**
 * 文件夹筛选：只显示指定目录下的 Claude 会话。
 *
 * 服务端的 projectRoots 是**安全边界**（限制手机能触及的范围），
 * 这里的筛选是**视图偏好**（我现在只想看工作项目）。两者职责不同，
 * 所以没有复用服务端那套：安全边界不该由客户端说了算，
 * 而视图偏好也不该要求改服务器配置再重启。
 *
 * 过滤结果 visible 放在 store 里而不是页面里，是因为配置在「我的」页改、
 * 列表在「对话」页用。放页面里的话，两个 @ComponentV2 各自持有派生数据，
 * 改了配置另一边不会重算。放 store 里、且同为 @Trace，两边自动同步。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { ProjectInfo } from '../net/Protocol';

const STORE_NAME = 'cc_remoter_folder_filter';
const KEY_ENABLED = 'enabled';
const KEY_ROOTS = 'roots';

/** 候选目录：路径 + 它名下有多少项目 */
export class FolderCandidate {
  path: string = '';
  count: number = 0;

  constructor(path: string, count: number) {
    this.path = path;
    this.count = count;
  }
}

/** 统一分隔符，便于比较 */
function normalize(p: string): string {
  let s = p.split('\\').join('/');
  // 去掉结尾斜杠，否则 "/a/b/" 和 "/a/b" 会被当成不同目录
  while (s.length > 1 && s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/** Windows 路径大小写不敏感，Linux 敏感 —— 按有无盘符判断 */
function isWindowsPath(p: string): boolean {
  return p.length >= 2 && p.charAt(1) === ':';
}

/** 取父目录，已经到根就返回空串 */
function parentOf(p: string): string {
  const s = normalize(p);
  const i = s.lastIndexOf('/');
  if (i <= 0) {
    return '';
  }
  // 保留 Windows 盘符根 "C:/"
  if (i === 2 && isWindowsPath(s)) {
    return s.substring(0, 3);
  }
  return s.substring(0, i);
}

/**
 * path 是否**直属**于 root。
 *
 * 只认两种情况：path 就是 root 本身，或 path 的父目录是 root。
 * 不递归往下 —— 递归匹配时选一个稍微靠上的目录就会命中几乎所有项目
 * （实测选 Desktop 能命中 110 个里的 104 个），开了筛选也看不出变化，
 * 那就失去了筛选的意义。
 */
export function isDirectlyIn(path: string, root: string): boolean {
  let a = normalize(path);
  let b = normalize(root);
  if (b.length === 0) {
    return false;
  }
  if (isWindowsPath(b) || isWindowsPath(a)) {
    a = a.toLowerCase();
    b = b.toLowerCase();
  }
  if (a === b) {
    return true;
  }
  // 父目录必须正好是 root。用父目录比较而不是前缀比较，
  // 顺带避开了 /ab 被误判为在 /a 之下这类前缀陷阱
  return normalize(parentOf(a)).toLowerCase() === b
    || normalize(parentOf(a)) === b;
}

@ObservedV2
export class FolderFilterStore {
  @Trace enabled: boolean = false;
  @Trace roots: string[] = [];
  /** 过滤后的项目列表，页面直接读这个 */
  @Trace visible: ProjectInfo[] = [];

  /** 未过滤的原始列表 */
  private source: ProjectInfo[] = [];
  private store: preferences.Preferences | null = null;
  /**
   * 变更监听。
   *
   * visible 是 @Trace，读它的界面会自动刷新；但项目列表把分区**拍平成了
   * 行序列**（为了用 LazyForEach），那份派生数据得靠命令式重建。
   * 而配置在「我的」页改、列表在「对话」页用，Tab 之间切换不会重新
   * aboutToAppear —— 没有这个通知，改完筛选切回去列表还是旧的。
   */
  private listeners: Array<() => void> = [];

  /** 注册变更回调，返回取消注册的函数 */
  onChanged(cb: () => void): () => void {
    this.listeners.push(cb);
    return () => {
      const i = this.listeners.indexOf(cb);
      if (i >= 0) {
        this.listeners.splice(i, 1);
      }
    };
  }

  private notify(): void {
    for (const cb of this.listeners) {
      cb();
    }
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, STORE_NAME);
    this.enabled = await this.store.get(KEY_ENABLED, false) as boolean;
    const raw = await this.store.get(KEY_ROOTS, '') as string;
    if (raw.length > 0) {
      try {
        const arr = JSON.parse(raw) as string[];
        this.roots = arr.filter((x) => typeof x === 'string' && x.length > 0);
      } catch (_e) {
        this.roots = [];
      }
    }
    this.recompute();
  }

  private async persist(): Promise<void> {
    if (this.store === null) {
      return;
    }
    await this.store.put(KEY_ENABLED, this.enabled);
    await this.store.put(KEY_ROOTS, JSON.stringify(this.roots));
    await this.store.flush();
  }

  /** 列表加载完后灌进来 */
  setSource(list: ProjectInfo[]): void {
    this.source = list;
    this.recompute();
  }

  private recompute(): void {
    if (!this.enabled || this.roots.length === 0) {
      this.visible = this.source;
    } else {
      this.visible = this.source.filter((p) =>
        this.roots.some((r) => isDirectlyIn(p.path, r))
      );
    }
    this.notify();
  }

  async setEnabled(v: boolean): Promise<void> {
    this.enabled = v;
    this.recompute();
    await this.persist();
  }

  async addRoot(path: string): Promise<void> {
    const p = normalize(path.trim());
    if (p.length === 0) {
      return;
    }
    if (this.roots.some((r) => normalize(r) === p)) {
      return;
    }
    // 整体替换而不是 push —— @Trace 对引用替换的观察最直接
    this.roots = this.roots.concat([p]);
    // 加了第一个目录就自动启用，省一次操作。
    // 用户特意去添加目录，意图显然是想让它生效。
    if (!this.enabled) {
      this.enabled = true;
    }
    this.recompute();
    await this.persist();
  }

  async removeRoot(path: string): Promise<void> {
    this.roots = this.roots.filter((r) => normalize(r) !== normalize(path));
    this.recompute();
    await this.persist();
  }

  /** 某个目录下有多少个项目（不受当前筛选影响，始终基于全量） */
  countUnder(root: string): number {
    return this.source.filter((p) => isDirectlyIn(p.path, root)).length;
  }

  /** 被筛掉的项目数，用于在界面上说明筛选的实际效果 */
  hiddenCount(): number {
    return this.source.length - this.visible.length;
  }

  totalCount(): number {
    return this.source.length;
  }

  /**
   * 从现有项目路径推导候选目录。
   *
   * 手机上手打绝对路径非常痛苦，而候选其实是现成的 ——
   * 把所有项目路径的各级父目录汇总，按名下项目数排序即可。
   * 只保留能覆盖 2 个及以上项目的目录：只含一个项目的目录
   * 等同于选那个项目本身，作为"文件夹筛选"没有意义。
   */
  candidates(): FolderCandidate[] {
    // 只统计**直接父目录**，不再逐级往上累加。
    //
    // 之前逐级累加是为了配合递归匹配，但那样 C:/Users 这种祖先目录
    // 会显示"106 个项目"，选了却几乎筛不掉东西。现在匹配只认直属，
    // 候选的计数也必须是直属数，否则界面上的数字和实际效果对不上。
    const counter = new Map<string, number>();
    for (const p of this.source) {
      const dir = parentOf(p.path);
      if (dir.length > 0) {
        counter.set(dir, (counter.get(dir) ?? 0) + 1);
      }
    }

    const out: FolderCandidate[] = [];
    counter.forEach((count: number, path: string) => {
      out.push(new FolderCandidate(path, count));
    });

    // 直属项目多的排前面 —— 现在的计数已经反映真实筛选效果，
    // 不会再出现"数字很大但选了没用"的祖先目录
    out.sort((a, b) => {
      if (a.count !== b.count) {
        return b.count - a.count;
      }
      return a.path.length - b.path.length;
    });
    return out;
  }

  /** 是否已加入筛选 */
  hasRoot(path: string): boolean {
    return this.roots.some((r) => normalize(r) === normalize(path));
  }
}

/** 全局单例 */
export const folderFilter: FolderFilterStore = new FolderFilterStore();
