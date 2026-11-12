// swift-tools-version:5.9
import PackageDescription

// The dSYM -> Corlex symtab v1 generator. A separate package from the SDK: it runs on the
// developer's Mac (or CI) during the build, uses dwarfdump, nm and otool from Xcode, and has
// no relation to what ships in the app. `scripts/upload-symbols.sh` compiles the same sources
// with swiftc, so it works on a stock Xcode machine without resolving this package.
let package = Package(
    name: "CorlexSymtabTool",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "corlex-symtab", path: "Sources/corlex-symtab"),
        .testTarget(
            name: "CorlexSymtabTests",
            dependencies: ["corlex-symtab"],
            path: "Tests/CorlexSymtabTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
