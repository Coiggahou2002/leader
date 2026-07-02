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
                 revision: "d59975b82d12d3a1e2d4f624a78c3621a4e33b35")
    ],
    targets: [
        .executableTarget(
            name: "Leader",
            dependencies: ["SwiftTerm"],
            path: "src",
            // src/ also holds the python backend, the icon generator, and helper
            // scripts — only LeaderApp.swift is compiled into the app.
            exclude: [
                "archive.py", "backup-transcripts.sh", "build.sh", "config.py",
                "launch.py", "leader-hook.py", "makeicon.swift", "name.py",
                "pin.py", "scan.py", "server.py", "start.sh", "test_switch.py",
            ],
            sources: ["LeaderApp.swift", "EmbeddedTerminal.swift", "QuakeTerminal.swift"]
        ),
        .executableTarget(
            name: "replay",
            dependencies: ["SwiftTerm"],
            path: "replay"
        ),
    ]
)
