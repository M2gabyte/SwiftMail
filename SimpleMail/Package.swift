// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimpleMail",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SimpleMail",
            targets: ["SimpleMail"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/google/GoogleSignIn-iOS", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "SimpleMail",
            dependencies: [
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "SimpleMailTests",
            dependencies: ["SimpleMail"],
            path: "Tests"
        ),
    ]
)
