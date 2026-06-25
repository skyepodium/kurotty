// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kurotty",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Kurotty", targets: ["KurottyApp"]),
    ],
    targets: [
        .executableTarget(
            name: "KurottyApp",
            resources: [
                .process("Shaders"),
                .copy("Resources/kurotty.png"),
            ]
        ),
        .testTarget(
            name: "KurottyRenderingTests"
        ),
    ]
)
