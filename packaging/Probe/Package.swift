// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "PackagingProbe",
    products: [.executable(name: "packaging-probe", targets: ["PackagingProbe"])],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", exact: "1.9.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.90.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.0"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CPackagingRust"),
        .executableTarget(name: "PackagingProbe", dependencies: ["CSQLite", "CPackagingRust",
            .product(name: "MySQLNIO", package: "mysql-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl")])
    ], swiftLanguageModes: [.v5]
)
