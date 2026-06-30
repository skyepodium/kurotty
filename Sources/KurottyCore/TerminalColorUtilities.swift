import Foundation

public enum TerminalPalette {
    public static let ansiNormal: [SIMD4<Float>] = [
        SIMD4<Float>(0.00, 0.00, 0.00, 1),
        SIMD4<Float>(0.78, 0.18, 0.18, 1),
        SIMD4<Float>(0.18, 0.62, 0.28, 1),
        SIMD4<Float>(0.78, 0.62, 0.20, 1),
        SIMD4<Float>(0.22, 0.42, 0.86, 1),
        SIMD4<Float>(0.68, 0.32, 0.72, 1),
        SIMD4<Float>(0.20, 0.68, 0.72, 1),
        SIMD4<Float>(0.82, 0.82, 0.82, 1),
    ]

    public static let ansiBright: [SIMD4<Float>] = [
        SIMD4<Float>(0.30, 0.30, 0.30, 1),
        SIMD4<Float>(1.00, 0.32, 0.32, 1),
        SIMD4<Float>(0.35, 0.85, 0.45, 1),
        SIMD4<Float>(1.00, 0.82, 0.30, 1),
        SIMD4<Float>(0.42, 0.62, 1.00, 1),
        SIMD4<Float>(0.88, 0.50, 0.95, 1),
        SIMD4<Float>(0.40, 0.88, 0.92, 1),
        SIMD4<Float>(1.00, 1.00, 1.00, 1),
    ]

    public static func ansiColor(_ index: Int, bright: Bool) -> SIMD4<Float> {
        (bright ? ansiBright : ansiNormal)[max(0, min(index, 7))]
    }
}

public extension SIMD4 where Scalar == Float {
    func sameColor(as other: SIMD4<Float>) -> Bool {
        x == other.x && y == other.y && z == other.z && w == other.w
    }

    var perceivedLuminance: Float {
        x * 0.2126 + y * 0.7152 + z * 0.0722
    }

    var debugRGB: String {
        String(format: "(%0.3f,%0.3f,%0.3f,%0.3f)", x, y, z, w)
    }
}
