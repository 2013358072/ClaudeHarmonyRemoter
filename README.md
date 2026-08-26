# ClaudeHarmonyRemoter

鸿蒙端的 Claude Code 远程连接器。在工作服务器上跑一个 Node.js 服务驱动 Claude Code，用鸿蒙 App 在手机上选项目、选会话、发指令、看流式回复。

```
┌─────────────┐         WebSocket / HTTP        ┌──────────────────┐
│  鸿蒙 App    │ ◄─────────────────────────────► │  Node.js 服务端   │
│  (ArkTS)    │      配对码换 token 后长连接       │  驱动本机 claude  │
└─────────────┘                                  └──────────────────┘
                                                          │
                                                   Claude Agent SDK
                                                          ▼
                                                   本机 claude 二进制
                                                   （走你自己的中转）
```

## 为什么不用官方 API

因为根本不需要。`@anthropic-ai/claude-agent-sdk` 容易被名字误导 —— 它**不是** Anthropic API 客户端，而是「Claude Code 打包成了一个库」，底层拉起你本机那个 `claude` 二进制。

也就是说 `claude` 怎么认证，它就怎么认证。你配的 `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` 第三方中转**原样生效**，不需要为了绕开官方端点去搞「监控 jsonl + 注入 stdin」那套脆弱方案。

这一点已实测验证（`server/scripts/sdk-probe.mjs`）。

## 目录

| 路径 | 说明 |
|---|---|
| `server/` | Node.js 服务端 |
| `entry/` | 鸿蒙 App（ArkTS，API 24 / HarmonyOS 6.1.1） |
| `docs/protocol.md` | 线协议文档，含实现踩过的坑 |

## 跑起来

### 服务端

```bash
cd server
npm install
npm start
```

终端会打印访问地址、6 位配对码和二维码。

配置文件 `~/.claude-harmony/config.json`（全部可选）：

```json
{
  "port": 4517,
  "serverName": "我的开发机",
  "projectRoots": ["/home/me/work"],
  "permissionMode": "bypassPermissions",
  "claudeExecutablePath": ""
}
```

也支持环境变量：`CLAUDE_HARMONY_PORT` / `CLAUDE_HARMONY_HOST` / `CLAUDE_HARMONY_NAME` / `CLAUDE_HARMONY_PROJECT_ROOTS`（冒号分隔）/ `CLAUDE_HARMONY_PERMISSION_MODE` / `CLAUDE_HARMONY_CLAUDE_PATH`。

### 鸿蒙 App

用 DevEco Studio 打开项目根目录直接运行。命令行构建：

```bash
hvigorw assembleHap --mode module -p product=default
```

App 里填服务器地址和配对码即可。凭据存在本地，之后启动直接进项目列表。

## ⚠ 安全须知

首版 `permissionMode` 默认是 `bypassPermissions`，因为客户端还没做权限交互界面 —— 若用默认模式，Claude 一旦要改文件或跑命令就会卡住等批准，手机端永远收不到回复。

**代价是：手机发出的指令会在服务器上无确认地执行文件修改和 shell 命令。**

所以务必配置 `projectRoots` 白名单，把可访问范围限制在指定目录内。不配的话，Claude 的全部本地会话都会暴露给已配对的设备。服务端启动时会就此打印警告。

配对码是一次性的、5 分钟有效，连错 5 次锁 60 秒。token 以 0600 权限存在 `~/.claude-harmony/tokens.json`，它等价于服务器的远程执行权限。

**不要把端口直接暴露到公网。** 需要外网访问请走 tailscale / frp 之类的私有通道。

## 验证

服务端可独立验证，不需要鸿蒙设备：

```bash
# 接口
curl localhost:4517/api/ping
curl -X POST localhost:4517/api/pair -H 'Content-Type: application/json' -d '{"code":"<配对码>"}'
curl localhost:4517/api/projects -H "Authorization: Bearer <token>"

# 完整对话流（鉴权 → attach → 发送 → 流式回复）
node scripts/ws-smoke.mjs <token> <projectId> [sessionId]

# 探测 Agent SDK 与中转是否正常
node scripts/sdk-probe.mjs
```

会话续接的验证方法：发一条消息拿到 sessionId，断开，用同一 sessionId 重新 attach 后追问上文内容。同时在服务器上跑 `claude --resume`，确认该会话**出现在选择器里**（验证 `CLAUDE_CODE_ENTRYPOINT` 覆盖生效）。

## 当前进度

已完成并实测通过：

- 配对、token 签发与持久化、跨重启有效
- 项目 / 会话扫描与列表接口
- 历史消息解析与归一化
- WebSocket 鉴权、attach、实时对话、打断
- 会话续接
- 鸿蒙端全部页面，可编译出 HAP

尚未做：

- 权限交互（手机弹窗批准工具调用）—— 协议已预留位置
- 扫码配对（目前手输地址和配对码）
- 鸿蒙端真机联调
