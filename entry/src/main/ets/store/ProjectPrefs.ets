/**
 * 项目的本地组织方式：分组、置顶、重命名。
 *
 * 这些都是**展示层概念**，服务端只负责扫描 ~/.claude/projects 并返回原始列表，
 * 不知道也不该知道用户怎么给项目分组。所以全部存在手机本地。
 *
 * 副作用是换手机不会同步 —— 但这类偏好本来就带设备属性
 * （手机上常看的项目和电脑上不一定一样），放服务端反而是过度设计。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME = 'cc_remoter_project_prefs';
const KEY_DATA = 'data';

/** 未分组的哨兵值 */
export const NO_GROUP: string = '';

// ---------------------------------------------------------------------------
// 持久化用的纯数据结构（ArkTS 要求 JSON 解析结果有显式接口）
// ---------------------------------------------------------------------------

interface GroupJson {
  id: string;
  name: string;
  collapsed: boolean;
  order: number;
}

interface MetaJson {
  projectId: string;
  alias: string;
  pinned: boolean;
  groupId: string;
  notify?: boolean;
}

interface PrefsJson {
  groups: GroupJson[];
  metas: MetaJson[];
}

// ---------------------------------------------------------------------------
// 可观察的运行时对象
// ---------------------------------------------------------------------------

@ObservedV2
export class ProjectGroup {
  readonly id: string;
  @Trace name: string;
  /** 抽屉是否收起 */
  @Trace collapsed: boolean;
  @Trace order: number;

  constructor(id: string, name: string, collapsed: boolean, order: number) {
    this.id = id;
    this.name = name;
    this.collapsed = collapsed;
    this.order = order;
  }
}

@ObservedV2
export class ProjectMeta {
  readonly projectId: string;
  /** 重命名后的显示名。空字符串表示用服务端返回的原名 */
  @Trace alias: string;
  @Trace pinned: boolean;
  /** 所属分组 id，空字符串表示未分组 */
  @Trace groupId: string;
  /**
   * 是否推送这个项目的通知。
   *
   * 默认关闭 —— 通知是打扰，得由用户明确开启。
   * 而且大多数项目是历史记录，只有当下在推进的那一两个才需要提醒。
   */
  @Trace notify: boolean;

  constructor(
    projectId: string, alias: string, pinned: boolean,
    groupId: string, notify: boolean = false
  ) {
    this.projectId = projectId;
    this.alias = alias;
    this.pinned = pinned;
    this.groupId = groupId;
    this.notify = notify;
  }
}

@ObservedV2
export class ProjectPrefsStore {
  @Trace groups: ProjectGroup[] = [];
  @Trace metas: ProjectMeta[] = [];

  private store: preferences.Preferences | null = null;
  /** 生成 id 用的自增序号，配合时间戳避免同一毫秒内重复 */
  private seq: number = 0;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, STORE_NAME);
    const raw = await this.store.get(KEY_DATA, '') as string;
    if (raw.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(raw) as PrefsJson;
      const gs: ProjectGroup[] = [];
      if (parsed.groups !== undefined) {
        for (const g of parsed.groups) {
          gs.push(new ProjectGroup(g.id, g.name, g.collapsed, g.order));
        }
      }
      const ms: ProjectMeta[] = [];
      if (parsed.metas !== undefined) {
        for (const m of parsed.metas) {
          ms.push(new ProjectMeta(m.projectId, m.alias, m.pinned, m.groupId, m.notify === true));
        }
      }
      this.groups = gs.sort((a, b) => a.order - b.order);
      this.metas = ms;
    } catch (_e) {
      // 数据损坏就当空的重来，不值得为此让整个列表打不开
    }
  }

  private async persist(): Promise<void> {
    if (this.store === null) {
      return;
    }
    const gs: GroupJson[] = this.groups.map((g): GroupJson => {
      return { id: g.id, name: g.name, collapsed: g.collapsed, order: g.order };
    });
    const ms: MetaJson[] = this.metas.map((m): MetaJson => {
      return {
        projectId: m.projectId, alias: m.alias, pinned: m.pinned,
        groupId: m.groupId, notify: m.notify
      };
    });
    const data: PrefsJson = { groups: gs, metas: ms };
    await this.store.put(KEY_DATA, JSON.stringify(data));
    await this.store.flush();
  }

  private nextId(): string {
    this.seq += 1;
    return `g${Date.now()}_${this.seq}`;
  }

  // -------------------------------------------------------------------------
  // 项目元信息
  // -------------------------------------------------------------------------

  /** 取项目的元信息，没有就现建一条 */
  metaOf(projectId: string): ProjectMeta {
    const found = this.metas.find((m) => m.projectId === projectId);
    if (found !== undefined) {
      return found;
    }
    const created = new ProjectMeta(projectId, '', false, NO_GROUP, false);
    this.metas.push(created);
    return created;
  }

  /** 显示名：优先用户重命名的，否则用原名 */
  displayName(projectId: string, fallback: string): string {
    const m = this.metas.find((x) => x.projectId === projectId);
    if (m !== undefined && m.alias.length > 0) {
      return m.alias;
    }
    return fallback;
  }

  isPinned(projectId: string): boolean {
    const m = this.metas.find((x) => x.projectId === projectId);
    return m !== undefined && m.pinned;
  }

  groupIdOf(projectId: string): string {
    const m = this.metas.find((x) => x.projectId === projectId);
    return m === undefined ? NO_GROUP : m.groupId;
  }

  /** 该项目是否开启了通知 */
  isNotifyOn(projectId: string): boolean {
    const m = this.metas.find((x) => x.projectId === projectId);
    return m !== undefined && m.notify;
  }

  async setNotify(projectId: string, on: boolean): Promise<void> {
    const m = this.metaOf(projectId);
    m.notify = on;
    await this.persist();
  }

  async togglePin(projectId: string): Promise<void> {
    const m = this.metaOf(projectId);
    m.pinned = !m.pinned;
    await this.persist();
  }

  /** 重命名。传空字符串表示恢复原名 */
  async rename(projectId: string, alias: string): Promise<void> {
    const m = this.metaOf(projectId);
    m.alias = alias.trim();
    await this.persist();
  }

  async assignGroup(projectId: string, groupId: string): Promise<void> {
    const m = this.metaOf(projectId);
    m.groupId = groupId;
    await this.persist();
  }

  // -------------------------------------------------------------------------
  // 分组
  // -------------------------------------------------------------------------

  async createGroup(name: string): Promise<string> {
    const trimmed = name.trim();
    if (trimmed.length === 0) {
      return NO_GROUP;
    }
    const id = this.nextId();
    const order = this.groups.length;
    // 整体替换数组而不是 push —— @Trace 对引用替换的观察最稳，
    // 分组增删不频繁，多一次拷贝无所谓
    this.groups = this.groups.concat([new ProjectGroup(id, trimmed, false, order)]);
    await this.persist();
    return id;
  }

  async renameGroup(groupId: string, name: string): Promise<void> {
    const g = this.groups.find((x) => x.id === groupId);
    if (g === undefined) {
      return;
    }
    const trimmed = name.trim();
    if (trimmed.length === 0) {
      return;
    }
    g.name = trimmed;
    await this.persist();
  }

  /** 删除分组。组内项目退回未分组，不会跟着一起消失 */
  async deleteGroup(groupId: string): Promise<void> {
    this.groups = this.groups.filter((g) => g.id !== groupId);
    for (const m of this.metas) {
      if (m.groupId === groupId) {
        m.groupId = NO_GROUP;
      }
    }
    await this.persist();
  }

  async toggleCollapse(groupId: string): Promise<void> {
    const g = this.groups.find((x) => x.id === groupId);
    if (g === undefined) {
      return;
    }
    g.collapsed = !g.collapsed;
    await this.persist();
  }

  groupName(groupId: string): string {
    const g = this.groups.find((x) => x.id === groupId);
    return g === undefined ? '' : g.name;
  }
}

/** 全局单例 */
export const projectPrefs: ProjectPrefsStore = new ProjectPrefsStore();
