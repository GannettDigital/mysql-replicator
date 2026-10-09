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
        .package(path: "Vendor/mysql-nio"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.90.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ],
    targets: [
        .systemLibrary(name: "CReplicatorCodec"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "ReplicatorCodec", dependencies: ["CReplicatorCodec"],
            linkerSettings: [.unsafeFlags(["-L", codecLibraryPath]),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("m", .when(platforms: [.linux]))]),
        .target(name: "ReplicatorCapture", dependencies: ["ReplicatorCodec",
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "MySQLNIO", package: "mysql-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")]),
        .target(name: "ReplicatorApply", dependencies: ["ReplicatorCapture", "ReplicatorCodec", "CSQLite",
            .product(name: "MySQLNIO", package: "mysql-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")]),
        .target(name: "ReplicatorConfiguration", dependencies: [.product(name: "Yams", package: "Yams")]),
        .executableTarget(name: "ReplicatorCLI", dependencies: ["ReplicatorCodec", "ReplicatorCapture", "ReplicatorApply", "ReplicatorConfiguration"]),
        .testTarget(name: "ReplicatorConfigurationTests", dependencies: ["ReplicatorConfiguration", "ReplicatorApply", "ReplicatorCapture"], path: "tests/ReplicatorConfigurationTests"),
        .testTarget(name: "ReplicatorApplyTests", dependencies: ["ReplicatorApply", "ReplicatorCapture", "ReplicatorCodec", "ReplicatorConfiguration", "CSQLite"], path: "tests/ReplicatorApplyTests"),
        .testTarget(name: "ReplicatorCaptureTests", dependencies: ["ReplicatorCapture", "ReplicatorCodec",
            .product(name: "NIOEmbedded", package: "swift-nio")], path: "tests/ReplicatorCaptureTests"),
        .target(name: "ReplicatorLabCore", dependencies: ["ReplicatorConfiguration", .product(name: "Yams", package: "Yams")]),
        .executableTarget(name: "ReplicatorLab", dependencies: ["ReplicatorLabCore"]),
        .testTarget(name: "ReplicatorCodecTests", dependencies: ["ReplicatorCodec", "CReplicatorCodec", "ReplicatorLabCore"], path: "tests/ReplicatorCodecTests", exclude: ["Schema", "Synthetic"]),
        .testTarget(name: "ReplicatorLabTests", dependencies: ["ReplicatorLabCore"], path: "tests/ReplicatorLabTests",
                    resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
