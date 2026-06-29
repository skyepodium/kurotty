import simd

struct TerminalTextStyle: Equatable {
    var foreground: SIMD4<Float>
    var background: SIMD4<Float>
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var blink = false
    var strikethrough = false
    var inverse = false

    static let `default` = TerminalTextStyle(
        foreground: SIMD4<Float>(0.92, 0.92, 0.92, 1),
        background: SIMD4<Float>(0, 0, 0, 1)
    )

    var effectiveForeground: SIMD4<Float> {
        if inverse {
            return background
        }
        let weighted = bold ? brighten(foreground) : foreground
        return dim ? dimmed(weighted, against: background) : weighted
    }

    var effectiveBackground: SIMD4<Float> {
        inverse ? foreground : background
    }

    var isLightBackground: Bool {
        luminance(background) > 0.5
    }

    static func ansiColor(_ index: Int, bright: Bool) -> SIMD4<Float> {
        TerminalPalette.ansiColor(index, bright: bright)
    }

    static func rgb(red: Int, green: Int, blue: Int) -> SIMD4<Float> {
        SIMD4<Float>(
            Float(max(0, min(red, 255))) / 255,
            Float(max(0, min(green, 255))) / 255,
            Float(max(0, min(blue, 255))) / 255,
            1
        )
    }

    static func xterm256Color(_ value: Int) -> SIMD4<Float> {
        let index = max(0, min(value, 255))
        if index < 16 {
            return ansiColor(index % 8, bright: index >= 8)
        }
        if index < 232 {
            let cube = index - 16
            let r = cube / 36
            let g = (cube / 6) % 6
            let b = cube % 6
            func component(_ value: Int) -> Int { value == 0 ? 0 : 55 + value * 40 }
            return rgb(red: component(r), green: component(g), blue: component(b))
        }
        let gray = 8 + (index - 232) * 10
        return rgb(red: gray, green: gray, blue: gray)
    }

    private func brighten(_ color: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(min(color.x * 1.15, 1), min(color.y * 1.15, 1), min(color.z * 1.15, 1), color.w)
    }

    private func dimmed(_ color: SIMD4<Float>, against background: SIMD4<Float>) -> SIMD4<Float> {
        if luminance(background) > 0.5 {
            return blend(color, background, amount: dimBlendAmount(for: color))
        }
        return SIMD4<Float>(color.x * 0.62, color.y * 0.62, color.z * 0.62, color.w)
    }

    private func dimBlendAmount(for color: SIMD4<Float>) -> Float {
        chroma(color) > 0.08 ? 0.04 : 0.48
    }

    private func chroma(_ color: SIMD4<Float>) -> Float {
        max(color.x, max(color.y, color.z)) - min(color.x, min(color.y, color.z))
    }

    private func blend(_ color: SIMD4<Float>, _ background: SIMD4<Float>, amount: Float) -> SIMD4<Float> {
        let kept = max(0, min(1, 1 - amount))
        let mixed = max(0, min(1, amount))
        return SIMD4<Float>(
            color.x * kept + background.x * mixed,
            color.y * kept + background.y * mixed,
            color.z * kept + background.z * mixed,
            color.w
        )
    }

    private func luminance(_ color: SIMD4<Float>) -> Float {
        color.x * 0.2126 + color.y * 0.7152 + color.z * 0.0722
    }
}
