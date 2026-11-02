// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SharesheetKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SharesheetCore", targets: ["SharesheetCore"]),
        .library(name: "SharesheetUI", targets: ["SharesheetUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.12.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup", from: "2.14.3"),
    ],
    targets: [
        .target(
            name: "SharesheetCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .target(name: "SharesheetUI", dependencies: ["SharesheetCore"]),
        .testTarget(name: "SharesheetCoreTests", dependencies: ["SharesheetCore"]),
    ]
)
