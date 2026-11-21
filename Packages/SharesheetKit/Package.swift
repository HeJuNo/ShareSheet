// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SharesheetKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SharesheetCore", targets: ["SharesheetCore"]),
        .library(name: "SharesheetUI", targets: ["SharesheetUI"]),
        .library(name: "InstagramMedia", targets: ["InstagramMedia"]),
        .library(name: "XMedia", targets: ["XMedia"]),
        .library(name: "SpotifyMedia", targets: ["SpotifyMedia"]),
        .library(name: "FacebookMedia", targets: ["FacebookMedia"]),
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
        .target(name: "InstagramMedia", dependencies: ["SharesheetCore"]),
        .target(
            name: "XMedia",
            dependencies: ["SharesheetCore", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .target(name: "SpotifyMedia", dependencies: ["SharesheetCore"]),
        .target(
            name: "FacebookMedia",
            dependencies: ["SharesheetCore", .product(name: "SwiftSoup", package: "SwiftSoup")]),
        .testTarget(
            name: "SharesheetCoreTests",
            dependencies: ["SharesheetCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(
            name: "InstagramMediaTests",
            dependencies: ["InstagramMedia", "SharesheetCore"]),
        .testTarget(
            name: "XMediaTests",
            dependencies: ["XMedia", "SharesheetCore"]),
        .testTarget(
            name: "SpotifyMediaTests",
            dependencies: ["SpotifyMedia", "SharesheetCore"]),
        .testTarget(
            name: "FacebookMediaTests",
            dependencies: ["FacebookMedia", "SharesheetCore"]),
    ]
)
