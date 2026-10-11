// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HerdrKit",
    platforms: [
        .iOS(.v17),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "HerdrKit", targets: ["HerdrKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", .upToNextMinor(from: "0.12.1")),
        // Same NIOSSH fork Citadel depends on, declared here so we can import NIOSSH types directly.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(
            name: "HerdrKit",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "HerdrKitTests",
            dependencies: ["HerdrKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
