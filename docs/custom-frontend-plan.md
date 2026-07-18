# Leader 自定义前端(方案 ③):用 stream-json 自绘一问一答

> 目标:把右侧"内嵌终端"升级为**自定义 SwiftUI 前端**,像 Conductor 那样渲染 coding-agent 的一问一答,并支持从自绘 UI 发消息(读写双工 + token 级流式)。
>
> 本文是**可直接照着开工的实施 spec**。所有关键机制均已在本机 `claude` 上实测(见 §1)。实现时新开 worktree、起验证实例时**改 bundle id**,不要影响正在运行的主实例(方法见 §11)。

---

## 0. 决策:为什么是 ③ 而不是 ①/②

- **①(只读 tail jsonl)**:能漂亮渲染,但**打不了字**(jsonl 是日志,不是输入通道)——半个方案。
- **②(自绘 UI 读 jsonl + 写 PTY)**:读写都有,但输入穿过终端 PTY,拿不到结构化权限/流式,交互半桥接——也是半个。
- **③(stream-json 亲自起进程,读写全自绘)**:一次到位,读(token 级)写(结构化)都归自绘 UI,是 Conductor 走的路(Claude Code SDK + Tauri)。**最贵,但唯一"完整"的方案。**

关键:③ **不作废** ①——外部起的会话仍走"只读 jsonl 渲染"(护城河不丢),jsonl 还用来**回填历史**。见 §3、§8。

---

## 1. 已实测的地基(不是猜,均在本机跑过)

**flags(`claude --help` 确认):**
- `--output-format stream-json`(仅 `--print`/`-p`):输出 NDJSON 事件流
- `--input-format stream-json`(仅 `--print`):从 stdin 读 NDJSON 用户消息 → **持久多轮**
- `--include-partial-messages`:token 级增量(M3 打字机效果用)
- `--replay-user-messages`:把你发的 user 消息回显到输出流(方便渲染"我说的话")
- `--verbose`:必须带,否则 stream-json 事件不全
- `--model <id>`、`--resume [sid]`、`--session-id <uuid>`、`--fork-session`、`--permission-mode <mode>`

**实测 1:持久多轮成立。** 一个常驻进程发两轮:同一 `session_id`、轮间 `alive=True`、第二轮正常处理。→ ③ 的核心假设成立。

**实测 2:事件序列(一次带工具调用的回合)长这样:**
```
system/hook_started        ← 我们的 leader-hook 也会以 system 事件出现在流里
system/hook_response
system/init                 model=... tools=31 session_id=...
assistant  blocks=[thinking]
assistant  blocks=[tool_use]   Bash(command, description)
rate_limit_event            ← 独立顶层事件类型,喂 HUD 用
user       blocks=[tool_result]  is_error=false content="..."
assistant  blocks=[text]    "命令执行成功…"
rate_limit_event
result     subtype=success total_cost_usd=... num_turns=2 duration_ms=...
```

**实测 3 · 三个坑(实现必须处理):**
1. **每轮都会重发 `system/init`** → 渲染要去重(按是否已初始化)。
2. **一个回合里 assistant 分多条事件到达**(thinking / tool_use / text 各一条)→ 按 `message.id` 累积成一个 Turn,不要一条事件一个气泡。
3. **`-p` 默认模型落到 `claude-fable-5`**(不是终端里的 opus)→ **必须显式 `--model`**。

---

## 2. 精确启动命令(③ 会话)

```
claude -p \
  --output-format stream-json \
  --input-format stream-json \
  --verbose \
  --replay-user-messages \
  --model <opus-id,从 Conf 或与终端一致> \
  --dangerously-skip-permissions \
  --settings <~/.claude/leader/leader-hooks.json>   # 保留呼吸灯/活动 hook
  [--session-id <新uuid>  |  --resume <既有sid>]
  [--include-partial-messages]                        # M3 起加,token 级流
```
- **cwd** = 会话工作目录。**env** = 复用 `termCleanEnv()` + 代理(见 §6);headless 不需要 TERM/COLORTERM,但无害。
- 用 `Foundation.Process` + `Pipe`(**不是 PTY**;PTY 只留给 fallback 终端)。stdout 走 `FileHandle.readabilityHandler` 行缓冲解析,stdin 写 user JSON。

发一轮用户消息(写入 stdin,NDJSON 一行):
```json
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"你的 prompt"}]}}
```

---

## 3. 架构与数据流

```
Leader 自起的会话（③ 全双工）:
  AgentSession(actor)
   ├ spawn claude -p …stream-json…（Process+Pipe,非 PTY)
   ├ stdout ─NDJSON→ StreamEvent 解码 → Conversation(@Observable) → ConversationView(SwiftUI)
   └ stdin  ←NDJSON user msg── 输入框 / interrupt

外部起的会话(路 A,只读,护城河):
  tail ~/.claude/projects/<proj>/<sid>.jsonl → 同一套 Block 渲染器

历史回填(两类会话通用):
  先读 jsonl 铺历史 Turn → 再挂 live 流续新轮
  (resume/重连也走这条:jsonl 回填 + --resume 续)
```

右栏按会话类型选渲染器:③-managed → ConversationView;外部/未接管 → 只读 jsonl 视图 或 终端 fallback。

---

## 4. 事件模型(Swift `Codable`,按实测)

```swift
// 每行一个 JSON。用 type 判别。
enum StreamEvent: Decodable {
    case system(subtype: String, sessionId: String?, model: String?)   // init / hook_started / hook_response / …
    case assistant(id: String, blocks: [Block])                        // 一回合可多条,按 id 累积
    case user(toolResults: [ToolResult])                               // tool_result 回填
    case rateLimit(RateLimitInfo)                                      // 顶层 rate_limit_event → HUD
    case result(subtype: String, costUSD: Double?, numTurns: Int?, durationMs: Int?)
    case partial(Delta)                                               // --include-partial-messages(M3)
    case unknown(type: String)
}

enum Block {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(id: String, content: String, isError: Bool)
}
```

`Conversation`(`@Observable`):
- 有序 `[Turn]`;`Turn` = 一次 user + 其后的 assistant blocks(thinking/tool_use/text)+ tool_results。
- assistant 事件按 `message.id` 合并进当前 Turn。
- partial delta(M3)追加到当前 text block → 打字机效果。
- `system/init` 去重;`rate_limit_event` 只更新 HUD 状态,不入对话流。

**注**:`JSONValue` 需要一个能装任意 JSON 的类型(tool input 形态各异)。写个简单的递归 `enum JSONValue: Codable`。

---

## 5. 新增组件(文件级)

| 文件 | 职责 |
|---|---|
| `src/AgentSession.swift` | actor:spawn/stdin/stdout 管线、send(prompt)、interrupt、terminate、resume;NDJSON 行缓冲解析 |
| `src/StreamEvent.swift` | `StreamEvent` / `Block` / `JSONValue` 的 `Codable` |
| `src/Conversation.swift` | `@Observable` 对话模型:累积 Turn、合并 assistant、partial 追加、init 去重 |
| `src/ConversationView.swift` | SwiftUI:Turn 列表(自动滚底)、各 Block 渲染器、输入框、停止键、HUD |
| `src/AgentSessionManager.swift` | 单例:sid → AgentSession 注册表(类似 `TerminalManager`);并发多会话 |
| (改)`src/LeaderApp.swift` | 右栏按会话类型选渲染器;新建会话可选走 ③;活动/分诊不变 |

---

## 6. 复用现有代码的锚点(别重造)

- `src/EmbeddedTerminal.swift`
  - `termCleanEnv()` / `proxyExport()` / `hookSettingsArg()`(→ `--settings`)/ `Conf.claudeBin` → 直接给 ③ 的进程用。
  - `EmbeddedTerminalView`、`applyTermTheme` → 保留给 fallback 终端。
- `src/scan.py` 的 `digest()`:已在解析 jsonl(cwd/最后消息等)。**历史回填**可参考它的字段;Swift 侧要么调它、要么按同样 schema 直接解析 jsonl(`type`/`message.content`/`usage`/`sessionId`/`gitBranch`)。
- `src/LeaderApp.swift`
  - 右栏当前逻辑:`activeSID` → 找会话 → 内嵌终端(约 `embeddedForActive`)。③ 在这里分叉。
  - `TerminalManager`(embed 状态)、`Activity`(呼吸灯/spinner,基于 hook,**不受影响**)。
- 活动/hook 系统:`leader-hook.py` + `leader-hooks.json`。③ 会话带 `--settings` 即照常 fire(实测 hook 会作为 `system/hook_*` 出现在流里)。

---

## 7. 分阶段里程碑(每步可独立 ship)

| M | 内容 | 交付价值 | 体量 |
|---|---|---|---|
| **M1 只读直出** | AgentSession 起进程、StreamEvent 解析、text/tool_use/tool_result 用**通用卡片**渲染(不美化) | 已能替代终端**阅读** | M |
| **M2 输入闭环** | 输入框→stdin 发 user JSON;停止键→interrupt;init 去重、按 id 累积 | **能读能写的自绘 chat** | S–M |
| **M3 富渲染** | markdown + 代码高亮;Edit/Write→diff、Bash→命令块、Read/Grep/Todo→专属卡;thinking 折叠;`--include-partial-messages` 打字机;rate_limit→HUD | Conductor 级观感 | **L** |
| **M4 接续 & 逃生舱** | jsonl 回填历史;右栏"自绘/终端"一键切;崩溃 `--resume` 重连;外部会话只读渲染 | 稳、可日用、护城河回归 | M |
| **M5(后置可选)** | slash 白名单子集、@file 补全、图片粘贴、权限按钮(若关 skip-perms)、plan 模式 | 补长尾 | L |

> **价值最陡在 M1+M2**:两步就得到"能读能写的自绘 UI"。M3 是打磨也是最重的一块。

---

## 8. 四个 scope-reducer(让 ③ 可控)

1. **保留 `--dangerously-skip-permissions`** → v1 **完全不做权限 UI**(砍掉最大的交互重造)。
2. **jsonl 回填历史**(复用现有解析)→ live 流只管当前活轮,不重放。**① 的工作变成 ③ 的历史组件,不浪费。**
3. **通用工具卡片先行** → 未知工具走 fallback 卡,per-tool 逐个补。
4. **保留终端做逃生舱** → 没做的交互一键切回终端 → ③ 可**无功能对齐焦虑地增量上线**。

---

## 9. 失去 / 保留(诚实)

- **失去(除非重造)**:TUI 的 slash 全集、plan 模式交互、vim 模式、原生 @file 补全、部分 MCP 交互提示 → **终端 fallback** 兜。
- **护城河不丢**:③ 只对"Leader 自起"的会话全双工;**外部会话走只读 jsonl 富渲染** → "接管任意来源会话"依旧成立。
- **保留**:分诊看板、呼吸灯/spinner/未读、跨文件夹 —— 全基于 jsonl/hook,不受 ③ 影响。

---

## 10. 坑 / 待实现时验证

- [ ] `system/init` 每轮重发 → 去重(§1 坑1)。
- [ ] 一回合多条 assistant → 按 `message.id` 累积(§1 坑2)。
- [ ] `--model` 必须显式传(§1 坑3)。
- [ ] **interrupt 的确切机制**:优先试 stdin 控制消息(形如 `{"type":"control_request","request":{"subtype":"interrupt"}}`),不行退 `SIGINT` 给进程。M2 敲定。
- [ ] `--include-partial-messages` 的 delta 事件形状(应是 Anthropic 原生 streaming:`content_block_delta` 里 `text_delta`/`input_json_delta`)。M3 接。
- [ ] headless 下哪些 slash 生效 → M5 列白名单;不生效的在自绘 UI 里自己实现(如 /clear=新 session)。
- [ ] 多个 ③ 会话并发 = 多个常驻进程,注意资源上限(Leader 是舰队管理器,可能同开多个)→ 加空闲回收/上限。
- [ ] NDJSON 跨读边界的半行缓冲(一个 JSON 可能被拆到两次 read)。
- [ ] 大 tool 输出截断/折叠。

---

## 11. M1 开工清单(具体)

1. 新 worktree(off 当前 Leader 分支或 main),不在主目录原地改。
2. 建 `StreamEvent.swift`(+ `JSONValue`)、`AgentSession.swift`(Process+Pipe,readabilityHandler 行解析)、`Conversation.swift`、`ConversationView.swift`、`AgentSessionManager.swift`。
3. 先做一个**独立入口**(如设置里一个开关 or 新建会话时选"自绘模式")起一个 ③ 会话,右栏挂 `ConversationView`,**只读**渲染(text/tool_use/tool_result 通用卡)。
4. 复用 `termCleanEnv()`/`proxyExport()`/`hookSettingsArg()`/`Conf.claudeBin` 拼启动参数(§2)。
5. `./build.sh` 编译(它 build 到 `dist/`,不碰 `~/Applications`)。
6. **验证用隔离实例(改 bundle id,不影响主实例)**——沿用 `docs/terminal-rendering.md §6` 的方法:
   ```
   cp -R dist/Leader.app "$SB/LeaderVerify.app"
   /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.leader.app.verify" "$SB/LeaderVerify.app/Contents/Info.plist"
   codesign --force --deep --sign - "$SB/LeaderVerify.app"
   open -n "$SB/LeaderVerify.app"          # 不同 bundle id 绕过单例锁
   ```
   验完 `kill` 精确 pid,别广撒 pkill。

---

## 12. 参考

- 本机实测:`claude -p --input-format/--output-format stream-json`(多轮持久 + 事件 schema + 三坑)
- Claude Code Agent SDK streaming(官方):https://code.claude.com/docs/en/agent-sdk/streaming-output
- stream-json 自建 UI:https://docs.bswen.com/blog/2026-03-21-stream-json-custom-ui-claude-code/
- Conductor = Claude Code SDK + Tauri + 三栏自绘 chat(参考架构):
  https://georgetaskos.medium.com/scaling-the-loop-run-5-claude-code-sessions-in-parallel-with-conductor-build-539b52888a81
- jsonl transcript 格式(路 A 复用):https://claude-dev.tools/docs/jsonl-format
