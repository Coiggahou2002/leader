// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Leader",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
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
            sources: ["LeaderApp.swift", "EmbeddedTerminal.swift"]
        ),
        .executableTarget(
            name: "replay",
            dependencies: ["SwiftTerm"],
            path: "replay"
        ),
    ]
)
