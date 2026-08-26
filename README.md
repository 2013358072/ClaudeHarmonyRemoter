<div align="center">
  <img src="assets/logo.png" width="140" alt="CC-Remoter">
</div>

<h1 align="center">CC-Remoter</h1>

<h4 align="center">在鸿蒙手机上远程操控你服务器上的 Claude Code</h4>

<div align="center">

[📦 **下载安装包**](https://github.com/2013358072/ClaudeHarmonyRemoter/releases) • [📖 **线协议文档**](docs/protocol.md) • [🔨 **构建与签名**](docs/build-and-sign.md)

</div>

---

## 它是怎么工作的？

在你的工作服务器上跑一个 Node.js 服务，它开一个端口并打印配对码。手机上的 App 扫码或手输配对码完成配对，之后就能选项目、选会话、发指令、看流式回复。

真正干活的 `claude` 进程是服务端在你发消息时拉起来的——**认证完全沿用你本机 `claude` 的配置**，所以你配的第三方中转（`ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`）原样生效，不需要官方 API key。

```
┌─────────────┐      HTTP + WebSocket       ┌──────────────────┐
│  鸿蒙 App    │ ◄─────────────────────────► │  Node.js 服务端   │
│  (ArkTS)    │    配对码换 token 后长连接     │  驱动本机 claude  │
└─────────────┘                              └──────────────────┘
                                                      │
                                              Claude Agent SDK
                                                      ▼
                                              本机 claude 二进制
```

## 🔥 为什么做这个？

- 📱 **鸿蒙生态的空缺** —— 现有的 Claude Code 移动端方案都没有鸿蒙客户端
- 🔌 **中转友好** —— 不依赖官方登录，第三方中转开箱即用
- 🔒 **权限在你手里** —— Claude 要改文件或跑命令，手机上弹确认框，可选允许 / 总是允许 / 拒绝
- 🔄 **会话续接** —— 手机上能接着电脑上的对话继续问，反之亦然
- 🔍 **全量可见** —— 文本、思考过程、工具调用（含参数摘要和执行状态）、耗时与花费，逐条展示
- 🛠️ **开源自建** —— 没有中心服务器，没有遥测，数据只在你的设备和你的服务器之间流动

## 🚀 三步跑起来

**1. 服务器上启动服务**

```bash
cd server
npm install
npm start
```

终端会打印访问地址、6 位配对码和二维码。

**2. 手机上安装 App**

从 [Releases](https://github.com/2013358072/ClaudeHarmonyRemoter/releases) 下载，或 clone 仓库后用 DevEco Studio 自己签名安装（推荐，见下文）。

**3. 配对并开始**

App 里填服务器地址和配对码。凭据存在本地，之后启动直接进项目列表。

## 📦 项目组成

| 模块 | 说明 |
|---|---|
| **[服务端](server/)** | Node.js。扫描本机 Claude 会话、驱动 `claude` 进程、把消息流归一化后推给客户端 |
| **[鸿蒙客户端](entry/)** | ArkTS / ArkUI，API 24（HarmonyOS 6.1.1）。配对、项目列表、会话列表、聊天页 |
| **[线协议](docs/protocol.md)** | 两端共享的数据结构定义，以及实现过程中踩过的坑 |
| **[图标生成](scripts/make_icons.py)** | 从源 logo 生成鸿蒙分层图标 |

## 🔐 关于安全，说实话

这个项目**没有**端到端加密。通信走的是局域网内的明文 HTTP / WebSocket，靠 Bearer token 鉴权。请不要把端口直接暴露到公网——需要外网访问请走 tailscale、frp 之类的私有通道。

权限模式默认是 `default`：Claude 要动文件或跑命令时会在手机上弹确认框。注意 Claude Code 自带安全分类器，`echo hello` 这类无害操作会直接放行，只有真正有风险的才问。

仍然建议配项目白名单，把手机能触及的范围锁死：

```json
// ~/.claude-harmony/config.json
{
  "projectRoots": ["/home/me/work"]
}
```

不配的话，你机器上所有 Claude 会话都会暴露给已配对的设备。

如果确实想要全自动放行，可以显式配 `"permissionMode": "bypassPermissions"`——但那意味着**手机指令会在服务器上无确认执行 shell 命令**，服务端启动时会就此打印警告。

配对码一次性、5 分钟有效、连错 5 次锁 60 秒；token 以 `0600` 权限存在 `~/.claude-harmony/tokens.json`，它等价于服务器的远程执行权限。

## 🙏 致谢

本项目的架构设计大量参考了 **[slopus/happy](https://github.com/slopus/happy)**（MIT）—— Claude Code 与 Codex 的移动端/Web 客户端。

## 📋 当前进度

服务端功能，已在真实会话上实测：

- [x] 配对、token 签发与持久化、跨重启有效
- [x] 项目 / 会话扫描与列表接口
- [x] 历史消息解析与归一化
- [x] WebSocket 鉴权、attach、实时对话、打断
- [x] 会话续接
- [x] **权限交互** —— 允许 / 总是允许 / 拒绝三种决定均已验证

鸿蒙端功能，已实现并编译签名通过，尚未真机验证：

- [x] 配对、项目列表、会话列表、聊天页
- [x] 权限确认弹层
- [x] 三套主题配色 + 四档字号，本地持久化
- [x] 底部导航（对话 / 我的）
- [x] **项目管理** —— 分组抽屉折叠、左滑置顶 / 重命名 / 移动分组

尚未完成：

- [ ] 扫码配对（目前手输地址和配对码，服务端已打印二维码）
- [ ] 鸿蒙端真机联调
- [ ] 推送通知

## 📚 文档

- [线协议](docs/protocol.md) —— 数据结构定义与实现踩坑记录
- [构建与签名](docs/build-and-sign.md) —— 鸿蒙签名步骤、命令行构建、服务端 systemd 部署

## 📄 License

MIT License —— 详见 [LICENSE](LICENSE)。
