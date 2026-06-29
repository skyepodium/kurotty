import Foundation

extension Character {
    var terminalColumnWidth: Int {
        if unicodeScalars.allSatisfy({ CharacterSet.nonBaseCharacters.contains($0) }) {
            return 0
        }
        let widthScalar = firstBaseScalarForTerminalWidth ?? unicodeScalars.first
        guard let scalar = widthScalar else { return 1 }
        let value = scalar.value
        if value == 0 || (value < 32) || (0x7f..<0xa0).contains(value) {
            return 0
        }
        if value >= 0x1100 &&
            (value <= 0x115f ||
             value == 0x2329 || value == 0x232a ||
             (0x2e80...0xa4cf).contains(value) ||
             (0xac00...0xd7a3).contains(value) ||
             (0xf900...0xfaff).contains(value) ||
             (0xfe10...0xfe19).contains(value) ||
             (0xfe30...0xfe6f).contains(value) ||
             (0xff00...0xff60).contains(value) ||
             (0xffe0...0xffe6).contains(value) ||
             (0x1f300...0x1f64f).contains(value) ||
             (0x1f900...0x1f9ff).contains(value)) {
            return 2
        }
        return 1
    }

    var isTerminalPrintableGrapheme: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        let value = scalar.value
        return value != 0x1b && value != 10 && value != 13 && value != 8 && value != 9 &&
            value >= 32 && value != 127
    }

    private var firstBaseScalarForTerminalWidth: UnicodeScalar? {
        unicodeScalars.first { scalar in
            !CharacterSet.nonBaseCharacters.contains(scalar) &&
                scalar.value != 0x200d &&
                !(0xfe00...0xfe0f).contains(scalar.value)
        }
    }
}

extension String {
    var terminalColumnWidth: Int {
        reduce(0) { $0 + $1.terminalColumnWidth }
    }
}
