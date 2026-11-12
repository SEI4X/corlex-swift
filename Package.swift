// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Corlex",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Corlex", targets: ["Corlex"]),
    ],
    targets: [
        // Fatal-signal handler, loaded-image table and report writer: C, because everything the
        // handler runs must be async-signal-safe.
        .target(name: "CCorlexCrash", path: "Sources/CCorlexCrash"),
        .target(
            name: "Corlex",
            dependencies: ["CCorlexCrash"],
            path: "Sources/Corlex",
            resources: [.process("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "CorlexTests",
            dependencies: ["Corlex"],
            path: "Tests/CorlexTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
