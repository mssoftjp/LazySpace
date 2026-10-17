// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "LazySpace",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Update checks and installation for the distributed app.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // User-facing strings (English base, Japanese translation).
        .target(name: "Copy", path: "Sources/Copy"),
        // Layout model and planner. No AX, Spaces, or clocks.
        .target(name: "LayoutCore", path: "Sources/LayoutCore"),
        // Operations. Touches the OS only through the WindowSystem protocol.
        .target(name: "Operations", dependencies: ["LayoutCore", "Copy"], path: "Sources/Operations"),
        // Reading, validating, and saving settings. ConfigFile owns file I/O.
        .target(name: "Settings", dependencies: ["LayoutCore", "Copy"], path: "Sources/Settings"),
        // macOS integration: AX, CGWindowList, SkyLight, input observation. The only place that writes to the OS.
        .target(name: "MacSupport", dependencies: ["Operations", "Copy"], path: "Sources/MacSupport"),
        // The app (menu bar, window list, CLI) as a library, so the tests can import it.
        .target(
            name: "LazySpaceApp",
            dependencies: ["LayoutCore", "Operations", "MacSupport", "Settings", "Copy", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/LazySpaceApp"
        ),
        // The executable: main.swift only.
        .executableTarget(
            name: "LazySpace",
            dependencies: ["LazySpaceApp"],
            path: "Sources/LazySpace",
            // Sparkle.framework is embedded in Contents/Frameworks of the app bundle.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Investigation probe. Not shipped.
        .executableTarget(
            name: "lzprobe",
            dependencies: ["MacSupport"],
            path: "Sources/lzprobe"
        ),
        .testTarget(name: "CopyTests", dependencies: ["Copy"], path: "Tests/CopyTests"),
        .testTarget(name: "MacSupportTests", dependencies: ["MacSupport", "Operations", "Copy"], path: "Tests/MacSupportTests"),
        .testTarget(name: "LayoutCoreTests", dependencies: ["LayoutCore"], path: "Tests/LayoutCoreTests"),
        .testTarget(name: "OperationsTests", dependencies: ["Operations", "LayoutCore", "Copy"], path: "Tests/OperationsTests"),
        .testTarget(name: "SettingsTests", dependencies: ["Settings", "LayoutCore", "Copy"], path: "Tests/SettingsTests"),
        .testTarget(name: "LZProbeTests", dependencies: ["lzprobe", "MacSupport", "Operations"], path: "Tests/LZProbeTests"),
        .testTarget(name: "LazySpaceTests", dependencies: ["LazySpaceApp", "MacSupport", "Operations", "LayoutCore", "Copy"], path: "Tests/LazySpaceTests"),
    ],
    swiftLanguageModes: [.v5]
)
