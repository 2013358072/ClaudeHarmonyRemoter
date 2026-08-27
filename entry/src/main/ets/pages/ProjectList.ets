/**
 * 项目列表：服务器上有 Claude 会话记录的项目。
 *
 * 常态下四层组织：运行中 → 置顶 → 各分组（可折叠抽屉）→ 未分组。
 * 优先级从高到低，一个项目只出现在最高的那一层，不重复。
 *
 * 搜索时**拍平成单一结果列表**，不保留分组结构 ——
 * 搜索的意图是"快速找到那一个"，分组套结果反而增加扫读成本。
 *
 * 分组、置顶、重命名都是本地偏好，见 store/ProjectPrefs.ets。
 * 「正在运行」由服务端判定，见 server/src/claude/activeSessions.ts。
 */

import { apiClient, ApiException } from '../net/ApiClient';
import { appStore } from '../store/AppStore';
import { tokenStore } from '../store/TokenStore';
import { projectPrefs, ProjectGroup, NO_GROUP } from '../store/ProjectPrefs';
import { ProjectInfo } from '../net/Protocol';
import { SessionListParam } from './SessionList';
import { formatTimestamp } from '../utils/Format';
import { theme, FontSize, RUNNING_GREEN } from '../theme/Theme';
import { pasteboard } from '@kit.BasicServicesKit';
import { folderFilter } from '../store/FolderFilter';
import { LazyDataSource } from '../utils/LazyDataSource';
import { notifier } from '../utils/Notifier';

/** 当前打开的弹层。名字不能叫 Sheet —— 会和 ArkUI 的 bindSheet 一族撞车 */
class SheetKind {
  static readonly NONE: string = '';
  static readonly RENAME: string = 'rename';
  static readonly GROUP: string = 'group';
  static readonly NEW_GROUP: string = 'newGroup';
  static readonly GROUP_MENU: string = 'groupMenu';
  /** 齿轮打开的项目设置面板 */
  static readonly PROJECT_MENU: string = 'projectMenu';
}

/**
 * 列表里的一行。
 *
 * 分区结构（运行中/置顶/分组/未分组）原本是靠多个 ForEach 拼出来的，
 * 但 ForEach 没有虚拟化 —— 110 个项目卡片会被一次性全部实例化。
 * 改用 LazyForEach 就必须只有一个数据源，所以先把分区拍平成行序列，
 * 标题和项目都是行，由 kind 区分。
 */
class RowKind {
  static readonly RUNNING_HEADER: string = 'runHead';
  static readonly SECTION_HEADER: string = 'secHead';
  static readonly GROUP_HEADER: string = 'grpHead';
  static readonly PROJECT: string = 'project';
  static readonly SPACER: string = 'spacer';
}

class ListRow {
  kind: string = '';
  /** 稳定 key。LazyForEach 要求唯一，否则会错位复用 */
  key: string = '';
  title: string = '';
  count: number = 0;
  project: ProjectInfo | null = null;
  group: ProjectGroup | null = null;

  constructor(kind: string, key: string) {
    this.kind = kind;
    this.key = key;
  }
}

@ComponentV2
export struct ProjectListView {
  @Consumer() pathStack: NavPathStack = new NavPathStack();
  @Local projects: ProjectInfo[] = [];
  @Local loading: boolean = true;
  @Local errorText: string = '';

  /** 输入框里的原始文本，每次按键都变 */
  @Local query: string = '';
  /**
   * 防抖后真正生效的关键词。
   *
   * 分成两个状态是必须的：过滤是 O(n) 的，而 build() 里会多处读取结果
   * （标题计数、空态文案、列表本身）。直接用 query 意味着每按一个键
   * 就要全量过滤好几遍 —— 项目一多就卡。
   */
  @Local activeQuery: string = '';
  /** 缓存的搜索结果，只在 activeQuery 变化时重算一次 */
  @Local results: ProjectInfo[] = [];
  /** 防抖定时器句柄 */
  private searchTimer: number = -1;

  /** 拍平后的行数据源。分区变化时整体重建 */
  private rows: LazyDataSource<ListRow> = new LazyDataSource<ListRow>();
  /** 行数单独暴露，供界面判断空态 */
  @Local rowCount: number = 0;

  // ---- 弹层状态 ----
  @Local sheet: string = SheetKind.NONE;
  /** 正在操作的项目 id */
  @Local targetId: string = '';
  /** 正在操作的分组 id */
  @Local targetGroupId: string = '';
  @Local inputText: string = '';

  /** 取消订阅筛选变更 */
  private unsubscribe: () => void = () => {};

  aboutToAppear(): void {
    // 「我的」页改了筛选后，这里要重建行序列。
    // Tab 之间切换不会重新 aboutToAppear，所以必须靠订阅。
    this.unsubscribe = folderFilter.onChanged((): void => {
      this.rebuildRows();
    });
    this.load();
  }

  aboutToDisappear(): void {
    this.unsubscribe();
  }

  async load(): Promise<void> {
    this.errorText = '';
    try {
      this.projects = await apiClient.listProjects();
      // 灌给筛选 store，之后所有分区都基于它过滤后的结果
      folderFilter.setSource(this.projects);
      this.rebuildRows();
    } catch (e) {
      const err = e as ApiException;
      // token 失效就清掉凭据，下次启动会回到配对页
      if (err.isUnauthorized()) {
        await tokenStore.clear();
        this.errorText = '登录已失效，请重启应用重新配对';
      } else {
        this.errorText = err.message;
      }
    } finally {
      this.loading = false;
    }
  }

  // -------------------------------------------------------------------------
  // 分区计算
  // -------------------------------------------------------------------------

  private searching(): boolean {
    return this.activeQuery.length > 0;
  }

  /**
   * 输入变化时不立即过滤，等 180ms 没有新输入再算。
   *
   * 连续打字时每一键都全量过滤会明显掉帧，而人眼也看不清中间过程。
   * 180ms 比常见的 300ms 短一些 —— 这里的过滤很轻，
   * 拖太久反而显得迟钝。
   */
  private onQueryChange(v: string): void {
    this.query = v;
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
    }
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.applyQuery(v.trim());
    }, 180);
  }

  private applyQuery(q: string): void {
    this.activeQuery = q;
    if (q.length === 0) {
      this.results = [];
      this.rebuildRows();
      return;
    }
    // 匹配显示名和真实路径 —— 用户可能记得项目名，
    // 也可能记得的是路径里的某一段
    const lower = q.toLowerCase();
    this.results = this.shown().filter((p) => {
      const name = projectPrefs.displayName(p.id, p.name).toLowerCase();
      if (name.indexOf(lower) >= 0) {
        return true;
      }
      return p.path.toLowerCase().indexOf(lower) >= 0;
    });
    this.rebuildRows();
  }

  private clearQuery(): void {
    if (this.searchTimer !== -1) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
    this.query = '';
    this.activeQuery = '';
    this.results = [];
    this.rebuildRows();
  }

  /** 复制工作目录到剪贴板 */
  private copyPath(path: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, path);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.getUIContext().getPromptAction().showToast({ message: '工作目录已复制' });
    }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败' });
    });
  }

  /**
   * 参与展示的项目 —— 已经过文件夹筛选。
   * 各分区一律基于它，不要直接用 this.projects，
   * 否则筛选对那个分区就失效了。
   */
  private shown(): ProjectInfo[] {
    return folderFilter.visible;
  }

  private runningItems(): ProjectInfo[] {
    return this.shown().filter((p) => p.running);
  }

  /** 置顶区排除运行中的 —— 后者已单独成区，不重复出现 */
  private pinnedItems(): ProjectInfo[] {
    return this.shown().filter((p) => !p.running && projectPrefs.isPinned(p.id));
  }

  private itemsInGroup(groupId: string): ProjectInfo[] {
    return this.shown().filter((p) =>
      !p.running
        && !projectPrefs.isPinned(p.id)
        && projectPrefs.groupIdOf(p.id) === groupId
    );
  }

  private ungroupedItems(): ProjectInfo[] {
    return this.shown().filter((p) => {
      if (p.running || projectPrefs.isPinned(p.id)) {
        return false;
      }
      const gid = projectPrefs.groupIdOf(p.id);
      if (gid === NO_GROUP) {
        return true;
      }
      // 分组被删掉但元信息还指着它时，也算未分组，避免项目凭空消失
      return projectPrefs.groups.find((g) => g.id === gid) === undefined;
    });
  }

  /**
   * 重建行序列。
   *
   * 任何影响列表构成的操作（加载完成、筛选变化、搜索、置顶、分组折叠）
   * 之后都要调它 —— 漏掉一处，界面就会停在旧结构上。
   */
  private rebuildRows(): void {
    const out: ListRow[] = [];

    if (this.searching()) {
      const head = new ListRow(RowKind.SECTION_HEADER, 'h_search');
      head.title = '搜索结果';
      head.count = this.results.length;
      out.push(head);
      for (const p of this.results) {
        const r = new ListRow(RowKind.PROJECT, `q_${p.id}`);
        r.project = p;
        out.push(r);
      }
    } else {
      const running = this.runningItems();
      if (running.length > 0) {
        const head = new ListRow(RowKind.RUNNING_HEADER, 'h_run');
        head.count = running.length;
        out.push(head);
        for (const p of running) {
          const r = new ListRow(RowKind.PROJECT, `run_${p.id}`);
          r.project = p;
          out.push(r);
        }
      }

      const pinned = this.pinnedItems();
      if (pinned.length > 0) {
        const head = new ListRow(RowKind.SECTION_HEADER, 'h_pin');
        head.title = '置顶';
        head.count = pinned.length;
        out.push(head);
        for (const p of pinned) {
          const r = new ListRow(RowKind.PROJECT, `pin_${p.id}`);
          r.project = p;
          out.push(r);
        }
      }

      for (const g of projectPrefs.groups) {
        const inGroup = this.itemsInGroup(g.id);
        const head = new ListRow(RowKind.GROUP_HEADER, `h_g_${g.id}`);
        head.group = g;
        head.count = inGroup.length;
        out.push(head);
        if (!g.collapsed) {
          for (const p of inGroup) {
            const r = new ListRow(RowKind.PROJECT, `${g.id}_${p.id}`);
            r.project = p;
            out.push(r);
          }
        }
      }

      const ungrouped = this.ungroupedItems();
      if (ungrouped.length > 0) {
        if (projectPrefs.groups.length > 0 || pinned.length > 0 || running.length > 0) {
          const head = new ListRow(RowKind.SECTION_HEADER, 'h_ung');
          head.title = '未分组';
          head.count = ungrouped.length;
          out.push(head);
        }
        for (const p of ungrouped) {
          const r = new ListRow(RowKind.PROJECT, `ung_${p.id}`);
          r.project = p;
          out.push(r);
        }
      }
    }

    out.push(new ListRow(RowKind.SPACER, 'spacer_end'));

    this.rows.setAll(out);
    this.rowCount = out.length;
  }

  private openProject(item: ProjectInfo): void {
    const param: SessionListParam = {
      projectId: item.id,
      projectName: projectPrefs.displayName(item.id, item.name)
    };
    this.pathStack.pushPath({ name: 'SessionList', param: param });
  }

  private closeSheet(): void {
    this.sheet = SheetKind.NONE;
    this.targetId = '';
    this.targetGroupId = '';
    this.inputText = '';
  }

  // -------------------------------------------------------------------------
  // 列表渲染
  // -------------------------------------------------------------------------

  @Builder
  searchBar() {
    Row({ space: 8 }) {
      Text('🔍')
        .fontSize(theme.fs(FontSize.LABEL))
        .opacity(0.5)
      TextInput({ placeholder: '搜索项目名称或路径', text: this.query })
        .layoutWeight(1)
        .height(38)
        .padding({ left: 0, right: 0 })
        .fontSize(theme.fs(FontSize.LABEL))
        .fontColor(theme.palette.text)
        .placeholderColor(theme.palette.textTertiary)
        .backgroundColor(Color.Transparent)
        .onChange((v: string) => this.onQueryChange(v))
      if (this.query.length > 0) {
        Text('✕')
          .fontSize(theme.fs(FontSize.LABEL))
          .fontColor(theme.palette.textTertiary)
          .padding({ left: 4, right: 2 })
          .onClick(() => this.clearQuery())
      }
    }
    .width('100%')
    .padding({ left: 14, right: 12 })
    .borderRadius(12)
    .backgroundColor(theme.palette.surfaceAlt)
  }

  @Builder
  sectionHeader(title: string, count: number) {
    Row({ space: 8 }) {
      Text(title)
        .fontSize(theme.fs(FontSize.TINY))
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.palette.textSecondary)
      Text(`${count}`)
        .fontSize(theme.fs(FontSize.TINY))
        .fontColor(theme.palette.textTertiary)
      Blank()
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 8 })
    .backgroundColor(theme.palette.bg)
  }

  /** 运行中区标题，带绿点，和普通分区区分开 */
  @Builder
  runningHeader(count: number) {
    Row({ space: 7 }) {
      Row()
        .width(7)
        .height(7)
        .borderRadius(4)
        .backgroundColor(RUNNING_GREEN)
      Text('正在运行')
        .fontSize(theme.fs(FontSize.TINY))
        .fontWeight(FontWeight.Medium)
        .fontColor(RUNNING_GREEN)
      Text(`${count}`)
        .fontSize(theme.fs(FontSize.TINY))
        .fontColor(theme.palette.textTertiary)
      Blank()
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 8 })
    .backgroundColor(theme.palette.bg)
  }

  /** 分组抽屉头：点击展开/收起，右侧「⋯」打开分组菜单 */
  @Builder
  groupHeader(group: ProjectGroup, count: number) {
    Row({ space: 8 }) {
      // 箭头旋转表达展开状态，比换图标更连贯
      Text('›')
        .fontSize(theme.fs(16))
        .fontColor(theme.palette.textSecondary)
        .width(14)
        .textAlign(TextAlign.Center)
        .rotate({ angle: group.collapsed ? 0 : 90 })
        .animation({ duration: 180, curve: Curve.EaseInOut })

      Text(group.name)
        .fontSize(theme.fs(FontSize.LABEL))
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.palette.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '60%' })

      Text(`${count}`)
        .fontSize(theme.fs(FontSize.TINY))
        .fontColor(theme.palette.textTertiary)
        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
        .borderRadius(6)
        .backgroundColor(theme.palette.surfaceAlt)

      Blank()

      Text('⋯')
        .fontSize(theme.fs(18))
        .fontColor(theme.palette.textSecondary)
        .padding({ left: 10, right: 4 })
        .onClick(() => {
          this.targetGroupId = group.id;
          this.sheet = SheetKind.GROUP_MENU;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 13, bottom: 13 })
    .backgroundColor(theme.palette.bg)
    .onClick(() => {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
        projectPrefs.toggleCollapse(group.id);
        this.rebuildRows();
      });
    })
  }

  @Builder
  projectCard(item: ProjectInfo) {
    // Stack 是为了把运行绿点压在卡片左上角
    Stack({ alignContent: Alignment.TopStart }) {
      Row({ space: 12 }) {
        // 首字母方块，给列表一个视觉锚点
        Text(projectPrefs.displayName(item.id, item.name).substring(0, 1).toUpperCase())
          .fontSize(theme.fs(FontSize.HEADING))
          .fontWeight(FontWeight.Medium)
          .fontColor(item.running ? RUNNING_GREEN : theme.palette.accent)
          .width(42)
          .height(42)
          .textAlign(TextAlign.Center)
          .borderRadius(12)
          .backgroundColor(theme.palette.surfaceAlt)

        Column({ space: 3 }) {
          Row({ space: 6 }) {
            if (projectPrefs.isPinned(item.id)) {
              Text('▲')
                .fontSize(theme.fs(9))
                .fontColor(theme.palette.accent)
            }
            Text(projectPrefs.displayName(item.id, item.name))
              .fontSize(theme.fs(FontSize.BODY))
              .fontWeight(FontWeight.Medium)
              .fontColor(theme.palette.text)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(formatTimestamp(item.lastActiveAt))
              .fontSize(theme.fs(FontSize.TINY))
              .fontColor(theme.palette.textTertiary)
          }
          .width('100%')

          Text(item.path)
            .fontSize(theme.fs(FontSize.TINY))
            .fontColor(theme.palette.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(`${item.sessionCount} 个会话`)
            .fontSize(theme.fs(FontSize.TINY))
            .fontColor(theme.palette.textSecondary)
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .padding(14)
      .alignItems(VerticalAlign.Center)

      if (item.running) {
        // 外圈用卡片底色描边，让绿点像贴在角上的徽标而不是一个色块
        Row()
          .width(9)
          .height(9)
          .borderRadius(5)
          .backgroundColor(RUNNING_GREEN)
          .border({ width: 2, color: theme.palette.surface })
          .margin({ left: 7, top: 7 })
      }
    }
    .width('100%')
    .borderRadius(16)
    .backgroundColor(theme.palette.surface)
    .border({
      width: 1,
      color: item.running ? RUNNING_GREEN : theme.palette.border
    })
  }

  /**
   * 左滑操作条：只有两个图标按钮。
   *
   * 从三个文字按钮改成图标，是因为文字按钮各要 64pt 宽，三个排下来
   * 占掉半个屏幕，滑出来的一刻很有压迫感。图标按钮 52pt 见方，
   * 两个加起来还不到原来的一半，含义也一眼就懂。
   * 重命名和分组这类低频操作收进齿轮里，不占常驻位置。
   */
  @Builder
  swipeActions(item: ProjectInfo) {
    Row({ space: 8 }) {
      this.swipeIcon(
        projectPrefs.isPinned(item.id) ? $r('app.media.ic_pin_off') : $r('app.media.ic_pin'),
        theme.palette.accent,
        (): void => {
          projectPrefs.togglePin(item.id);
          this.rebuildRows();
        }
      )
      this.swipeIcon($r('app.media.ic_gear'), theme.palette.textSecondary, (): void => {
        this.targetId = item.id;
        this.sheet = SheetKind.PROJECT_MENU;
      })
    }
    .height('100%')
    .padding({ left: 8, right: 4 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  swipeIcon(icon: Resource, bg: string, action: () => void) {
    Row() {
      Image(icon)
        .width(21)
        .height(21)
        .fillColor(theme.palette.onAccent)
    }
    .width(52)
    .height(52)
    .borderRadius(14)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(bg)
    .onClick(() => { action(); })
  }

  @Builder
  projectItem(item: ProjectInfo) {
    ListItem() {
      this.projectCard(item)
    }
    .padding({ left: 16, right: 16, bottom: 10 })
    .swipeAction({
      end: {
        builder: () => { this.swipeActions(item) },
        actionAreaDistance: 60
      },
      edgeEffect: SwipeEdgeEffect.Spring
    })
    .onClick(() => this.openProject(item))
  }

  @Builder
  placeholder(text: string, showRetry: boolean) {
    Column({ space: 14 }) {
      Text(text)
        .fontSize(theme.fs(FontSize.LABEL))
        .fontColor(theme.palette.textSecondary)
        .textAlign(TextAlign.Center)
      if (showRetry) {
        Button('重试')
          .height(40)
          .fontSize(theme.fs(FontSize.LABEL))
          .fontColor(theme.palette.onAccent)
          .backgroundColor(theme.palette.accent)
          .borderRadius(20)
          .padding({ left: 26, right: 26 })
          .onClick(() => {
            this.loading = true;
            this.load();
          })
      }
    }
    .layoutWeight(1)
    .width('100%')
    .padding(36)
    .justifyContent(FlexAlign.Center)
  }

  // -------------------------------------------------------------------------
  // 弹层
  // -------------------------------------------------------------------------

  /**
   * 弹层外壳：遮罩 + 底部卡片。点遮罩关闭。
   *
   * 内容在这里按 sheet 状态分支，而不是把 builder 当参数传进来 ——
   * ArkTS 的 @Builder 不接受"产生 UI 的闭包"作参数，
   * 那样写编译期就会报 '(' expected。要传 UI 只能用 @BuilderParam，
   * 但这里分支不多，直接内联更省事。
   */
  @Builder
  sheetShell() {
    Column() {
      Column()
        .layoutWeight(1)
        .width('100%')
        .backgroundColor('#59000000')
        .onClick(() => this.closeSheet())

      Column({ space: 14 }) {
        Row()
          .width(36)
          .height(4)
          .borderRadius(2)
          .backgroundColor(theme.palette.border)

        if (this.sheet === SheetKind.RENAME) {
          // 同一个输入弹层服务两种重命名：项目和分组，按哪个 target 非空区分
          if (this.targetGroupId.length > 0) {
            this.textInputSheet('重命名分组', '分组名称', '')
          } else {
            this.textInputSheet('重命名项目', '项目名称', '留空恢复为原始名称')
          }
        } else if (this.sheet === SheetKind.GROUP) {
          this.groupSheet()
        } else if (this.sheet === SheetKind.NEW_GROUP) {
          this.textInputSheet('新建分组', '分组名称', '')
        } else if (this.sheet === SheetKind.GROUP_MENU) {
          this.groupMenuSheet()
        } else if (this.sheet === SheetKind.PROJECT_MENU) {
          this.projectMenuSheet()
        }
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 12, bottom: 26 })
      .backgroundColor(theme.palette.surface)
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .width('100%')
    .height('100%')
  }

  /** 输入弹层的确定按钮：按当前 sheet 决定落到哪个动作 */
  private confirmInput(): void {
    if (this.sheet === SheetKind.NEW_GROUP) {
      const pending = this.targetId;
      projectPrefs.createGroup(this.inputText).then((id: string) => {
        // 从「移动到分组」进来的，建完直接归位，省一次操作
        if (id.length > 0 && pending.length > 0) {
          projectPrefs.assignGroup(pending, id);
        }
      });
    } else if (this.targetGroupId.length > 0) {
      projectPrefs.renameGroup(this.targetGroupId, this.inputText);
    } else {
      projectPrefs.rename(this.targetId, this.inputText);
    }
    this.rebuildRows();
    this.closeSheet();
  }

  @Builder
  textInputSheet(title: string, placeholder: string, hint: string) {
    Column({ space: 12 }) {
      Text(title)
        .fontSize(theme.fs(FontSize.HEADING))
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.palette.text)
        .width('100%')

      TextInput({ placeholder: placeholder, text: this.inputText })
        .width('100%')
        .height(46)
        .fontSize(theme.fs(FontSize.BODY))
        .fontColor(theme.palette.text)
        .placeholderColor(theme.palette.textTertiary)
        .backgroundColor(theme.palette.surfaceAlt)
        .borderRadius(12)
        .onChange((v: string) => { this.inputText = v; })

      if (hint.length > 0) {
        Text(hint)
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.textTertiary)
          .width('100%')
      }

      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(46)
          .fontSize(theme.fs(FontSize.BODY))
          .fontColor(theme.palette.text)
          .backgroundColor(theme.palette.surfaceAlt)
          .borderRadius(12)
          .onClick(() => this.closeSheet())
        Button('确定')
          .layoutWeight(1)
          .height(46)
          .fontSize(theme.fs(FontSize.BODY))
          .fontColor(theme.palette.onAccent)
          .backgroundColor(theme.palette.accent)
          .borderRadius(12)
          .onClick(() => this.confirmInput())
      }
      .width('100%')
    }
    .width('100%')
  }

  @Builder
  groupRow(label: string, selected: boolean, action: () => void) {
    Row() {
      Text(label)
        .fontSize(theme.fs(FontSize.BODY))
        .fontColor(selected ? theme.palette.accent : theme.palette.text)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (selected) {
        Text('✓')
          .fontSize(theme.fs(FontSize.BODY))
          .fontColor(theme.palette.accent)
      }
    }
    .width('100%')
    .padding({ top: 13, bottom: 13 })
    .onClick(() => { action(); })
  }

  /** 选择分组 */
  @Builder
  groupSheet() {
    Column({ space: 2 }) {
      Text('移动到分组')
        .fontSize(theme.fs(FontSize.HEADING))
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.palette.text)
        .width('100%')
        .padding({ bottom: 6 })

      Scroll() {
        Column() {
          this.groupRow('未分组', projectPrefs.groupIdOf(this.targetId) === NO_GROUP, (): void => {
            projectPrefs.assignGroup(this.targetId, NO_GROUP);
            this.rebuildRows();
            this.closeSheet();
          })

          ForEach(projectPrefs.groups, (g: ProjectGroup) => {
            Divider().strokeWidth(0.5).color(theme.palette.border)
            this.groupRow(g.name, projectPrefs.groupIdOf(this.targetId) === g.id, (): void => {
              projectPrefs.assignGroup(this.targetId, g.id);
              this.rebuildRows();
              this.closeSheet();
            })
          }, (g: ProjectGroup) => g.id)
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 260 })
      .width('100%')
      .scrollBar(BarState.Off)

      Button('＋ 新建分组')
        .width('100%')
        .height(46)
        .fontSize(theme.fs(FontSize.BODY))
        .fontColor(theme.palette.accent)
        .backgroundColor(theme.palette.surfaceAlt)
        .borderRadius(12)
        .margin({ top: 10 })
        .onClick(() => {
          // 保留 targetId：建完组直接把当前项目放进去
          this.inputText = '';
          this.sheet = SheetKind.NEW_GROUP;
        })
    }
    .width('100%')
  }

  /** 分组自身的菜单 */
  @Builder
  groupMenuSheet() {
    Column({ space: 2 }) {
      Text(projectPrefs.groupName(this.targetGroupId))
        .fontSize(theme.fs(FontSize.HEADING))
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.palette.text)
        .width('100%')
        .padding({ bottom: 6 })

      this.groupRow('重命名分组', false, (): void => {
        this.inputText = projectPrefs.groupName(this.targetGroupId);
        this.sheet = SheetKind.RENAME;
      })
      Divider().strokeWidth(0.5).color(theme.palette.border)

      Row() {
        Text('删除分组')
          .fontSize(theme.fs(FontSize.BODY))
          .fontColor(theme.palette.danger)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 13, bottom: 13 })
      .onClick(() => {
        projectPrefs.deleteGroup(this.targetGroupId);
        this.rebuildRows();
        this.closeSheet();
      })

      Text('删除分组不会影响里面的项目，它们会回到「未分组」')
        .fontSize(theme.fs(FontSize.TINY))
        .fontColor(theme.palette.textTertiary)
        .width('100%')
        .padding({ top: 4 })
    }
    .width('100%')
  }

  /**
   * 齿轮打开的项目设置面板。
   *
   * 工作目录整块可点即复制，不另设复制按钮 —— 一个只有单一动作的
   * 区域，再挂一个按钮是多余的，还会挤占本就不宽的路径显示区。
   */
  @Builder
  projectMenuSheet() {
    Column({ space: 2 }) {
      Text(this.targetName())
        .fontSize(theme.fs(FontSize.HEADING))
        .fontWeight(FontWeight.Medium)
        .fontColor(theme.palette.text)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ bottom: 8 })

      this.groupRow('重命名', false, (): void => {
        this.inputText = this.targetName();
        this.sheet = SheetKind.RENAME;
      })
      Divider().strokeWidth(0.5).color(theme.palette.border)

      Row() {
        Text('分组')
          .fontSize(theme.fs(FontSize.BODY))
          .fontColor(theme.palette.text)
          .layoutWeight(1)
        Text(this.targetGroupLabel())
          .fontSize(theme.fs(FontSize.LABEL))
          .fontColor(theme.palette.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '50%' })
        Text('›')
          .fontSize(theme.fs(16))
          .fontColor(theme.palette.textTertiary)
          .margin({ left: 6 })
      }
      .width('100%')
      .padding({ top: 13, bottom: 13 })
      .onClick(() => { this.sheet = SheetKind.GROUP; })

      Divider().strokeWidth(0.5).color(theme.palette.border)

      Row() {
        Column({ space: 2 }) {
          Text('消息通知')
            .fontSize(theme.fs(FontSize.BODY))
            .fontColor(theme.palette.text)
          Text('切到后台时，需要授权或任务完成会提醒')
            .fontSize(theme.fs(FontSize.TINY))
            .fontColor(theme.palette.textTertiary)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: projectPrefs.isNotifyOn(this.targetId) })
          .selectedColor(theme.palette.accent)
          .onChange((v: boolean) => { this.onNotifyChange(v); })
      }
      .width('100%')
      .padding({ top: 13, bottom: 13 })

      Divider().strokeWidth(0.5).color(theme.palette.border)

      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text('工作目录')
            .fontSize(theme.fs(FontSize.LABEL))
            .fontColor(theme.palette.textSecondary)
          Blank()
          Text('点击复制')
            .fontSize(theme.fs(FontSize.TINY))
            .fontColor(theme.palette.accent)
        }
        .width('100%')

        Text(this.targetPath())
          .fontSize(theme.fs(FontSize.TINY))
          .fontFamily('monospace')
          .fontColor(theme.palette.text)
          .lineHeight(theme.fs(FontSize.TINY) * 1.55)
          .width('100%')
          .padding(12)
          .borderRadius(10)
          .backgroundColor(theme.palette.surfaceAlt)
      }
      .width('100%')
      .padding({ top: 12 })
      .onClick(() => { this.copyPath(this.targetPath()); })
    }
    .width('100%')
  }

  /**
   * 切换通知开关。
   *
   * 开启时立刻申请系统通知权限 —— 等到真要发通知才申请的话，
   * 用户早已切到后台，弹窗根本看不见，表现就是"开了但没提醒"。
   */
  private onNotifyChange(on: boolean): void {
    const pid = this.targetId;
    projectPrefs.setNotify(pid, on);
    if (!on) {
      return;
    }
    notifier.ensureReady().then((ok: boolean) => {
      if (!ok) {
        this.getUIContext().getPromptAction().showToast({
          message: '系统通知权限未开启，请到设置里允许'
        });
      }
    });
  }

  /** 当前操作目标的显示名 */
  private targetName(): string {
    const p = this.shown().find((x) => x.id === this.targetId);
    return p === undefined ? '' : projectPrefs.displayName(p.id, p.name);
  }

  private targetPath(): string {
    const p = this.shown().find((x) => x.id === this.targetId);
    return p === undefined ? '' : p.path;
  }

  private targetGroupLabel(): string {
    const gid = projectPrefs.groupIdOf(this.targetId);
    if (gid === NO_GROUP) {
      return '未分组';
    }
    const name = projectPrefs.groupName(gid);
    return name.length > 0 ? name : '未分组';
  }

  @Builder
  sheetOverlay() {
    if (this.sheet !== SheetKind.NONE) {
      this.sheetShell()
    }
  }

  // -------------------------------------------------------------------------
  // 两种列表形态
  // -------------------------------------------------------------------------

  /**
   * 取行上的项目。
   *
   * LazyForEach 的 item builder 里只能写 UI 语法，声明不了局部常量；
   * 而 ArkTS 又不把 null 收窄带进嵌套闭包，直接用 row.project 会报
   * "ProjectInfo | null is not assignable to ProjectInfo"。
   * 用方法把断言收在一处，调用方已通过 kind 保证非空。
   */
  private projectOf(row: ListRow): ProjectInfo {
    return row.project as ProjectInfo;
  }

  /** 一行的渲染分发 */
  @Builder
  rowView(row: ListRow) {
    if (row.kind === RowKind.RUNNING_HEADER) {
      this.runningHeader(row.count)
    } else if (row.kind === RowKind.GROUP_HEADER && row.group !== null) {
      this.groupHeader(row.group, row.count)
    } else if (row.kind === RowKind.SECTION_HEADER) {
      this.sectionHeader(row.title, row.count)
    } else {
      Row().height(8)
    }
  }

  /**
   * 唯一的列表体。
   *
   * 分区已经在 rebuildRows 里拍平成行，这里只需一个 LazyForEach ——
   * 之前是多个 ForEach 拼接，110 个卡片会被一次性全部实例化。
   */
  @Builder
  projectList() {
    List() {
      LazyForEach(this.rows, (row: ListRow) => {
        // 分两支而不是给 swipeAction 传 undefined ——
        // 条件属性传 undefined 的行为没有保证，标题行也不该能左滑
        if (row.kind === RowKind.PROJECT && row.project !== null) {
          ListItem() {
            this.projectCard(this.projectOf(row))
          }
          .padding({ left: 16, right: 16, bottom: 10 })
          .swipeAction({
            end: {
              builder: () => { this.swipeActions(this.projectOf(row)) },
              actionAreaDistance: 60
            },
            edgeEffect: SwipeEdgeEffect.Spring
          })
          .onClick(() => { this.openProject(this.projectOf(row)); })
        } else {
          ListItem() {
            this.rowView(row)
          }
        }
      }, (row: ListRow) => row.key)
    }
    .layoutWeight(1)
    .width('100%')
    // 上下各多建 8 行，快速滑动时不会出现空白
    .cachedCount(8)
    .scrollBar(BarState.Off)
  }

  build() {
    Stack() {
      Column() {
        // ---- 标题 ----
        Row() {
          Column({ space: 2 }) {
            Text('对话')
              .fontSize(theme.fs(FontSize.TITLE))
              .fontWeight(FontWeight.Bold)
              .fontColor(theme.palette.text)
            if (appStore.serverName.length > 0) {
              Text(appStore.serverName)
                .fontSize(theme.fs(FontSize.TINY))
                .fontColor(theme.palette.textTertiary)
            }
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Text('＋ 分组')
            .fontSize(theme.fs(FontSize.LABEL))
            .fontColor(theme.palette.accent)
            .padding({ left: 12, right: 4, top: 6, bottom: 6 })
            .onClick(() => {
              this.targetId = '';
              this.inputText = '';
              this.sheet = SheetKind.NEW_GROUP;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 16, top: 14, bottom: 10 })
        .alignItems(VerticalAlign.Center)

        // ---- 搜索 ----
        if (!this.loading && this.errorText.length === 0 && this.shown().length > 0) {
          Column() {
            this.searchBar()
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 6 })
        }

        if (this.loading) {
          Column() {
            LoadingProgress().width(36).height(36).color(theme.palette.accent)
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.errorText.length > 0) {
          this.placeholder(this.errorText, true)
        } else if (this.shown().length === 0) {
          // 区分"服务器上没有"和"被筛选挡住了"，否则用户会以为数据丢了
          this.placeholder(
            folderFilter.enabled && folderFilter.totalCount() > 0
              ? `文件夹筛选已开启，${folderFilter.totalCount()} 个项目被隐藏。可在「我的」里调整`
              : '服务器上还没有 Claude 会话记录',
            true
          )
        } else if (this.searching() && this.results.length === 0) {
          this.placeholder(`没有匹配「${this.activeQuery}」的项目`, false)
        } else {
          this.projectList()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(theme.palette.bg)

      this.sheetOverlay()
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Bottom)
  }
}
