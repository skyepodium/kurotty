// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kurotty",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "KurottyApp", targets: ["KurottyApp"]),
    ],
    targets: [
        .executableTarget(
            name: "KurottyApp",
            resources: [
                .process("Shaders"),
            ]
        ),
        .testTarget(
            name: "KurottyRenderingTests"
        ),
    ]
)
