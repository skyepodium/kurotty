import Foundation

#if os(macOS)
import Darwin
#endif

enum TerminalProcessArguments {
    #if os(macOS)
    static func commandName(pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var byteCount = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &byteCount, nil, 0) == 0,
              byteCount > MemoryLayout<Int32>.size else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &byteCount, nil, 0)
        }
        guard status == 0 else { return nil }
        return commandName(fromKernProcArgs2: Array(bytes.prefix(byteCount)))
    }
    #endif

    static func commandName(fromKernProcArgs2 bytes: [UInt8]) -> String? {
        var index = MemoryLayout<Int32>.size
        guard index < bytes.count else { return nil }

        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        let argumentStart = index
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        guard argumentStart < index else { return nil }

        let argument = String(decoding: bytes[argumentStart..<index], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !argument.isEmpty else { return nil }
        let name = URL(fileURLWithPath: argument).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

struct TerminalRuntimeNotificationMetadata: Equatable {
    let command: String
    let workingDirectory: String?

    static func parse(_ text: String) -> Self? {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        let command = URL(fileURLWithPath: String(fields[0])).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !workingDirectory.isEmpty else { return nil }
        return Self(command: command, workingDirectory: workingDirectory)
    }
}
