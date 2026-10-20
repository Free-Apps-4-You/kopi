// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// Apple's Command Line Tools install the Swift Testing macro plugin in a `testing`
/// subdirectory that the compiler's default plugin search path does not cover, which
/// makes the test module fail to expand `@Test` on a machine without Xcode. The
/// directory is added where it exists, so other toolchain layouts are left alone.
let swiftTestingPluginPaths = [
    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
].filter { FileManager.default.fileExists(atPath: $0) }

let swiftTestingPluginSettings = swiftTestingPluginPaths.flatMap { path in
    [SwiftSetting.unsafeFlags(["-plugin-path", path])]
}

let package = Package(
    name: "Kopi",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KopiCore", targets: ["KopiCore"]),
        .executable(name: "Kopi", targets: ["Kopi"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "NotesScripting",
            linkerSettings: [
                .linkedFramework("ScriptingBridge")
            ]
        ),
        .target(
            name: "KopiCore",
            dependencies: [
                "NotesScripting",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "Kopi",
            dependencies: ["KopiCore"]
        ),
        .testTarget(
            name: "KopiCoreTests",
            dependencies: ["KopiCore", "Kopi"],
            swiftSettings: swiftTestingPluginSettings
        )
    ],
    swiftLanguageModes: [.v6]
)
