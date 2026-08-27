/**
 * 「我的」：外观设置与连接信息。
 *
 * 主题选择用实色卡片而不是文字列表 —— 配色这种东西描述再多不如直接看到，
 * 每张卡片用它自己的配色渲染，点之前就知道选完长什么样。
 */

import {
  theme,
  THEME_OPTIONS,
  FONT_SCALES,
  ThemeOption,
  FontScaleOption,
  FontSize
} from '../theme/Theme';
import { appStore } from '../store/AppStore';
import { apiClient } from '../net/ApiClient';

@ComponentV2
export struct ProfileView {
  /** 退出登录回调，由宿主切回配对页 */
  @Event onSignOut: () => void = () => {};

  @Builder
  sectionTitle(text: string) {
    Text(text)
      .fontSize(theme.fs(FontSize.LABEL))
      .fontColor(theme.palette.textSecondary)
      .width('100%')
      .padding({ left: 4, bottom: 10, top: 4 })
  }

  /** 主题卡片：用该主题自己的配色渲染，所见即所得 */
  @Builder
  themeCard(opt: ThemeOption) {
    Column({ space: 10 }) {
      // 迷你预览：模拟一条用户消息和一条模型回复
      Column({ space: 6 }) {
        Row() {
          Blank()
          Row()
            .width(38)
            .height(9)
            .borderRadius(5)
            .backgroundColor(opt.palette.userBubble)
        }
        .width('100%')

        Row()
          .width('82%')
          .height(7)
          .borderRadius(4)
          .backgroundColor(opt.palette.textSecondary)
        Row()
          .width('60%')
          .height(7)
          .borderRadius(4)
          .backgroundColor(opt.palette.textTertiary)

        Row() {
          Row()
            .width(28)
            .height(9)
            .borderRadius(5)
            .backgroundColor(opt.palette.accent)
          Blank()
        }
        .width('100%')
        .margin({ top: 2 })
      }
      .width('100%')
      .padding(12)
      .borderRadius(10)
      .backgroundColor(opt.palette.bg)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 2 }) {
        Text(opt.name)
          .fontSize(theme.fs(FontSize.LABEL))
          .fontWeight(FontWeight.Medium)
          .fontColor(theme.palette.text)
        Text(opt.desc)
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .padding(8)
    .borderRadius(14)
    .backgroundColor(theme.palette.surface)
    // 选中态用强调色描边，比打勾更直观也更安静
    .border({
      width: theme.themeId === opt.id ? 2 : 1,
      color: theme.themeId === opt.id ? theme.palette.accent : theme.palette.border
    })
    .onClick(() => { theme.setTheme(opt.id); })
  }

  @Builder
  fontChip(opt: FontScaleOption) {
    Text(opt.label)
      .fontSize(theme.fs(FontSize.LABEL))
      .fontColor(
        theme.fontScale === opt.value ? theme.palette.onAccent : theme.palette.text
      )
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .padding({ top: 9, bottom: 9 })
      .borderRadius(9)
      .backgroundColor(
        theme.fontScale === opt.value ? theme.palette.accent : Color.Transparent
      )
      .onClick(() => { theme.setFontScale(opt.value); })
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(theme.fs(FontSize.BODY))
        .fontColor(theme.palette.text)
      Blank()
      Text(value)
        .fontSize(theme.fs(FontSize.LABEL))
        .fontColor(theme.palette.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '60%' })
    }
    .width('100%')
    .padding({ top: 13, bottom: 13, left: 16, right: 16 })
  }

  build() {
    Column() {
      // ---- 标题 ----
      Row() {
        Text('我的')
          .fontSize(theme.fs(FontSize.TITLE))
          .fontWeight(FontWeight.Bold)
          .fontColor(theme.palette.text)
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 14, bottom: 12 })

      Scroll() {
        Column({ space: 22 }) {
          // ---- 外观 ----
          Column() {
            this.sectionTitle('主题配色')
            Row({ space: 10 }) {
              ForEach(THEME_OPTIONS, (opt: ThemeOption) => {
                this.themeCard(opt)
              }, (opt: ThemeOption) => opt.id)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }
          .width('100%')

          // ---- 字号 ----
          Column() {
            this.sectionTitle('字体大小')
            Row({ space: 4 }) {
              ForEach(FONT_SCALES, (opt: FontScaleOption) => {
                this.fontChip(opt)
              }, (opt: FontScaleOption) => opt.label)
            }
            .width('100%')
            .padding(4)
            .borderRadius(12)
            .backgroundColor(theme.palette.surfaceAlt)

            // 实时预览，调完立刻知道效果
            Column({ space: 8 }) {
              Row() {
                Blank()
                Text('帮我看下这段代码')
                  .fontSize(theme.fs(FontSize.BODY))
                  .fontColor(theme.palette.text)
                  .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                  .borderRadius(12)
                  .backgroundColor(theme.palette.userBubble)
              }
              .width('100%')

              Text('好的，我先读一下文件再给结论。模型回复用的字号比你的消息小一档，长文更好读。')
                .fontSize(theme.fs(FontSize.ASSISTANT))
                .fontColor(theme.palette.text)
                .width('100%')
                .lineHeight(theme.fs(FontSize.ASSISTANT) * 1.65)
            }
            .width('100%')
            .padding(14)
            .margin({ top: 10 })
            .borderRadius(12)
            .backgroundColor(theme.palette.surface)
            .border({ width: 1, color: theme.palette.border })
          }
          .width('100%')

          // ---- 连接 ----
          Column() {
            this.sectionTitle('连接')
            Column() {
              this.infoRow('服务器', appStore.serverName.length > 0 ? appStore.serverName : '未连接')
              Divider().strokeWidth(0.5).color(theme.palette.border).margin({ left: 16 })
              this.infoRow('地址', apiClient.baseUrl())
            }
            .width('100%')
            .borderRadius(14)
            .backgroundColor(theme.palette.surface)
            .border({ width: 1, color: theme.palette.border })
          }
          .width('100%')

          // ---- 退出 ----
          Button('断开连接')
            .width('100%')
            .height(46)
            .fontSize(theme.fs(FontSize.BODY))
            .fontColor(theme.palette.danger)
            .backgroundColor(theme.palette.surface)
            .borderRadius(14)
            .border({ width: 1, color: theme.palette.border })
            .onClick(() => { this.onSignOut(); })

          Text('CC-Remoter v0.1.2')
            .fontSize(theme.fs(FontSize.TINY))
            .fontColor(theme.palette.textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 4, bottom: 20 })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(theme.palette.bg)
  }
}
