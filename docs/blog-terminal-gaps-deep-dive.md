# 终端里的怪空格——从三个小抱怨到 GPU 字形定位的一次深潜

> 2026-07-11 · Leader embedded-app
>
> 这是一篇复盘。起点是三句很随意的抱怨:"打拼音看不见"、"光标太粗"、"打字有点卡"。
> 终点是一个 GPU 渲染器里的字形定位 bug:中文段落被悄悄压窄了 17%,欠下的宽度在
> 样式边界处一次性吐出来,变成一段段莫名其妙的空白。中间经过输入法协议、光标样式、
> 三层渲染开销、两条渲染路径的分叉,和一次"医生给自己动手术"的上线。

---

## 一、三个抱怨

Leader 是一个管理多个 Claude Code 会话的 macOS 原生驾驶舱,右侧嵌着一个真正的终端,
里面跑着 `claude --resume`。某天使用者(也就是我自己)提了三个体验问题:

1. **打拼音的时候,拼音不显示。** 候选词窗口是有的,选字也能上屏,但组合中的拼音
   序列在终端里完全看不见——只能在脑子里默记"我刚才敲了 zhongwen 还是 zhongwne"。
2. **光标是那种很粗的块状光标**,想要 kakoune / WezTerm 那种细竖线。
3. **打字不太顺畅,有点卡卡的**,说不上哪里卡,就是不如 kitty 里跟手。

三个问题看起来都是"小毛病",但它们各自通向终端栈的不同层。逐个拆开,恰好是一次
从上到下的完整旅行:输入法协议层 → 光标绘制层 → 渲染管线层。

先交代舞台:Leader 的嵌入终端用的是 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
——一个纯 Swift 的终端模拟器库。准确地说,是我们自己的 fork,因为需要一个上游
没有的功能:`lineHeightMultiplier`,1.2 倍行距,让密密麻麻的终端文字能喘口气。
这个 fork 后面会成为故事的关键伏笔。

---

## 二、消失的拼音:一个从来没人实现的协议

### 输入法是怎么工作的

在 macOS 上,中文输入法和应用之间走一个叫 `NSTextInputClient` 的协议。直觉版本是
这样的:当你打拼音时,按键**并不直接进入应用**,而是先被输入法截走;输入法把"组合中
的临时文本"(术语叫 **marked text**,也叫 **preedit**,预编辑串)交还给应用,说
"请你先把这段画出来,带下划线,表示还没确定";等你按空格选字,输入法才调用
`insertText` 把真正的中文提交进来。

也就是说,**预编辑拼音的显示责任在应用这边**。候选词窗口是系统画的,所以一直都在;
拼音串要应用自己画,所以——

### SwiftTerm 的实现是个空壳

```swift
// SwiftTerm MacTerminalView.swift(修复前)
open func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    kittyIsComposing = true          // 只设了个标志位,string 直接丢弃
}
open func hasMarkedText() -> Bool {
    return false                     // 永远说"我没有 marked text"
}
```

拼音串被原样丢进了黑洞。这不是 bug,是**从来没实现过**——上游代码里还留着
`// TODO` 和 `print("This should return the actual range")` 这样的注释。对英文用户
来说这个协议几乎不会被触发,所以它荒了很多年。

### 修复:一个贴着光标的 overlay

好消息是,提交路径(`insertText`)是通的,组合期间也确实没有任何字节被误发进
PTY(伪终端,应用和 shell 之间的管道)。所以这纯粹是个**展示层**问题,修复也可以
纯展示层:在 app 侧的 `EmbeddedTerminalView` 子类里接管这套协议,把 marked text
存下来,用一个 `NSTextField` overlay 画在光标位置上——终端同款字体、下划线标示
预编辑态、输入法正在转换的子句加粗下划线。选字提交、ESC 取消、切换会话时清除。

一个细节:overlay 的定位不需要访问 SwiftTerm 内部的光标视图(它是 `internal` 的),
因为协议里本来就有 `firstRect(forCharacterRange:)`——输入法用它决定候选窗的位置,
返回的正是光标的屏幕坐标。把它换算回视图坐标,overlay 就钉在了光标上。

---

## 三、粗光标:一行修复,但顺便学了个协议

这是三个问题里最简单的。SwiftTerm 其实一直支持六种光标样式:

```
blinkBlock  steadyBlock  blinkUnderline  steadyUnderline  blinkBar  steadyBar
```

`steadyBar` 就是 WezTerm 那种 2px 细竖线。默认值是 `blinkBlock`(粗块+闪烁),
而 Leader 从来没设置过。修复的核心真的只有一行:

```swift
tv.getTerminal().setCursorStyle(.steadyBar)
```

顺便学到的:终端里的程序(vim、htop)可以通过一个叫 **DECSCUSR** 的转义序列
(`ESC [ n q`)临时改光标形状,这是几十年前 DEC 终端传下来的标准。所以"默认细竖线"
不妨碍 vim 在 normal mode 里把它变回块状——这套协议 SwiftTerm 也是支持的,我们的
默认值只是它的兜底。配置键 `term_cursor_style` 进了设置面板,六种样式随便选。

---

## 四、卡顿:三层开销叠在主线程上

"打字卡"是最模糊的抱怨,但拆开后发现是**三层开销的叠加**,每一层单独看都有正当理由:

**第一层:claude 被我们强制全屏重绘。** Claude Code 的 TUI 在 alt-screen(备用屏,
全屏应用用的那块无滚动缓冲区)里跑差量渲染:每帧只重画变了的部分,靠"光标回退 N 个
逻辑行"来定位。问题是它按自己的换行假设回退,而 SwiftTerm 的换行不感知 grapheme
(中文、ZWJ emoji 的宽度处理和 kitty 不同),物理行数对不上,一滚动就花屏。当时的
解法是设 `CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT=1`,强制 claude **每帧把整个屏幕
重写一遍**。花屏没了,代价是每敲一个键,PTY 里都涌过来一整屏的 ANSI 数据。

**第二层:app 侧也在全量重绘。** SwiftTerm 的局部重绘在 alt-screen 下会留残影,
所以 `EmbeddedTerminalView` 里把所有失效都提升成了全窗口重绘。又是一个"为了正确性
牺牲性能"的正当决定。

**第三层:默认渲染器是 CPU 的。** SwiftTerm 的 Mac 默认路径用 CoreGraphics/CoreText
画字:每帧、每一行,构建 `NSAttributedString`、创建 `CTLine`、在主线程光栅化。
全屏重绘 × CPU 光栅化 × 主线程 = 键盘事件排在绘制后面等着,这就是"卡卡的"的手感。
kitty 和 WezTerm 流畅,不是玄学,是因为它们都在 GPU 上渲染。

### 解法:fork 里睡着一个 Metal 渲染器

翻 fork 源码时发现,SwiftTerm 已经带了一个实验性的 **Metal 渲染器**——CoreText 先把
每个字形(glyph,字体里一个字符的图形)光栅化进一张 **glyph atlas**(字形图集,一张
大纹理,每个字形占一小块),然后每帧只是往 GPU 提交一批带纹理坐标的四边形。更妙的是
它有个 `perFrameAggregated` 缓冲模式,文档原话就是给"每帧重绘大部分屏幕"的负载
设计的——正好是我们被迫选择的工作模式。

开启它之前有一个已知的坑要填:我们 fork 的 `lineHeightMultiplier` 补丁只改了 CG
路径——行高拉到 1.2 倍后,多出来的空间要在字形上下均分,这个居中逻辑写在
`drawTerminalContents` 里,**Metal 路径没有对应的修改**。不补的话,开了 GPU 文字
会沉在格子底部。于是给 Metal 路径的 `yOffset` 也补上了同样的居中算术。

记住这个模式:**同一个逻辑,存在两条渲染路径,补丁必须双打。** 这次是行高,我们
记得补;马上会看到一个上游自己没双打的地方。

---

## 五、上线,然后怪空格出现了

三项修复构建、安装、重启。拼音出来了,光标细了,打字确实顺了。

然后截图来了:**GPU 模式下,中文段落里到处是莫名其妙的空白**。

```
和最后活跃    sid (之前没存,     AppDelegate  也拿不到   ContentView  的  @State) ,并暴露
崩溃后重启不会批量拉起(这点和          macOS  崩溃后恢复窗口不同,是防        spawn  循环的取舍)。
```

仔细看这些空隙,有三个规律,每一个都是线索:

1. **只出现在中文文本里**,纯英文行完全正常;
2. **总是出现在样式边界之前**——彩色的行内代码、加粗文本这些 token 的前面;
3. **中文段落越长,它前面欠的空隙越宽**。

第三条是决定性的。它说明这不是"多画了几个空格",而是**宽度亏空在累积**——某个东西
把中文画窄了,窄掉的宽度在下一个"重新对齐"的地方一次性显形。

## 六、破案:格子世界和排版世界的汇率

### 终端是格子,字体是流

先建立直觉。终端的世界观是一张**等宽网格**:屏幕分成 N 列 × M 行的格子(cell),
每个字符占 1 格,中日韩全角字符占 2 格。这不是渲染偏好,是**语义**——终端里跑的
程序(vim 的光标移动、claude 的换行计算)全都建立在"第 n 列就在 x = n × 格宽"
这个承诺上。

而字体的世界观是**排版流**:每个字形有自己的 **advance**(步进,画完这个字形后
画笔往右挪多少)。CoreText 做 **shaping**(把字符序列变成带位置的字形序列)时,
给出的 x 坐标是 advance 的累加——那是给 Word 文档用的坐标,不是给终端用的。

两个世界在英文里**碰巧**汇率是 1:1:JetBrains Mono 是等宽字体,13pt 下每个 ASCII
字形的 advance 恰好等于格宽 ≈ 7.8pt。但中文呢?**JetBrains Mono 根本没有汉字**。
系统触发 **font fallback**(字体回退),汉字实际由苹方(PingFang SC)渲染。苹方的
汉字 advance 是 13pt(正好一个 em),而终端里一个汉字该占两格 = 2 × 7.8 = **15.6pt**。

每个汉字欠 2.6pt,约合三分之一格。"和最后活跃"五个字,欠 13pt ≈ 1.7 格;十四个字的
长句,欠 36pt ≈ 4.7 格。**跟截图里的空隙宽度完全对得上。**

### 两条路径,两种回答

那为什么 CG 路径没这个问题?对质源码,两条路径对"字形放哪儿"给出了不同的回答。

**CG 路径**(正确)——完全无视排版 x,每个字形锚死在自己的格子上:

```swift
// AppleTerminalView.swift drawTerminalContents
for i in 0..<runGlyphsCount {
    let glyphColumn = startColumn + (i * segment.columnWidth)
    positions[i] = CGPoint(
        x: lineOrigin.x + CGFloat(glyphColumn) * cellDimension.width,  // ← 格子说了算
        y: lineOrigin.y + yOffset + ctPosition.y)
}
```

**Metal 路径**(有病)——只把每个属性 run(同色同款式的连续文本段)的**起点**锚在
格子上,run 内部用 CoreText 的排版步进累加:

```swift
// MetalTerminalRenderer.swift(修复前)
let baseX = lineOrigin.x + (cellWidth * CGFloat(startColumn))  // run 起点:格子说了算
let xOffset = baseX - run.shaperRun.firstX
...
let basePos = CGPoint(x: ctPos.x + xOffset, ...)               // run 内部:字体说了算
```

于是每段连续中文在 run 内部按苹方的 13pt 步进排布,被压窄 17%;直到下一个属性
run(颜色一变,比如行内代码的紫色)——它的起点又老老实实锚回自己的格子列。压窄
省下的宽度,全部在这里显形成空白。

这也严丝合缝地解释了三条规律:英文 advance == 格宽所以无感;空隙出现在样式边界
因为那里是下一个 run 的"重新锚定点";段落越长欠得越多。甚至解释了一个更隐蔽的
细节:压窄后的中文其实**字距也变紧了**,只是人眼对"紧一点"远不如对"突然空一块"
敏感。

### 修复:格子是唯一真理

修法就是让 Metal 路径承认和 CG 路径同一个真理——**x 坐标由 buffer 列号决定,
排版坐标只借用 y**:

```swift
// MetalTerminalRenderer.swift(修复后)
var glyphIndexInRun = 0
for glyphRun in run.shaperRun.glyphRuns {
    for i in 0..<glyphRun.glyphs.count {
        let glyphColumn = startColumn + (glyphIndexInRun * segment.columnWidth)
        glyphIndexInRun += 1     // 注意:被跳过的字形也要占格,否则后面全错位
        guard let entry = glyphEntry(...) else { continue }
        ...
        let basePos = CGPoint(x: lineOrigin.x + CGFloat(glyphColumn) * cellWidth,
                              y: lineOrigin.y + yOffset + ctPos.y)
    }
}
```

两个容易漏的地方:

- **计数要在 guard 之前**。atlas 里没有条目的字形会被 `continue` 跳过,但它在
  终端里仍然占着自己的格子——跳过绘制不等于跳过占位,否则一个画不出来的字形会让
  后面整行左移。
- **下划线和删除线是同一个病灶的两个分店**。它们也在用 `ctPos.x + xOffset` 定位,
  同样改成逐列锚定。

## 七、教训

**1. 双渲染路径意味着每个补丁都要付两份。** 行高居中我们记得给 Metal 补,因为是
自己刚写的;字形定位上游自己就没双打,CG 修对了,Metal 还是老逻辑。只要仓库里
存在"同一语义、两套实现",漂移就是时间问题。要么抽公共层,要么在 review 清单里
写死"改 A 必查 B"。

**2. 等宽是 ASCII 的神话,不是字体的承诺。** 任何"终端 + CJK"的组合里,回退字体的
advance 几乎不可能恰好等于两倍格宽。凡是从 CoreText/HarfBuzz 拿排版坐标直接用的
终端渲染代码,都值得怀疑。

**3. 显示 bug 的空间分布本身就是证据。** 这次没有加一行日志:"空隙只在中文里、
只在样式边界前、随段落长度线性增长"三个观察,足以把假设收敛到"advance ≠ 格宽 +
run 起点重锚定"这一种可能,剩下的只是打开源码核对。定位渲染问题时,先问"错误出现
在**哪里**的规律是什么",往往比先上 debugger 快。

**4. 修根因,不修汇率。** 中途闪过一个念头:能不能给 CJK 字形设个横向缩放,把
13pt 拉伸到 15.6pt?能消空隙,但字会变形,而且没解决"排版坐标混进格子世界"的
本质——下一个非整数倍的字体照样出事。正确的修复让排版系统只回答"这个字长什么样",
不让它回答"这个字在哪儿"。

## 尾声:医生在病人肚子里做手术

最后是这次修复里最有戏剧性的细节:整个定位、修复、构建、安装的过程,是由一个
**跑在 Leader 嵌入终端里的 Claude 会话**完成的——也就是说,医生自己就住在病人
肚子里,屏幕上那些怪空格,正是它自己的输出被渲染出的样子。

它可以替换磁盘上的 `Leader.app`(运行中的进程按 inode 持有旧二进制,不受影响),
但不能替用户重启 app——那会把自己杀掉。恰好前一天刚给 Leader 加了"退出时勾选、
下次启动批量恢复会话"的功能,于是收尾变成了一句话:"你 Cmd+Q,勾上恢复,再打开。"
app 重启,新渲染器上线,怪空格消失,而做手术的那个会话被 `--resume` 原样拉起,
继续写完了这篇复盘。

---

*相关代码:fork 补丁 `Coiggahou2002/SwiftTerm@leader-line-height`(行高居中
`92621cc`、字形锚列 `519d112`);app 侧 IME overlay / 光标样式 / Metal 开关见
`src/EmbeddedTerminal.swift`,渲染架构说明见仓库 `CLAUDE.md`。*
