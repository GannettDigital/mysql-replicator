// swift-tools-version: 6.1
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let codecLibraryPath = ProcessInfo.processInfo.environment["REPLICATOR_CODEC_LIBRARY_PATH"] ?? root + "/rust/target/debug"
let package = Package(
    name: "mysql-replicator",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "mysql-replicator", targets: ["ReplicatorCLI"]),
        .executable(name: "replicator-lab", targets: ["ReplicatorLab"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.15.1"),
        .package(path: "Vendor/mysql-nio"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.90.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.7.0"),
    ],
    targets: [
        .target(name: "ReplicatorLogging", dependencies: [.product(name: "Logging", package: "swift-log")]),
        .testTarget(name: "ReplicatorLoggingTests", dependencies: ["ReplicatorLogging"], path: "tests/ReplicatorLoggingTests"),
        .target(name: "MySQLSyntax"),
        .testTarget(name: "MySQLSyntaxTests", dependencies: ["MySQLSyntax"], path: "tests/MySQLSyntaxTests"),
        .systemLibrary(name: "CReplicatorCodec"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "ReplicatorCodec", dependencies: ["CReplicatorCodec", "MySQLSyntax"],
            linkerSettings: [.unsafeFlags(["-L", codecLibraryPath]),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("m", .when(platforms: [.linux]))]),
        .target(name: "ReplicatorCapture", dependencies: ["ReplicatorLogging", "ReplicatorCodec",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "MySQLNIO", package: "mysql-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")]),
        .target(name: "ReplicatorApply", dependencies: ["ReplicatorLogging", "MySQLSyntax", "ReplicatorCapture", "ReplicatorCodec", "CSQLite",
            .product(name: "MySQLNIO", package: "mysql-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")]),
        .target(name: "ReplicatorConfiguration", dependencies: [.product(name: "Yams", package: "Yams")]),
        .target(name: "ReplicatorCommandLine", dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "ReplicatorCommandLineTests", dependencies: ["ReplicatorCommandLine"], path: "tests/ReplicatorCommandLineTests"),
        .executableTarget(name: "ReplicatorCLI", dependencies: ["ReplicatorLogging", "ReplicatorCommandLine", "ReplicatorCodec", "ReplicatorCapture", "ReplicatorApply", "ReplicatorConfiguration"]),
        .testTarget(name: "ReplicatorConfigurationTests", dependencies: ["ReplicatorConfiguration", "ReplicatorApply", "ReplicatorCapture"], path: "tests/ReplicatorConfigurationTests"),
        .testTarget(name: "ReplicatorApplyTests", dependencies: ["ReplicatorApply", "ReplicatorCapture", "ReplicatorCodec", "ReplicatorConfiguration", "CSQLite",
            .product(name: "NIOEmbedded", package: "swift-nio")], path: "tests/ReplicatorApplyTests"),
        .testTarget(name: "ReplicatorCaptureTests", dependencies: ["ReplicatorCapture", "ReplicatorCodec",
            .product(name: "NIOEmbedded", package: "swift-nio")], path: "tests/ReplicatorCaptureTests"),
        .target(name: "ReplicatorLabCore", dependencies: ["ReplicatorConfiguration", .product(name: "Yams", package: "Yams")]),
        .target(name: "ReplicatorLabCommandLine", dependencies: ["ReplicatorLabCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "ReplicatorLabCommandLineTests", dependencies: ["ReplicatorLabCommandLine"], path: "tests/ReplicatorLabCommandLineTests"),
        .executableTarget(name: "ReplicatorLab", dependencies: ["ReplicatorLabCore", "ReplicatorLabCommandLine"]),
        .testTarget(name: "ReplicatorCodecTests", dependencies: ["ReplicatorCodec", "CReplicatorCodec", "ReplicatorLabCore"], path: "tests/ReplicatorCodecTests", exclude: ["Schema", "Synthetic"]),
        .testTarget(name: "ReplicatorLabTests", dependencies: ["ReplicatorLabCore"], path: "tests/ReplicatorLabTests",
                    resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)

// Build the packaging probe only in the static Docker builder. It shares the
// production dependency graph and objects without entering unit/Periphery builds.
if ProcessInfo.processInfo.environment["REPLICATOR_PACKAGING"] == "1" {
    package.products.append(.executable(name: "packaging-probe", targets: ["PackagingProbe"]))
    package.targets += [
        .systemLibrary(name: "CPackagingRust", path: "packaging/Probe/Sources/CPackagingRust"),
        .executableTarget(name: "PackagingProbe", dependencies: ["CSQLite", "CPackagingRust",
            .product(name: "MySQLNIO", package: "mysql-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")],
            path: "packaging/Probe/Sources/PackagingProbe",
            linkerSettings: [.unsafeFlags(["-L", codecLibraryPath])])
    ]
}
