// swift-tools-version: 6.0
import PackageDescription
import Foundation

let commandLineToolsTestingPath =
    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let commandLineToolsTestingLibraryPath =
    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let usesCommandLineToolsTesting = FileManager.default.fileExists(
    atPath: "\(commandLineToolsTestingPath)/Testing.framework")

let localTestSwiftSettings: [SwiftSetting] = usesCommandLineToolsTesting ? [
    .unsafeFlags(["-F", commandLineToolsTestingPath]),
] : []

let localTestLinkerSettings: [LinkerSetting] = usesCommandLineToolsTesting ? [
    .unsafeFlags([
        "-F", commandLineToolsTestingPath,
        "-framework", "Testing",
        "-Xlinker", "-rpath",
        "-Xlinker", commandLineToolsTestingPath,
        "-Xlinker", "-rpath",
        "-Xlinker", commandLineToolsTestingLibraryPath,
    ]),
] : []

let package = Package(
    name: "GPTAccountManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "GPTAccountManager", targets: ["GPTAccountManager"])],
    targets: [
        .executableTarget(name: "GPTAccountManager"),
        .testTarget(
            name: "GPTAccountManagerTests",
            dependencies: ["GPTAccountManager"],
            swiftSettings: localTestSwiftSettings,
            linkerSettings: localTestLinkerSettings),
    ]
)
