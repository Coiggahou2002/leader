// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Leader",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Fork of SwiftTerm adding lineHeightMultiplier (adjustable terminal line
        // spacing; upstream has no such option). Branch leader-line-height off 1.13.0.
        .package(url: "https://github.com/Coiggahou2002/SwiftTerm.git",
                 revision: "8d3bd3b7325e3faa623a82aee52b481176dbded9")
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
                "launch.py", "makeicon.swift", "name.py", "pin.py", "scan.py",
                "server.py", "start.sh", "test_switch.py",
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
