/**
 * 主题系统：配色 + 字号缩放。
 *
 * 三套配色都按各自产品的真实设计语言取色，不是随手调的：
 *   claude —— 暖米白底 + 陶土橙，Claude 的标志性观感
 *   gpt    —— 纯白底 + 墨绿，ChatGPT 的克制风格
 *   dark   —— Claude 深色模式，暖调而非纯黑，长时间阅读不刺眼
 *
 * 字号不写死，全部走 fs()，用户在「我的」里调的缩放对全局生效。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** 一套完整配色 */
export class Palette {
  /** 页面底色 */
  bg: string = '';
  /** 卡片/输入框等前景容器 */
  surface: string = '';
  /** 次级容器：代码块、用户气泡、未选中态 */
  surfaceAlt: string = '';
  /** 正文 */
  text: string = '';
  /** 辅助信息：时间、路径、副标题 */
  textSecondary: string = '';
  /** 最弱信息：计数、占位 */
  textTertiary: string = '';
  /** 强调色：按钮、选中态、链接 */
  accent: string = '';
  /** 强调色上的文字 */
  onAccent: string = '';
  /** 分隔线与描边 */
  border: string = '';
  /** 用户消息气泡底色 */
  userBubble: string = '';
  /** 危险/错误 */
  danger: string = '';
  /** 底部导航栏底色 */
  navBg: string = '';

  constructor(
    bg: string, surface: string, surfaceAlt: string,
    text: string, textSecondary: string, textTertiary: string,
    accent: string, onAccent: string, border: string,
    userBubble: string, danger: string, navBg: string
  ) {
    this.bg = bg;
    this.surface = surface;
    this.surfaceAlt = surfaceAlt;
    this.text = text;
    this.textSecondary = textSecondary;
    this.textTertiary = textTertiary;
    this.accent = accent;
    this.onAccent = onAccent;
    this.border = border;
    this.userBubble = userBubble;
    this.danger = danger;
    this.navBg = navBg;
  }
}

export class ThemeId {
  static readonly CLAUDE: string = 'claude';
  static readonly GPT: string = 'gpt';
  static readonly DARK: string = 'dark';
}

/** Claude：暖米白 + 陶土橙 */
const CLAUDE = new Palette(
  '#FAF9F5', '#FFFFFF', '#F0EEE6',
  '#141413', '#6B6A66', '#A3A29E',
  '#C96442', '#FFFFFF', '#E8E6DC',
  '#F0EEE6', '#BC4C3C', '#F5F3EC'
);

/** GPT：纯白 + 墨绿 */
const GPT = new Palette(
  '#FFFFFF', '#FFFFFF', '#F7F7F8',
  '#0D0D0D', '#5D5D5D', '#8E8E8E',
  '#10A37F', '#FFFFFF', '#E5E5E5',
  '#F4F4F4', '#E02B2B', '#FFFFFF'
);

/** 深色：暖调而非纯黑，长时间阅读更舒适 */
const DARK = new Palette(
  '#1F1E1D', '#262624', '#30302E',
  '#F5F4EF', '#B4B2AC', '#85837D',
  '#D97757', '#1F1E1D', '#3A3937',
  '#35342F', '#E5715C', '#242322'
);

/** 主题元信息，供设置页渲染选项卡片 */
export class ThemeOption {
  id: string;
  name: string;
  desc: string;
  palette: Palette;

  constructor(id: string, name: string, desc: string, palette: Palette) {
    this.id = id;
    this.name = name;
    this.desc = desc;
    this.palette = palette;
  }
}

export const THEME_OPTIONS: ThemeOption[] = [
  new ThemeOption(ThemeId.CLAUDE, 'Claude', '暖米白 · 陶土橙', CLAUDE),
  new ThemeOption(ThemeId.GPT, 'GPT', '纯白 · 墨绿', GPT),
  new ThemeOption(ThemeId.DARK, '深色', '暖调深色 · 护眼', DARK)
];

/** 字号档位 */
export class FontScaleOption {
  value: number;
  label: string;

  constructor(value: number, label: string) {
    this.value = value;
    this.label = label;
  }
}

export const FONT_SCALES: FontScaleOption[] = [
  new FontScaleOption(0.85, '小'),
  new FontScaleOption(1.0, '标准'),
  new FontScaleOption(1.15, '大'),
  new FontScaleOption(1.3, '特大')
];

function paletteOf(id: string): Palette {
  if (id === ThemeId.GPT) {
    return GPT;
  }
  if (id === ThemeId.DARK) {
    return DARK;
  }
  return CLAUDE;
}

const STORE_NAME = 'cc_remoter_theme';
const KEY_THEME = 'themeId';
const KEY_SCALE = 'fontScale';

@ObservedV2
export class ThemeStore {
  @Trace themeId: string = ThemeId.CLAUDE;
  @Trace fontScale: number = 1.0;
  /**
   * 当前配色。
   *
   * 整体替换而不是逐字段赋值 —— @Trace 对引用替换的观察最直接，
   * 也避免切主题时出现十几个字段逐个变化导致的中间态闪烁。
   */
  @Trace palette: Palette = CLAUDE;

  private store: preferences.Preferences | null = null;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.store = await preferences.getPreferences(context, STORE_NAME);
    const id = await this.store.get(KEY_THEME, ThemeId.CLAUDE) as string;
    const scale = await this.store.get(KEY_SCALE, 1.0) as number;
    this.themeId = id;
    this.fontScale = scale;
    this.palette = paletteOf(id);
  }

  async setTheme(id: string): Promise<void> {
    this.themeId = id;
    this.palette = paletteOf(id);
    if (this.store !== null) {
      await this.store.put(KEY_THEME, id);
      await this.store.flush();
    }
  }

  async setFontScale(scale: number): Promise<void> {
    this.fontScale = scale;
    if (this.store !== null) {
      await this.store.put(KEY_SCALE, scale);
      await this.store.flush();
    }
  }

  /** 按用户设置缩放字号。所有字号都要走这里，不要写死 */
  fs(base: number): number {
    return Math.round(base * this.fontScale);
  }

  /** 深色主题下部分组件需要反色处理 */
  isDark(): boolean {
    return this.themeId === ThemeId.DARK;
  }
}

/** 全局单例 */
export const theme: ThemeStore = new ThemeStore();

/**
 * 基准字号。
 *
 * ASSISTANT 是模型回复的正文，刻意比用户消息小一档：
 * 模型回复通常很长，小一号能在一屏里放下更多内容，
 * 长文阅读的舒适度也更好。
 */
export class FontSize {
  static readonly TITLE: number = 24;
  static readonly HEADING: number = 18;
  static readonly BODY: number = 15;
  /** 模型回复正文 */
  static readonly ASSISTANT: number = 12;
  static readonly LABEL: number = 13;
  static readonly CAPTION: number = 12;
  static readonly TINY: number = 11;
}
