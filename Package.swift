// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kurotty",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "KurottyCore", targets: ["KurottyCore"]),
        .executable(name: "kurotty", targets: ["KurottyApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3"),
    ],
    targets: [
        .target(
            name: "KurottyCore"
        ),
        .executableTarget(
            name: "KurottyApp",
            dependencies: [
                "KurottyCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources/kurotty.png"),
                .copy("Resources/ShellIntegration"),
            ]
        ),
        .testTarget(
            name: "KurottyRenderingTests",
            dependencies: ["KurottyApp", "KurottyCore"]
        ),
    ]
)
