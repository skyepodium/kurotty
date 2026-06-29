// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kurotty",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "kurotty", targets: ["KurottyApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
    ],
    targets: [
        .executableTarget(
            name: "KurottyApp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/kurotty.png"),
            ]
        ),
        .testTarget(
            name: "KurottyRenderingTests",
            dependencies: ["KurottyApp"]
        ),
    ]
)
