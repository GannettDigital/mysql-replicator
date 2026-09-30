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
    ],
    targets: [
        .systemLibrary(name: "CReplicatorCodec"),
        .target(name: "ReplicatorCodec", dependencies: ["CReplicatorCodec"],
            linkerSettings: [.unsafeFlags(["-L", codecLibraryPath]),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("m", .when(platforms: [.linux]))]),
        .target(name: "ReplicatorCapture", dependencies: ["ReplicatorCodec",
            .product(name: "MySQLNIO", package: "mysql-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")]),
        .executableTarget(name: "ReplicatorCLI", dependencies: ["ReplicatorCodec", "ReplicatorCapture"]),
        .testTarget(name: "ReplicatorCaptureTests", dependencies: ["ReplicatorCapture", "ReplicatorCodec",
            .product(name: "NIOEmbedded", package: "swift-nio")], path: "tests/ReplicatorCaptureTests"),
        .target(name: "ReplicatorLabCore"),
        .executableTarget(name: "ReplicatorLab", dependencies: ["ReplicatorLabCore"]),
        .testTarget(name: "ReplicatorCodecTests", dependencies: ["ReplicatorCodec", "CReplicatorCodec", "ReplicatorLabCore"], path: "tests/ReplicatorCodecTests", exclude: ["Schema", "Synthetic"]),
        .testTarget(name: "ReplicatorLabTests", dependencies: ["ReplicatorLabCore"], path: "tests/ReplicatorLabTests",
                    resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
