/**
 * 配对页：输入服务器地址和配对码，换取长期 token。
 *
 * 分两步走而不是一次提交：先 ping 校验地址，再验配对码。
 * 这样「地址写错」和「配对码错」能给出不同提示 ——
 * 合成一步的话用户只会看到一个笼统的失败，不知道该改哪个。
 */

import { apiClient, ApiException } from '../net/ApiClient';
import { tokenStore, Credentials } from '../store/TokenStore';
import { appStore } from '../store/AppStore';
import { PairResponse, PingResponse } from '../net/Protocol';
import { deviceInfo } from '@kit.BasicServicesKit';

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

  build() {
    Column({ space: 16 }) {
      Text('连接服务器')
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 48, bottom: 8 })

      Text('在服务器上运行 ClaudeHarmonyRemoter 服务端，终端会显示地址和配对码')
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .margin({ bottom: 16 })

      // ---- 地址 ----
      Column({ space: 8 }) {
        Text('服务器地址').fontSize(14).width('100%')
        Row({ space: 8 }) {
          TextInput({ placeholder: '192.168.1.10', text: this.host })
            .layoutWeight(3)
            .enabled(!this.hostVerified && !this.busy)
            .onChange((v: string) => { this.host = v; })
          TextInput({ placeholder: '端口', text: this.port })
            .layoutWeight(1)
            .type(InputType.Number)
            .enabled(!this.hostVerified && !this.busy)
            .onChange((v: string) => { this.port = v; })
        }
      }
      .width('100%')

      if (this.hostVerified) {
        Row({ space: 6 }) {
          Text('✓').fontColor($r('sys.color.font_emphasize'))
          Text(`已找到服务器 ${this.verifiedServerName}`)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
          Blank()
          Text('修改')
            .fontSize(13)
            .fontColor($r('sys.color.font_emphasize'))
            .onClick(() => {
              this.hostVerified = false;
              this.errorText = '';
            })
        }
        .width('100%')

        // ---- 配对码 ----
        Column({ space: 8 }) {
          Text('配对码').fontSize(14).width('100%')
          TextInput({ placeholder: '6 位数字', text: this.code })
            .type(InputType.Number)
            .maxLength(6)
            .enabled(!this.busy)
            .onChange((v: string) => { this.code = v; })
        }
        .width('100%')
        .margin({ top: 8 })
      }

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .fontSize(13)
          .fontColor($r('sys.color.warning'))
          .width('100%')
      }

      Button(this.hostVerified ? '完成配对' : '下一步')
        .width('100%')
        .enabled(!this.busy)
        .onClick(() => {
          if (this.hostVerified) {
            this.submitCode();
          } else {
            this.verifyHost();
          }
        })
        .margin({ top: 16 })

      if (this.busy) {
        LoadingProgress().width(28).height(28)
      }

      Blank()
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, bottom: 24 })
  }
}
