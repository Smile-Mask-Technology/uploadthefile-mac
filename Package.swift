// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed (no Xcode), SwiftPM does not find Swift Testing:
// it passes the CLT frameworks folder as `-I` but the framework needs `-F`, a runtime search path
// and a linker path. Add them for the test target in that situation only; with Xcode installed
// SwiftPM already does the right thing.
let commandLineToolsFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let commandLineToolsLibraries = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let needsTestingFrameworkPaths =
    FileManager.default.fileExists(atPath: commandLineToolsFrameworks + "/Testing.framework")
    && !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
let testSwiftSettings: [SwiftSetting] =
    needsTestingFrameworkPaths ? [.unsafeFlags(["-F", commandLineToolsFrameworks])] : []
let testLinkerSettings: [LinkerSetting] =
    needsTestingFrameworkPaths
    ? [
        .unsafeFlags([
            "-F", commandLineToolsFrameworks,
            "-Xlinker", "-rpath", "-Xlinker", commandLineToolsFrameworks,
            "-Xlinker", "-rpath", "-Xlinker", commandLineToolsLibraries,
        ])
    ]
    : []

let package = Package(
    name: "uploadthefile-mac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UptfKit", targets: ["UptfKit"]),
        .executable(name: "uptf", targets: ["uptf"]),
        .executable(name: "UploadTheFile", targets: ["UploadTheFile"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(
            name: "UptfKit",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            ],
            swiftSettings: [.enableUpcomingFeature("InternalImportsByDefault")],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .executableTarget(
            name: "uptf",
            dependencies: [
                "UptfKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // The app's logic without any UI: publish flow, confirmations, row state, messages.
        .target(
            name: "UploadTheFileCore",
            dependencies: ["UptfKit"]
        ),
        .executableTarget(
            name: "UploadTheFile",
            dependencies: [
                "UptfKit", "UploadTheFileCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // Sparkle.framework is copied to Contents/Frameworks by scripts/build-app.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "UploadTheFileCoreTests",
            dependencies: ["UploadTheFileCore", "UptfKit"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "UptfKitTests",
            dependencies: [
                "UptfKit",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
