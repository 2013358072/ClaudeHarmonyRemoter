# 构建与签名

## 结论先说

**未签名的 HAP 装不到鸿蒙手机上。** 鸿蒙对应用安装的管控比 Android 严得多，没有「打开未知来源」这种开关。

Release 页附带的 `*-unsigned.hap` 只是构建产物存档，**不能直接安装**。要装到你自己手机上，必须用你自己的华为开发者账号签名——这一步没法由别人代做，因为签名材料绑定你的账号。

好消息是 DevEco Studio 的自动签名基本是点几下的事。

---

## 一、装到自己手机（调试签名）

适用于自用。**这是你要走的路径。**

### 前置条件

- 华为开发者账号，且已完成**实名认证**（个人认证即可）
- DevEco Studio 已登录该账号
- 手机用 USB 连上电脑，开启「开发者模式」和「USB 调试」

### 步骤

1. DevEco Studio 打开项目
2. 菜单 **File → Project Structure → Project → Signing Configs**
3. 勾选 **Automatically generate signature**（自动生成签名）
4. 等它跑完——会自动完成这些事：
   - 生成密钥库 `.p12`
   - 申请调试证书 `.cer`
   - 申请调试 Profile `.p7b`（其中包含你这台设备的 UDID）
   - 把配置写回 `build-profile.json5` 的 `signingConfigs`
5. 点 **Run**（▶）直接装到手机；或 **Build → Build Hap(s)/APP(s) → Build Hap(s)** 生成签名包

签名后的产物在：

```
entry/build/default/outputs/default/entry-default-signed.hap
```

也可以用命令行安装：

```bash
hdc install entry/build/default/outputs/default/entry-default-signed.hap
```

### 注意

- **调试 Profile 绑定设备**。换一台手机要重新执行自动签名，让它把新设备加进去。
- **调试证书有有效期**，过期后需要在 DevEco 里重新生成。
- 自动签名生成的 `.p12` / `.cer` / `.p7b` 会落在本地，`.gitignore` 已经把这些后缀排除了——**别提交它们**。

---

## 二、分发给别人装

这条路要难得多，鸿蒙没有 Android 那种「发个包就能装」的模式。

| 方式 | 说明 |
|---|---|
| **应用市场上架** | 走 AppGallery Connect 提交审核。本项目是自用工具，不适合。 |
| **企业内部应用** | 需要企业开发者账号。 |
| **把对方设备加进调试 Profile** | 需要对方的设备 UDID，且有数量上限。小范围内可行。 |

对本项目来说，**建议每个人自己 clone 仓库、自己签名**，而不是分发 HAP。

---

## 三、命令行构建

不签名的构建（CI 里跑类型检查和编译很有用）：

```bash
# 项目根目录
hvigorw assembleHap --mode module -p product=default -p buildMode=release
```

如果项目根目录没有 `hvigorw`（DevEco 未生成），可以直接用 DevEco 自带的：

```bash
DEVECO="/c/Program Files/Huawei/DevEco Studio"
"$DEVECO/tools/node/node.exe" "$DEVECO/tools/hvigor/bin/hvigorw.js" \
  assembleHap --mode module -p product=default -p buildMode=release --no-daemon
```

产物：

```
entry/build/default/outputs/default/entry-default-unsigned.hap
```

**签名配置好之后**，同一条命令产出的就是 `entry-default-signed.hap`，可直接安装。

---

## 四、服务端不需要打包

服务端是 Node.js，直接跑源码即可：

```bash
cd server
npm install
npm start
```

要做成后台常驻服务，Linux 上用 systemd：

```ini
# /etc/systemd/system/claude-harmony.service
[Unit]
Description=ClaudeHarmonyRemoter Server
After=network.target

[Service]
Type=simple
User=你的用户名
WorkingDirectory=/path/to/ClaudeHarmonyRemoter/server
# 中转配置必须在这里给，服务端会原样继承给拉起的 claude 进程
Environment="ANTHROPIC_BASE_URL=https://你的中转地址"
Environment="ANTHROPIC_AUTH_TOKEN=你的token"
ExecStart=/usr/bin/npx tsx src/index.ts
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now claude-harmony
sudo journalctl -u claude-harmony -f   # 看配对码
```

配对码只在启动时打印一次、5 分钟有效。作为后台服务跑时，从日志里取。
