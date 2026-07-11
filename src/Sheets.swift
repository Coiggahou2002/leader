// Sheets.swift — modal panels: rename, keyboard-shortcut help, settings.
// Split out of LeaderApp.swift; pure move, no logic changes.
import SwiftUI
import AppKit
import UserNotifications

// MARK: - 重命名面板(sheet:macOS 上比 alert+TextField 可靠得多)
struct RenameSheet: View {
    let session: Session
    @Binding var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名会话").font(.headline)
            Text("原标题:\(session.title ?? session.last_prompt ?? "(无)")")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            TextField("昵称(留空恢复原标题)", text: $text)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { onSave(text) }
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") { onSave(text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 320)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

// MARK: - 快捷键帮助面板
struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("快捷键").font(.headline).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("全局(任意位置,含终端内)", [
                        (["⌘", "K"], "命令面板 — 搜索会话、执行会话操作(⌘F 同义)"),
                        (["⌘", "1"], "切到「活跃」标签"),
                        (["⌘", "2"], "切到「会话」标签"),
                        (["⌘", "3"], "切到「陈旧」标签"),
                        (["⌘", "4"], "切到「已归档」标签"),
                        (["⌘", "⇧", "O"], "快速打开 — 输入目录,回车新建会话"),
                        (["⌃", "⌃"], "呼出 / 收起临时终端(双击 Control)"),
                        (["⌘", "W"], "关闭当前嵌入会话(需确认;不关窗口)"),
                        (["⌘", "Q"], "退出 Leader(有会话在运行时会确认)"),
                    ])
                    section("侧边栏列表", [
                        (["↑"], "上移选中"),
                        (["↓"], "下移选中"),
                        (["↩"], "打开选中的会话"),
                    ])
                    section("命令面板(⌘K 打开后)", [
                        (["↑", "↓"], "移动选中"),
                        (["⇥"], "进入该会话的操作列表"),
                        (["↩"], "打开会话 / 执行操作"),
                        (["⎋"], "返回上一层 / 关闭"),
                    ])
                    section("快速打开(⌘⇧O 打开后)", [
                        (["↑", "↓"], "在候选目录间移动"),
                        (["⇥"], "补全到选中的目录"),
                        (["↩"], "打开输入目录(或选中候选)新建会话"),
                        (["⎋"], "关闭"),
                    ])
                    section("临时终端呼出时", [
                        (["⌘", "K"], "交给终端清屏,不再拉起命令面板"),
                        (["⌘", "1–4"], "切换标签 — 暂时禁用"),
                        (["⌘", "⇧", "O"], "快速打开 — 暂时禁用"),
                    ])
                    Text("提示:每行右侧的 ••• 菜单(或右键)可对单个会话执行 置顶 / 标记未读 / 重命名 / 归档。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: 440)
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 14)
        }
        .padding(18).frame(width: 470)
    }

    @ViewBuilder private func section(_ title: String,
                                      _ rows: [(keys: [String], desc: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).bold().foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(spacing: 4) {
                        ForEach(Array(r.keys.enumerated()), id: \.offset) { _, k in keyCap(k) }
                    }
                    .frame(width: 92, alignment: .leading)
                    Text(r.desc).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
    private func keyCap(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
    }
}

// MARK: - 设置面板(代理)
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var addr: String
    @State private var font: String
    @State private var fontSize: CGFloat
    @State private var lineHeight: CGFloat
    @State private var softColors: Bool
    @State private var cursorStyle: String
    @State private var notify: Bool
    // Display name -> SwiftTerm CursorStyle raw name (what CursorStyle.from parses).
    private static let cursorStyles: [(label: String, value: String)] = [
        ("竖线", "steadyBar"), ("竖线·闪烁", "blinkBar"),
        ("块状", "steadyBlock"), ("块状·闪烁", "blinkBlock"),
        ("下划线", "steadyUnderline"), ("下划线·闪烁", "blinkUnderline"),
    ]
    init() {
        let p = Conf.proxy
        _enabled = State(initialValue: !p.isEmpty)
        _addr = State(initialValue: p.isEmpty ? Conf.detectedEnvProxy() : p)
        _font = State(initialValue: Conf.termFont)
        _fontSize = State(initialValue: Conf.termFontSize)
        _lineHeight = State(initialValue: Conf.lineHeight)
        _softColors = State(initialValue: Conf.softColors)
        _cursorStyle = State(initialValue: Conf.termCursorStyle)
        _notify = State(initialValue: Conf.notify)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置").font(.headline)

            // MARK: terminal appearance
            VStack(alignment: .leading, spacing: 8) {
                Text("终端外观").font(.subheadline).bold()
                HStack {
                    Text("字体").frame(width: 44, alignment: .leading)
                    Picker("", selection: $font) {
                        // Keep a stale/custom value selectable so it isn't silently lost.
                        if !Conf.monoFontChoices.contains(font) { Text(font).tag(font) }
                        ForEach(Conf.monoFontChoices, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                HStack {
                    Text("字号").frame(width: 44, alignment: .leading)
                    Stepper(value: $fontSize, in: 8...32, step: 1) {
                        Text("\(Int(fontSize)) pt")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                HStack {
                    Text("行高").frame(width: 44, alignment: .leading)
                    Slider(value: $lineHeight, in: 1.0...2.0, step: 0.05)
                    Text(String(format: "%.2f×", lineHeight))
                        .font(.system(.body, design: .monospaced)).frame(width: 52, alignment: .trailing)
                }
                Text("预览 The quick brown fox · 0123 (){}[]")
                    .font(.custom(font, size: fontSize))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                HStack {
                    Text("光标").frame(width: 44, alignment: .leading)
                    Picker("", selection: $cursorStyle) {
                        ForEach(Self.cursorStyles, id: \.value) { Text($0.label).tag($0.value) }
                    }.labelsHidden()
                }
                Toggle("柔和配色(Kaku Dark)", isOn: $softColors)
                Text("套用 Kaku Dark 主题:16 色 ANSI 调色板 + 深色背景/前景/光标,让 claude-hud 进度条等只发索引色的程序不再刺眼。关闭则回到默认自适应配色。")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // MARK: notifications
            VStack(alignment: .leading, spacing: 8) {
                Text("通知").font(.subheadline).bold()
                Toggle("会话完成时发送系统通知", isOn: $notify)
                Text("当某个会话在你未查看它时完成一轮回答,发送 macOS 系统通知(点击通知直接跳到该会话)。首次开启会弹系统授权;若之前拒绝过,需去「系统设置 → 通知 → Leader」手动允许。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // MARK: proxy
            VStack(alignment: .leading, spacing: 8) {
                Text("代理").font(.subheadline).bold()
                Toggle("启用代理", isOn: $enabled)
                HStack(spacing: 6) {
                    TextField("127.0.0.1:6789", text: $addr)
                        .textFieldStyle(.roundedBorder).disabled(!enabled)
                    Button("检测环境") {
                        let d = Conf.detectedEnvProxy()
                        if !d.isEmpty { addr = d; enabled = true }
                    }.help("从当前 shell 的 http_proxy / https_proxy 读取")
                }
                Text("填 host:port(不带 http://)。启用后,每个新终端启动时会注入 "
                     + "http_proxy / https_proxy / all_proxy。从 Raycast/Dock 启动 App "
                     + "时没有 shell 环境,必须在这里显式设置代理,否则 claude 连不上会让你登录。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("代理改动对已打开的终端不生效,重开该会话即可。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    let val = enabled ? addr.trimmingCharacters(in: .whitespaces) : ""
                    Conf.save(["proxy": val,
                               "term_font": font,
                               "term_font_size": Double(fontSize),
                               "line_height": Double(lineHeight),
                               "soft_colors": softColors,
                               "term_cursor_style": cursorStyle,
                               "notify": notify])
                    // If notifications were just enabled, (re)request authorization now.
                    if notify {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
                    TerminalManager.shared.reapplyTheme()   // live terminals update now
                    QuakeTerminal.shared.reapplyTheme()
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 400)
    }
}
