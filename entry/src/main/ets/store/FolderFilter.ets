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

/** path 是否在 root 之下（含自身） */
export function isUnder(path: string, root: string): boolean {
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
  // 必须以 "root/" 开头，否则 /ab 会被误判为在 /a 之下
  return a.startsWith(`${b}/`);
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

@ObservedV2
export class FolderFilterStore {
  @Trace enabled: boolean = false;
  @Trace roots: string[] = [];
  /** 过滤后的项目列表，页面直接读这个 */
  @Trace visible: ProjectInfo[] = [];

  /** 未过滤的原始列表 */
  private source: ProjectInfo[] = [];
  private store: preferences.Preferences | null = null;

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
      return;
    }
    this.visible = this.source.filter((p) =>
      this.roots.some((r) => isUnder(p.path, r))
    );
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
    return this.source.filter((p) => isUnder(p.path, root)).length;
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
    const counter = new Map<string, number>();
    for (const p of this.source) {
      let dir = parentOf(p.path);
      let guard = 0;
      while (dir.length > 0 && guard < 12) {
        counter.set(dir, (counter.get(dir) ?? 0) + 1);
        const next = parentOf(dir);
        if (next === dir) {
          break;
        }
        dir = next;
        guard++;
      }
    }

    const total = this.source.length;
    const out: FolderCandidate[] = [];
    counter.forEach((count: number, path: string) => {
      // 覆盖全部项目的目录等于没筛，别浪费列表位置。
      // 实测 "C:/" 和 "C:/Users" 就属于这类。
      if (count >= 2 && count < total) {
        out.push(new FolderCandidate(path, count));
      }
    });

    // 深的排前面。
    //
    // 直觉上该按项目数降序，但实测那样排出来最前面全是 C:/Users
    // 这种覆盖面极广、筛了等于没筛的祖先目录，真正想选的工作目录
    // 反而沉到最底下。用户要找的是"某个具体的工作文件夹"，
    // 越具体的越该先看到；数量相同时再让项目多的靠前。
    out.sort((a, b) => {
      const da = a.path.split('/').length;
      const db = b.path.split('/').length;
      if (da !== db) {
        return db - da;
      }
      return b.count - a.count;
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
