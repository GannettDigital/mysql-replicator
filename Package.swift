// swift-tools-version: 6.1
import PackageDescription
import Foundation
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let package = Package(
    name: "mysql-replicator",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "mysql-replicator", targets: ["ReplicatorCLI"])],
    targets: [
        .systemLibrary(name: "CReplicatorCodec"),
        .target(name: "ReplicatorCodec", dependencies: ["CReplicatorCodec"],
            linkerSettings: [.unsafeFlags(["-L", root + "/rust/target/debug"]),
                .linkedLibrary("pthread", .when(platforms: [.linux])),
                .linkedLibrary("dl", .when(platforms: [.linux])),
                .linkedLibrary("m", .when(platforms: [.linux]))]),
        .executableTarget(name: "ReplicatorCLI", dependencies: ["ReplicatorCodec"])
    ]
)
