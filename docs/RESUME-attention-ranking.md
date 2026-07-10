# 恢复点 — 注意力分配路线图(P0/P1 已落地,2026-07-10 更新)

背景:把"推荐系统"思路重构成 **cμ 分诊**(后悔最小化,不是 engagement)。可靠信号
来自**实时 hook**(Activity),transcript 的 `asks` 只做同状态内 tiebreak,绝不触发
提醒(避开 `scan.py` 注释里记录的 needs-you tier 误报坑)。

**构建只写 `dist/`,别动运行中的实例。**

## 已完成(都已按功能拆 commit 提交)
- **P0** `SessionState` 统一状态模型(doneAway/waiting/working/closed,只从
  Activity + alive 派生);ContentView 观察 Activity,列表随 turn 事件实时重排。
- **P1** `byAttention` cμ 排序(状态优先 → asks → idle_h)应用到全部列表。
  (「需要你」strip 曾实现,用户明确不要,已移除——commit 0b422c8;别再加回来。)
- **错误检测** scan.py `errored`/`error_text`(最后一条对话消息是
  `isApiErrorMessage` 的 assistant 条目 = 卡死;322 个真实 transcript 验证,恢复
  262/286 靠人重发)→ 侧栏脉动黄 ⚠(压掉误导性 shimmer)+ 新卡死时 macOS 横幅
  (启动静默 seed;点横幅打开会话)。
- **perf** digest 缓存 (mtime_ns,size),warm scan 3.64s→0.45s;**fix** 四个 flag
  文件原子写(pid-unique tmp + os.replace,4 写者并发 6712 读 0 撕裂)。

## 尚未做 / 待验证
- **真机 UI 验证**:排序跳动观感、黄 ⚠/横幅的真实渲染——
  需要装进 `~/Applications` 并重启 app(会杀嵌入会话,由用户挑时机)。
- **P2(下一步,最高杠杆)**:每会话增量摘要。记 `lastViewedTS`(复用清
  attention 的 hook 点),会话进入 doneAway 时用便宜模型对 delta 生成一行
  「上次之后:做了 X,现在要 Y」,缓存 key = 最后消息 ts。scan 缓存结构可复用。
- **P3**:隐式反馈日志(点开/停留/未看就归档)→ 为 P4 学习式排序攒数据。
- 旧分支/worktree 清理、`replay` target 与 `test_switch.py` 去留:等用户确认。
