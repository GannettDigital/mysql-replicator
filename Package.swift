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
    targets: [
        .systemLibrary(name: "CReplicatorCodec"),
        .target(name: "ReplicatorCodec", dependencies: ["CReplicatorCodec"],
            linkerSettings: [.unsafeFlags(["-L", codecLibraryPath]),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("m", .when(platforms: [.linux]))]),
        .executableTarget(name: "ReplicatorCLI", dependencies: ["ReplicatorCodec"]),
        .target(name: "ReplicatorLabCore"),
        .executableTarget(name: "ReplicatorLab", dependencies: ["ReplicatorLabCore"]),
        .testTarget(name: "ReplicatorCodecTests", dependencies: ["ReplicatorCodec", "CReplicatorCodec", "ReplicatorLabCore"], path: "tests/ReplicatorCodecTests", exclude: ["Schema", "Synthetic"]),
        .testTarget(name: "ReplicatorLabTests", dependencies: ["ReplicatorLabCore"], path: "tests/ReplicatorLabTests",
                    resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
