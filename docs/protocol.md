# 线协议

服务端与鸿蒙客户端之间的通信约定。

- 服务端定义：`server/src/protocol/wire.ts`
- 客户端镜像：`entry/src/main/ets/net/Protocol.ets`

**两边必须保持同步。** 改动任一侧都要同步另一侧。

---

## 设计原则：服务端负责压平

Claude Agent SDK 吐出的 `SDKMessage` 里，assistant 消息的 content 是 Anthropic 的 content block 数组（text / thinking / tool_use / tool_result 混排），联合类型嵌套很深。

ArkTS 不支持 `any`，对动态对象和联合类型窄化的检查也比 TypeScript 严格得多（实测踩到的 `arkts-no-untyped-obj-literals` 就是一例）。如果把原始结构透传给客户端，复杂度只是从服务端转移到了最不适合承担它的一侧。

所以服务端在 `protocol/normalize.ts` 里把它压平成 `WireEvent`：**一个扁平接口 + `kind` 判别字段 + 可选字段**，刻意不用可辨识联合类型。客户端只需 `if (e.kind === 'text')` 就能安全取值。

协议演进时，改动集中在服务端一个文件里。

---

## WireEvent

| 字段 | 类型 | 何时有效 |
|---|---|---|
| `kind` | `'text' \| 'thinking' \| 'tool' \| 'result' \| 'error'` | 总是 |
| `id` | string | 总是。列表 key，也是 tool 事件的合并依据 |
| `ts` | number | 总是。毫秒时间戳 |
| `role` | `'user' \| 'assistant'` | kind=text |
| `text` | string | kind=text / thinking / error |
| `toolName` | string | kind=tool |
| `toolSummary` | string | kind=tool，一行摘要如 `Read src/index.ts` |
| `toolStatus` | `'running' \| 'ok' \| 'error'` | kind=tool |
| `ok` | boolean | kind=result |
| `durationMs` | number | kind=result |
| `costUsd` | number | kind=result |

### tool 事件的合并规则

一次工具调用会产生**两条** `tool` 事件，共用同一个 `id`（取自 SDK 的 `tool_use.id`）：

1. `tool_use` → 带 `toolName` / `toolSummary`，`toolStatus='running'`
2. `tool_result` → 只带最终的 `toolStatus`

客户端按 `id` 覆盖已有条目，只更新非空字段。要的就是「先转圈、再出结果」的效果。

**例外：历史消息接口已在服务端合并好**（`claude/history.ts` 的 `mergeToolEvents`）。批量返回时服务端手上有完整列表，没理由把合并推给客户端，而且不合并会让 `limit` 的语义对不上（N 条事件 ≠ N 个可见条目）。实时流仍需客户端合并。

---

## HTTP 接口

除 `/api/ping` 和 `/api/pair` 外，都需要 `Authorization: Bearer <token>`。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/ping` | 探测服务器可达性，返回 `{ok, serverName, pairingOpen}` |
| POST | `/api/pair` | body `{code, deviceName}` → `{token, serverName}` |
| GET | `/api/projects` | `ProjectInfo[]` |
| GET | `/api/projects/:id/sessions` | `SessionInfo[]` |
| GET | `/api/sessions/:id/messages?limit=N` | `WireEvent[]`，已合并 tool 事件 |

配对失败一律返回 401，错误文案区分「配对码不正确」「已过期」「尝试次数过多」，但状态码相同 —— 不给暴力破解提供额外信号。

---

## WebSocket

地址 `/ws`。token 走 `Authorization` header（鸿蒙 `webSocket.connect` 支持自定义 header）；也兼容 `?token=` 查询参数，方便命令行调试。

握手阶段就鉴权，未授权直接返回 `401` 并断开，不进入 WebSocket 协议。

### 上行

```jsonc
{"type": "attach", "projectId": "...", "sessionId": "..."}  // sessionId 可省=新建
{"type": "send", "text": "..."}
{"type": "interrupt"}
{"type": "detach"}
```

### 下行

```jsonc
{"type": "attached", "sessionId": "..."}
{"type": "event", "payload": { /* WireEvent */ }}
{"type": "thinking", "value": true}
{"type": "fatal", "message": "..."}
```

### `attached` 的语义：可以发消息了，不是拿到 id 了

这一点很关键，是实测踩出来的坑。

**新建会话时，SDK 在收到第一条用户消息之前不会吐任何东西**，包括带 `session_id` 的 init 消息。如果服务端非要等到 id 才回 `attached`，就会死锁 —— 客户端等 `attached` 才敢发，服务端等发了才有 id。

所以：

1. `attach` 成功后**立刻**回一条 `attached`，新会话的 `sessionId` 留空字符串
2. 真实 id 到达后**再补发一条** `attached`

客户端收到 `attached` 即可发送；每次都用非空的 `sessionId` 更新本地记录（断线重连时要靠它续接同一会话）。

---

## 会话与项目的识别

### 项目路径不能从目录名反解

Claude Code 的会话存储布局是 `~/.claude/projects/<projectId>/<sessionId>.jsonl`，其中

```
projectId = resolve(cwd).replace(/[^a-zA-Z0-9-]/g, '-')
```

这是**有损且不可逆**的（`/a/b` 和 `-a-b` 会撞到一起）。真实路径只能从 jsonl 内容里读 —— 记录带 `cwd` 字段。

注意**首条记录不一定有 `cwd`**（实测会出现 `queue-operation` 这类记录打头），扫描时要往下找，不能只看第一行。

### sessionId 必须是 UUID

`claude --resume` 只接受 UUID 格式（Claude Code v2.0.65 起），`agent-*` 这类子会话必须过滤，否则续接会失败。

### CLAUDE_CODE_ENTRYPOINT 必须覆盖

Agent SDK 默认把 `CLAUDE_CODE_ENTRYPOINT` 设成 `sdk-ts`，而 Claude Code 的 `--resume` 选择器会**隐藏** `{sdk-cli, sdk-ts, sdk-py}` 的会话。

不覆盖的话，手机上建的会话在服务器终端敲 `claude --resume` 时看不见，用户会以为会话丢了。服务端统一覆盖成 `harmony-remote`（`claude/runner.ts`）。
