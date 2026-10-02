// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zeddy",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // Vendored SQLite 3 (amalgamation) — the fast engine. Static C library.
        .target(
            name: "SQLiteShim",
            path: "Sources/SQLite",
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_OMIT_LOAD_EXTENSION")
            ]
        ),
        // Core domain: the FTS5-backed store, token-budgeted context builder,
        // settings, IPC protocol, daemon process control, and the typed client.
        .target(
            name: "ZeddyCore",
            dependencies: ["SQLiteShim"],
            path: "Sources/ZeddyCore"
        ),
        // Background daemon: owns the store + Unix socket.
        .executableTarget(
            name: "zeddy-daemon",
            dependencies: ["ZeddyCore"],
            path: "Sources/zeddy-daemon"
        ),
        // CLI: the Zed integration surface.
        .executableTarget(
            name: "zeddy",
            dependencies: ["ZeddyCore"],
            path: "Sources/zeddy"
        ),
        // GUI: full application management.
        .executableTarget(
            name: "zeddy-app",
            dependencies: ["ZeddyCore"],
            path: "Sources/zeddy-app"
        ),
        .testTarget(
            name: "ZeddyCoreTests",
            dependencies: ["ZeddyCore"],
            path: "Tests/ZeddyCoreTests"
        )
    ]
)
