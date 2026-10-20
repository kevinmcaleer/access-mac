// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AccessKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AccessEngine", targets: ["AccessEngine"]),
        .library(name: "AccessCore", targets: ["AccessCore"]),
        .library(name: "AccessSQL", targets: ["AccessSQL"]),
        .executable(name: "accessdump", targets: ["accessdump"]),
    ],
    targets: [
        // Reads (and later writes) the Jet/ACE page format. No UI dependency.
        .target(name: "AccessEngine"),
        // The object model shared by the app and the engines.
        .target(name: "AccessCore", dependencies: ["AccessEngine"]),
        // Access SQL: lexer today, parser and executor to follow.
        .target(name: "AccessSQL", dependencies: ["AccessCore"]),
        // Command-line inspector, handy for debugging files on any platform.
        .executableTarget(name: "accessdump", dependencies: ["AccessEngine"]),
        .testTarget(
            name: "AccessEngineTests",
            dependencies: ["AccessEngine"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "AccessCoreTests", dependencies: ["AccessCore"]),
        .testTarget(name: "AccessSQLTests", dependencies: ["AccessSQL"]),
    ]
)
