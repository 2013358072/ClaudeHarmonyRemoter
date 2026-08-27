/**
 * 配对页：输入服务器地址和配对码，换取长期 token。
 *
 * 分两步走而不是一次提交：先 ping 校验地址，再验配对码。
 * 这样「地址写错」和「配对码错」能给出不同提示 ——
 * 合成一步的话用户只会看到一个笼统的失败，不知道该改哪个。
 *
 * 视觉上用步骤指示器把这两步显式化，让用户知道自己走到哪了。
 */

import { apiClient, ApiException } from '../net/ApiClient';
import { tokenStore, Credentials } from '../store/TokenStore';
import { appStore } from '../store/AppStore';
import { PairResponse, PingResponse } from '../net/Protocol';
import { deviceInfo } from '@kit.BasicServicesKit';
import { theme, FontSize } from '../theme/Theme';
import { scanCore, scanBarcode } from '@kit.ScanKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { parsePairPayload, PairPayload } from '../utils/PairPayload';

@ComponentV2
export struct PairingView {
  /** 配对成功回调，由宿主切换根页面 */
  @Event onPaired: () => void = () => {};

  @Local host: string = '';
  @Local port: string = '4517';
  @Local code: string = '';

  /** 地址是否已通过 ping 校验 */
  @Local hostVerified: boolean = false;
  @Local verifiedServerName: string = '';

  @Local busy: boolean = false;
  @Local errorText: string = '';

  private parsePort(): number {
    const n = Number.parseInt(this.port, 10);
    return Number.isInteger(n) && n > 0 && n < 65536 ? n : 4517;
  }

  /**
   * 扫码配对：一步直达。
   *
   * 二维码里 host / port / code 都有，没必要再让用户走"先验地址再输码"
   * 那两步 —— 手输时分两步是为了区分错因，扫码则不存在输错的可能。
   * 所以直接调 pair，失败了再回落到手动流程并把地址填好。
   */
  async scanAndPair(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.errorText = '';

    let raw = '';
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      };
      // getHostContext() 返回 Context | undefined，不收窄的话
      // 三个重载选不出来，会推断成 void & Promise<ScanResult>
      const ctx = this.getUIContext().getHostContext() as common.Context;
      const result: scanBarcode.ScanResult =
        await scanBarcode.startScanForResult(ctx, options);
      raw = result.originalValue ?? '';
    } catch (e) {
      const err = e as BusinessError;
      // 用户主动取消扫码不是错误，不该弹红字
      if (err.code !== 1000500001) {
        this.errorText = `扫码失败：${err.message ?? '未知错误'}`;
      }
      return;
    }

    const payload: PairPayload | null = parsePairPayload(raw);
    if (payload === null) {
      this.errorText = '这个二维码不是 CC-Remoter 的配对码';
      return;
    }

    // 把地址回填，失败时用户可以直接接着手动改
    this.host = payload.host;
    this.port = `${payload.port}`;
    this.code = payload.code;
    this.hostVerified = true;

    await this.submitCode();
  }

  /** 第一步：校验地址可达 */
  async verifyHost(): Promise<void> {
    if (this.host.trim().length === 0) {
      this.errorText = '请填写服务器地址';
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      const res: PingResponse = await apiClient.ping(this.host.trim(), this.parsePort());
      this.hostVerified = true;
      this.verifiedServerName = res.serverName;
      if (!res.pairingOpen) {
        this.errorText = '服务器当前没有可用的配对码，请查看服务器终端';
      }
    } catch (e) {
      const err = e as ApiException;
      this.errorText = err.message;
      this.hostVerified = false;
    } finally {
      this.busy = false;
    }
  }

  /** 第二步：用配对码换 token */
  async submitCode(): Promise<void> {
    if (this.code.trim().length !== 6) {
      this.errorText = '配对码是 6 位数字';
      return;
    }
    this.busy = true;
    this.errorText = '';
    try {
      const host = this.host.trim();
      const port = this.parsePort();
      const res: PairResponse = await apiClient.pair(
        host,
        port,
        this.code.trim(),
        deviceInfo.marketName
      );

      const creds: Credentials = {
        host: host,
        port: port,
        token: res.token,
        serverName: res.serverName
      };
      await tokenStore.save(creds);
      apiClient.configure(host, port, res.token);
      appStore.serverName = res.serverName;

      // 全局 promptAction.showToast 已废弃，走 UIContext 拿实例
      this.getUIContext().getPromptAction().showToast({
        message: `已连接到 ${res.serverName}`
      });
      this.onPaired();
    } catch (e) {
      const err = e as ApiException;
      this.errorText = err.message;
    } finally {
      this.busy = false;
    }
  }

  /** 步骤圆点 */
  @Builder
  stepDot(index: number, active: boolean, done: boolean) {
    Row() {
      if (done) {
        Text('✓')
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(theme.palette.onAccent)
      } else {
        Text(`${index}`)
          .fontSize(theme.fs(FontSize.TINY))
          .fontColor(active ? theme.palette.onAccent : theme.palette.textTertiary)
      }
    }
    .width(22)
    .height(22)
    .borderRadius(11)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(
      (active || done) ? theme.palette.accent : theme.palette.surfaceAlt
    )
  }

  @Builder
  steps() {
    Row({ space: 8 }) {
      this.stepDot(1, !this.hostVerified, this.hostVerified)
      Row()
        .width(28)
        .height(1.5)
        .backgroundColor(this.hostVerified ? theme.palette.accent : theme.palette.border)
      this.stepDot(2, this.hostVerified, false)
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  field(label: string) {
    Text(label)
      .fontSize(theme.fs(FontSize.TINY))
      .fontColor(theme.palette.textSecondary)
      .width('100%')
      .padding({ left: 4, bottom: 6 })
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 18 }) {
          // ---- 品牌区 ----
          Column({ space: 14 }) {
            Image($r('app.media.startIcon'))
              .width(72)
              .height(72)
              .borderRadius(18)

            Column({ space: 5 }) {
              Text('CC-Remoter')
                .fontSize(theme.fs(26))
                .fontWeight(FontWeight.Bold)
                .fontColor(theme.palette.text)
              Text('远程操控你服务器上的 Claude Code')
                .fontSize(theme.fs(FontSize.LABEL))
                .fontColor(theme.palette.textTertiary)
                .textAlign(TextAlign.Center)
            }
          }
          .width('100%')
          .margin({ top: 56, bottom: 8 })

          this.steps()

          // ---- 表单 ----
          Column({ space: 16 }) {
            Column() {
              this.field('服务器地址')
              Row({ space: 8 }) {
                TextInput({ placeholder: '192.168.1.10', text: this.host })
                  .layoutWeight(3)
                  .height(46)
                  .fontSize(theme.fs(FontSize.BODY))
                  .fontColor(theme.palette.text)
                  .placeholderColor(theme.palette.textTertiary)
                  .backgroundColor(theme.palette.surfaceAlt)
                  .borderRadius(12)
                  .enabled(!this.hostVerified && !this.busy)
                  .onChange((v: string) => { this.host = v; })

                TextInput({ placeholder: '端口', text: this.port })
                  .layoutWeight(1)
                  .height(46)
                  .fontSize(theme.fs(FontSize.BODY))
                  .fontColor(theme.palette.text)
                  .placeholderColor(theme.palette.textTertiary)
                  .backgroundColor(theme.palette.surfaceAlt)
                  .borderRadius(12)
                  .type(InputType.Number)
                  .enabled(!this.hostVerified && !this.busy)
                  .onChange((v: string) => { this.port = v; })
              }
            }
            .width('100%')

            if (this.hostVerified) {
              Row({ space: 8 }) {
                Text('✓')
                  .fontSize(theme.fs(FontSize.LABEL))
                  .fontColor(theme.palette.accent)
                Text(`已找到 ${this.verifiedServerName}`)
                  .fontSize(theme.fs(FontSize.LABEL))
                  .fontColor(theme.palette.textSecondary)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('修改')
                  .fontSize(theme.fs(FontSize.LABEL))
                  .fontColor(theme.palette.accent)
                  .onClick(() => {
                    this.hostVerified = false;
                    this.code = '';
                    this.errorText = '';
                  })
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 11, bottom: 11 })
              .borderRadius(12)
              .backgroundColor(theme.palette.surface)
              .border({ width: 1, color: theme.palette.border })

              Column() {
                this.field('配对码')
                TextInput({ placeholder: '6 位数字', text: this.code })
                  .width('100%')
                  .height(52)
                  .fontSize(theme.fs(22))
                  .fontColor(theme.palette.text)
                  .placeholderColor(theme.palette.textTertiary)
                  .backgroundColor(theme.palette.surfaceAlt)
                  .borderRadius(12)
                  .textAlign(TextAlign.Center)
                  .type(InputType.Number)
                  .maxLength(6)
                  .enabled(!this.busy)
                  .onChange((v: string) => { this.code = v; })
              }
              .width('100%')
            }

            if (this.errorText.length > 0) {
              Row({ space: 7 }) {
                Text('!')
                  .fontSize(theme.fs(FontSize.TINY))
                  .fontColor(theme.palette.onAccent)
                  .width(16)
                  .height(16)
                  .textAlign(TextAlign.Center)
                  .borderRadius(8)
                  .backgroundColor(theme.palette.danger)
                Text(this.errorText)
                  .fontSize(theme.fs(FontSize.LABEL))
                  .fontColor(theme.palette.danger)
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }

            Button(this.busy ? '请稍候…' : (this.hostVerified ? '完成配对' : '下一步'))
              .width('100%')
              .height(48)
              .fontSize(theme.fs(FontSize.BODY))
              .fontWeight(FontWeight.Medium)
              .fontColor(theme.palette.onAccent)
              .backgroundColor(this.busy ? theme.palette.textTertiary : theme.palette.accent)
              .borderRadius(24)
              .enabled(!this.busy)
              .onClick(() => {
                if (this.hostVerified) {
                  this.submitCode();
                } else {
                  this.verifyHost();
                }
              })
              .margin({ top: 4 })
          }
          .width('100%')

          // 扫码入口放在表单之后：服务端终端上二维码和数字码是并列的，
          // 但扫码明显更省事，给它一个独立且醒目的位置
          Row({ space: 10 }) {
            Row()
              .layoutWeight(1)
              .height(0.5)
              .backgroundColor(theme.palette.border)
            Text('或')
              .fontSize(theme.fs(FontSize.TINY))
              .fontColor(theme.palette.textTertiary)
            Row()
              .layoutWeight(1)
              .height(0.5)
              .backgroundColor(theme.palette.border)
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ top: 4 })

          Button('扫描二维码配对')
            .width('100%')
            .height(48)
            .fontSize(theme.fs(FontSize.BODY))
            .fontColor(theme.palette.accent)
            .backgroundColor(theme.palette.surfaceAlt)
            .borderRadius(24)
            .enabled(!this.busy)
            .onClick(() => { this.scanAndPair(); })

          Text('在服务器上运行服务端，终端会显示地址和配对码')
            .fontSize(theme.fs(FontSize.TINY))
            .fontColor(theme.palette.textTertiary)
            .textAlign(TextAlign.Center)
            .width('100%')
            .margin({ top: 4, bottom: 30 })
        }
        .width('100%')
        .padding({ left: 24, right: 24 })
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
