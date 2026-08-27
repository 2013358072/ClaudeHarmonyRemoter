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

/** 当前打开的弹层。名字不能叫 Sheet —— 会和 ArkUI 的 bindSheet 一族撞车 */
class SheetKind {
  static readonly NONE: string = '';
  static readonly RENAME: string = 'rename';
  static readonly GROUP: string = 'group';
  static readonly NEW_GROUP: string = 'newGroup';
  static readonly GROUP_MENU: string = 'groupMenu';
}

@ComponentV2
export struct ProjectListView {
  @Consumer() pathStack: NavPathStack = new NavPathStack();
  @Local projects: ProjectInfo[] = [];
  @Local loading: boolean = true;
  @Local errorText: string = '';

  /** 搜索关键词。非空时列表切换为拍平的结果视图 */
  @Local query: string = '';

  // ---- 弹层状态 ----
  @Local sheet: string = SheetKind.NONE;
  /** 正在操作的项目 id */
  @Local targetId: string = '';
  /** 正在操作的分组 id */
  @Local targetGroupId: string = '';
  @Local inputText: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.errorText = '';
    try {
      this.projects = await apiClient.listProjects();
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
    return this.query.trim().length > 0;
  }

  /**
   * 搜索结果。匹配显示名和真实路径 ——
   * 用户可能记得的是项目名，也可能记得的是路径里的某一段。
   */
  private searchResults(): ProjectInfo[] {
    const q = this.query.trim().toLowerCase();
    return this.projects.filter((p) => {
      const name = projectPrefs.displayName(p.id, p.name).toLowerCase();
      if (name.indexOf(q) >= 0) {
        return true;
      }
      return p.path.toLowerCase().indexOf(q) >= 0;
    });
  }

  private runningItems(): ProjectInfo[] {
    return this.projects.filter((p) => p.running);
  }

  /** 置顶区排除运行中的 —— 后者已单独成区，不重复出现 */
  private pinnedItems(): ProjectInfo[] {
    return this.projects.filter((p) => !p.running && projectPrefs.isPinned(p.id));
  }

  private itemsInGroup(groupId: string): ProjectInfo[] {
    return this.projects.filter((p) =>
      !p.running
        && !projectPrefs.isPinned(p.id)
        && projectPrefs.groupIdOf(p.id) === groupId
    );
  }

  private ungroupedItems(): ProjectInfo[] {
    return this.projects.filter((p) => {
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
        .onChange((v: string) => { this.query = v; })
      if (this.query.length > 0) {
        Text('✕')
          .fontSize(theme.fs(FontSize.LABEL))
          .fontColor(theme.palette.textTertiary)
          .padding({ left: 4, right: 2 })
          .onClick(() => { this.query = ''; })
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

  /** 左滑操作条 */
  @Builder
  swipeActions(item: ProjectInfo) {
    Row({ space: 6 }) {
      this.swipeButton(
        projectPrefs.isPinned(item.id) ? '取消置顶' : '置顶',
        theme.palette.accent,
        (): void => { projectPrefs.togglePin(item.id); }
      )
      this.swipeButton('重命名', theme.palette.textSecondary, (): void => {
        this.targetId = item.id;
        this.inputText = projectPrefs.displayName(item.id, item.name);
        this.sheet = SheetKind.RENAME;
      })
      this.swipeButton('分组', theme.palette.textSecondary, (): void => {
        this.targetId = item.id;
        this.sheet = SheetKind.GROUP;
      })
    }
    .height('100%')
    .padding({ left: 6, right: 4 })
  }

  @Builder
  swipeButton(label: string, color: string, action: () => void) {
    Text(label)
      .fontSize(theme.fs(FontSize.TINY))
      .fontColor(theme.palette.onAccent)
      .textAlign(TextAlign.Center)
      .width(64)
      .height('86%')
      .borderRadius(12)
      .backgroundColor(color)
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
            this.closeSheet();
          })

          ForEach(projectPrefs.groups, (g: ProjectGroup) => {
            Divider().strokeWidth(0.5).color(theme.palette.border)
            this.groupRow(g.name, projectPrefs.groupIdOf(this.targetId) === g.id, (): void => {
              projectPrefs.assignGroup(this.targetId, g.id);
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

  @Builder
  sheetOverlay() {
    if (this.sheet !== SheetKind.NONE) {
      this.sheetShell()
    }
  }

  // -------------------------------------------------------------------------
  // 两种列表形态
  // -------------------------------------------------------------------------

  @Builder
  searchResultList() {
    if (this.searchResults().length === 0) {
      this.placeholder(`没有匹配「${this.query.trim()}」的项目`, false)
    } else {
      List() {
        ListItem() {
          this.sectionHeader('搜索结果', this.searchResults().length)
        }
        ForEach(this.searchResults(), (item: ProjectInfo) => {
          this.projectItem(item)
        }, (item: ProjectInfo) => `q_${item.id}`)

        ListItem() {
          Row().height(8)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
  }

  @Builder
  groupedList() {
    List() {
      // ---- 运行中 ----
      if (this.runningItems().length > 0) {
        ListItem() {
          this.runningHeader(this.runningItems().length)
        }
        ForEach(this.runningItems(), (item: ProjectInfo) => {
          this.projectItem(item)
        }, (item: ProjectInfo) => `run_${item.id}`)
      }

      // ---- 置顶 ----
      if (this.pinnedItems().length > 0) {
        ListItem() {
          this.sectionHeader('置顶', this.pinnedItems().length)
        }
        ForEach(this.pinnedItems(), (item: ProjectInfo) => {
          this.projectItem(item)
        }, (item: ProjectInfo) => `pin_${item.id}`)
      }

      // ---- 分组抽屉 ----
      ForEach(projectPrefs.groups, (g: ProjectGroup) => {
        ListItem() {
          this.groupHeader(g, this.itemsInGroup(g.id).length)
        }
        if (!g.collapsed) {
          ForEach(this.itemsInGroup(g.id), (item: ProjectInfo) => {
            this.projectItem(item)
          }, (item: ProjectInfo) => `${g.id}_${item.id}`)
        }
      }, (g: ProjectGroup) => g.id)

      // ---- 未分组 ----
      if (this.ungroupedItems().length > 0) {
        if (projectPrefs.groups.length > 0
          || this.pinnedItems().length > 0
          || this.runningItems().length > 0) {
          ListItem() {
            this.sectionHeader('未分组', this.ungroupedItems().length)
          }
        }
        ForEach(this.ungroupedItems(), (item: ProjectInfo) => {
          this.projectItem(item)
        }, (item: ProjectInfo) => `ung_${item.id}`)
      }

      ListItem() {
        Row().height(8)
      }
    }
    .layoutWeight(1)
    .width('100%')
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
        if (!this.loading && this.errorText.length === 0 && this.projects.length > 0) {
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
        } else if (this.projects.length === 0) {
          this.placeholder('服务器上还没有 Claude 会话记录', true)
        } else if (this.searching()) {
          this.searchResultList()
        } else {
          this.groupedList()
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
