# Design Journal:嵌入式终端"残影/乱码"排查全记录

> 一次极其曲折的排查。记录下来不是为了流水账,而是因为**中途好几个看似板上钉钉的判断后来都被推翻了**——这些"被推翻的过程"本身就是方法论。如果将来再遇到终端渲染类问题,先读这篇,能少走至少 5 个弯路。

相关文档:`terminal-rendering-explained.md`(终端渲染分层科普)、`embedded-terminal-plan.md`(嵌入设计)。

---

## 1. 背景与症状

Leader 把 claude 会话用 **SwiftTerm** 嵌进 app 主区(而不是开 kitty 窗口)。出现两类问题:

- **A. 全屏 TUI 残影**:claude `/tui fullscreen` 下滚动,屏幕"只更新边缘",旧帧残留、不同帧内容叠在一起(`code3.position`、`公gentic` 这种字符交错)。
- **B. resize 乱**:拖窗口大小时换行错乱。
- **C(后期发现). 中文行内大空格**:整段中文里出现莫名其妙的大段空格。

用户的硬指标:**至少一个模式(default 或 fullscreen)要做到 ① 滚动流畅无错位 ② resize 时内容正确重排。**

---

## 2. 曲折的排查路径(含所有被推翻的判断)

下面按时间顺序,**每一步都标注当时的判断和后来是否被推翻**。

### 弯路 1:"是渲染层 dirty-rect 残留" ❌ 推翻

**当时判断**:SwiftTerm 默认 CoreGraphics renderer 走"只重画脏行",脏区算错就残留旧像素。经典的 stale-cell 问题。
**做的事**:① 强制 `setNeedsDisplay` 提升整屏重绘;② `setFrameSize` resize 后 0.8s 全量重绘;③ 切到 SwiftTerm 自带的 **Metal renderer**(GPU atlas + 全量重建)。
**结果**:**全都没用**,残影照旧。
**教训**:在没有"权威证据(buffer dump)"之前,不要假设问题在渲染层。

### 弯路 2:"Metal 没真正生效" → 真的没生效(但不是主因)

**现象**:切了 Metal 还是乱。怀疑 Metal 没真跑。
**查证**:写状态文件 → 确认 `setUseMetal` **静默抛错降级**了。根因是 **`build.sh` 只拷了二进制,没把 SwiftPM 的 `SwiftTerm_SwiftTerm.bundle`(含 `Shaders.metal`)拷进 .app**,运行时 `Bundle.module` 找不到 shader 源 → `makeLibrary` 失败。
**修复**:`build.sh` 拷 `*.bundle` 进 `Contents/Resources/`。Metal 真生效了(状态文件 `usingMetal=true`)。
**结果**:Metal 真跑起来后,**残影依旧**。所以 Metal 不是解药。
**教训**:① 自组 .app bundle 时,SwiftPM 资源 bundle 必须一起拷;② "改动没生效"要用确凿手段(写文件)验证,别靠肉眼/日志(GUI app 经 `open` 启动,`NSLog` 不一定进 unified log)。

### 弯路 3:进程管理的连环坑(浪费最多时间)

排查中反复出现"改了没区别"的诡异现象,根因是**我自己的进程/环境管理错误**,不是代码:

- **`pkill` 模式不匹配**:`open` 启的进程命令行是**相对路径** `dist/Leader.app/...`,而我一直 `pkill -f "leader.wt/embedded-app/dist"`(全路径)→ **杀进程一直是空操作**,旧实例从没死过,`open` 又把旧实例**重新激活**(macOS 对已运行 app 是 activate 而非新启)。
- **环境变量泄漏**:早期用 `LEADER_TESTCMD='vim ...' open` 测试,这个 env **泄漏进了那个长命进程**,导致之后"点会话打开的是空白 vim"。
- **误杀生产**:一次为了清 dev 实例,`pkill -9 -f "Leader.app/Contents/MacOS/Leader"` 把**生产的 `~/Applications/Leader.app` 也杀了**(违反了"不动生产"的约束)。

**教训**:
- 同名多实例(生产 + dev 都叫 "Leader")是噩梦。给 dev build 加**可见构建标识**(`BUILD_TAG`)+ 渲染器徽标,一眼分清在测哪个。
- 杀进程用**能匹配实际命令行**的模式,并**杀完 `pgrep` 复核**确认死透。
- 调试钩子(`LEADER_TESTCMD`)很危险,会泄漏;用完即删。

### 弯路 4:"是 SwiftTerm 的 emulation bug,换核就行" ❌ 推翻(关键转折)

走投无路后,做了**正确的事:抓 PTY 字节流 + headless 回放**。
- 在 `dataReceived` 里把 SwiftTerm 收到的每个字节 tee 到文件;
- 写了个 headless `replay` 工具(`replay/main.swift`):喂字节进一个无 GUI 的 SwiftTerm `Terminal`,把 cell buffer dump 成文本。

**结果**:回放出来的 buffer **本身就是乱的** → 确认不是渲染层,是状态层。**当时判断:SwiftTerm emulation 有 bug,换 alacritty_terminal / libghostty 就行。**

**推翻**:把同一段字节喂进 **pyte(公认正确的 Python 参照 emulator)→ 一样乱,乱法几乎一致**。两个独立正确的 emulator 都乱 → **不是 SwiftTerm 的 bug,换任何核都没用**。

**教训**:**永远拿一个独立的参照实现交叉验证**。差点就去做"换 Rust 核 + 自写 Metal renderer"那个数天的大工程了,纯属南辕北辙。

### 弯路 5:逐一排除(把假设全打死)

确认"字节流在正确尺寸下用标准终端都会乱"后,逐一证伪:

| 假设 | 验证方法 | 结果 |
|---|---|---|
| 同步输出 DEC 2026 | 剥掉所有 BSU/ESU 重放 | ❌ 一样乱 |
| 响应依赖(claude 查光标位置) | 数 `ESC[6n` | ❌ = 0,claude 不查 |
| 尺寸不匹配 | 量分隔线宽度(=87)、CUP 最大行(=74) | ❌ 尺寸完全对 |
| TERM/终端身份 | 改 `TERM=xterm-kitty` 重测 | ❌ claude 渲染变了但还是乱 |
| Unicode 宽度 wcwidth | pyte 里换各种宽度策略重放 | ❌ 都不变 |

每一条都有据排除。这一步看着笨,但**把假设空间收敛干净**才敢下最后的结论。

### 决定性实验:对照 kitty

唯一矛盾:**用户说 claude 在 kitty 里完全正常。** 于是做最后的对照:
- 在 **kitty 里**用 `script` 抓同样的 claude 全屏滚动字节流;
- 回放进 pyte。

**结果:kitty 抓的字节回放 → 完全干净(0 脏行);我们 SwiftTerm 抓的 → 满屏乱。**

> **这是整场调查的转折点:同一个 claude,给 kitty 发干净字节、给我们发会乱的字节。** 所以问题**可修** —— claude 根据终端的某些特征切换了渲染策略。

---

## 3. 两个真正的根因 + 修复

### 根因 A:claude 差分渲染 vs 非 grapheme-aware 换行(= 全屏滚动残影)

调研(查 Ink #907、claude-code #37389/#51828/#40555/#49086)+ 上述证据,定位:

> claude 全屏 TUI 用**光标相对的差分渲染器**:重画时用 `cursorUp` + `eraseLine` 回退,**回退的行数是按逻辑行(`\n`)算的,不是按换行后的物理行**。CJK / ZWJ-emoji / 正好等于终端宽度的行,在非 grapheme-aware 的 SwiftTerm(和 pyte)里换行成的**物理行数,和 grapheme-aware 的 kitty/Ghostty 不一样** → 回退行数算错 → 滚动时漂移、越积越乱。

**修复(官方隐藏开关)**:给嵌入的 claude 进程导出 **`CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT=1`** —— claude 改成**全屏全量重画**,不走差分回退,整类漂移消失。
注意:它会被我们的 `CLAUDE_CODE*` 环境剥离逻辑误删,所以必须在**启动 shell 命令里显式 `export`**。
→ 提交 `ceacba5`。**全屏滚动残影解决。**

### 根因 B:Metal renderer 的 CJK 字形定位 bug(= 中文行内大空格)

发现全屏修好后,出现新现象 C(中文大空格)。再次抓字节回放 + 用 `translateToString(skipNullCellsFollowingWide:true)` dump:

> **emulation buffer 紧凑正确**(和 pyte 一致),但**实时渲染**把中文字间拉开了大空格 → 纯**渲染层**问题,出在我加的 **Metal renderer**(社区 #479)的 CJK 字形定位。SwiftTerm 成熟的 **CoreGraphics** renderer 渲染 CJK 是对的。

**修复**:**弃用 Metal**(它本来就没解决任何问题——残影是 env 开关修的、与渲染器无关,反而引入了 CJK bug),回到 CoreGraphics 默认路径。
→ 提交 `ceb858a`。**中文大空格解决。**

### 附带修复

- **alt-screen 滚轮失灵**:alt-screen 无 scrollback,滚轮原来走 `scrollUp/scrollDown`(空操作)。改成 alt-screen 里把滚轮**翻译成方向键**发给程序(kitty/wezterm 的做法,DECCKM 感知)。→ 提交 `a4de1b9`。

### 没修(全行业限制,记录在案)

- **default 模式 resize 不重排历史**:claude 在 default 模式**自己硬折行(吐 `\n`)**写进 scrollback,终端拿到的是独立硬换行,**无法重排** —— **kitty 也一样**。这不是 bug,是 claude 端的渲染选择(见 claude-code#43113 在推动改成软换行)。所以"resize 正确重排"这条只有 **fullscreen 模式能满足**(claude 收 SIGWINCH 会全量重画)。

---

## 4. 关键工具与方法论

1. **抓字节流 + headless 回放**(`replay` target)是这次的破案核心。任何"终端显示不对"的问题,先把**输入字节**和**输出 buffer**分离出来看,立刻能区分"渲染层 / 状态层 / 输入(字节)层"。该工具已保留在仓库。
2. **拿独立参照实现交叉验证**(pyte)。差一点就为一个"不是 SwiftTerm 的问题"去换 SwiftTerm。
3. **对照"已知正确"的环境**(kitty 抓取)。这是确认"可修 vs 不可修"的唯一决定性实验。
4. **确凿验证改动生效**:写状态文件 > 看日志;可见构建标识区分多实例。
5. **逐一证伪、收敛假设空间**,再下最终结论。

## 5. 分层定位结论(便于复用)

```
现象              定位层              根因                                  修复
全屏滚动残影      claude(字节层)     差分渲染按逻辑行回退 × 非graphemeawrap   env: ALT_SCREEN_FULL_REPAINT=1
中文行内空格      渲染层(Metal)      Metal CJK 字形定位 bug                  弃用 Metal,用 CoreGraphics
滚轮滚不动        输入层             alt-screen 无 scrollback 空操作          滚轮→方向键
default resize    claude(字节层)     硬换行不可重排(全行业)                 不可修,用 fullscreen
```

---

## 6. 最终形态

- 渲染:SwiftTerm **CoreGraphics**(默认,CJK 正确)。
- 全屏 TUI:`CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT=1` 强制全量重画,滚动/resize 干净。
- 全屏滚轮:翻译成方向键。
- 逃生口:terminal header 的 "kitty 窗口" 按钮(保留,以防万一)。
- 诊断工具:`replay/` headless 回放,保留备用。

**相关提交**:`a9069e4`(bundle 修复)、`ceacba5`(full-repaint,根因A)、`a4de1b9`(滚轮)、`ceb858a`(弃 Metal,根因B/C)、`332b73a`(清理脚手架)。
