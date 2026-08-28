// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Leader",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Fork of SwiftTerm adding lineHeightMultiplier for adjustable terminal line
        // spacing, with glyphs vertically centered in the taller cell.
        //
        // TODO: upstream main already has an (unreleased) `lineSpacing` — but it does
        // NOT center the glyph (extra space piles above the text). We opened
        // migueldeicaza/SwiftTerm#585 to add that centering. Once #585 is merged AND
        // upstream ships a tagged release that includes `lineSpacing`, drop this fork:
        // point back at the upstream tag and rename `tv.lineHeightMultiplier` ->
        // `tv.lineSpacing` in EmbeddedTerminal.swift (applyTermTheme).
        .package(url: "https://github.com/Coiggahou2002/SwiftTerm.git",
                 revision: "83c4d21cc8320df9d426e67e58f20e544ea4d146"),
        // In-app auto-update (appcast on GitHub Releases). Sparkle ships as a
        // binary XCFramework; build.sh embeds Sparkle.framework into the bundle
        // and adds the @executable_path/../Frameworks rpath (swift build alone
        // does not embed it into a hand-assembled .app).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Leader",
            dependencies: ["SwiftTerm", .product(name: "Sparkle", package: "Sparkle")],
            path: "src",
            // src/ also holds the python backend, the icon generator, and helper
            // scripts — only LeaderApp.swift is compiled into the app.
            exclude: [
                "archive.py", "backup-transcripts.sh", "config.py",
                "hidden.py", "launch.py", "leader-hook.py", "makeicon.swift", "name.py",
                "pin.py", "scan.py", "test_switch.py",
                "unread.py", "__pycache__",
            ],
            sources: ["LeaderApp.swift", "EmbeddedTerminal.swift", "QuakeTerminal.swift",
                      "DesignSystem.swift", "Model.swift", "Store.swift", "Activity.swift",
                      "RowViews.swift", "AppDelegate.swift", "Sheets.swift"]
        ),
        .executableTarget(
            name: "replay",
            dependencies: ["SwiftTerm"],
            path: "replay"
        ),
    ]
)
