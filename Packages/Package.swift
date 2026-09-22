// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Packages",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Data", targets: ["Data"]),
        .library(name: "Platform", targets: ["Platform"]),
        .library(name: "Features", targets: ["Features"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-imap.git", from: "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Data", dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "Platform", dependencies: ["Domain", "Data",
            .product(name: "NIO", package: "swift-nio"),
            .product(name: "NIOIMAP", package: "swift-nio-imap"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .target(name: "Features", dependencies: ["Domain", "Data"]),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "DataTests", dependencies: ["Data"]),
        .testTarget(name: "PlatformTests", dependencies: ["Platform"]),
        .testTarget(name: "FeaturesTests", dependencies: ["Features"]),
    ],
    swiftLanguageModes: [.v6]
)
