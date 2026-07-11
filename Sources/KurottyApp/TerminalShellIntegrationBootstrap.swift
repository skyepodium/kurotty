import Foundation

struct TerminalShellLaunchConfiguration: Equatable {
    let argumentZero: String
    let arguments: [String]
    let environment: [String: String]
    let environmentKeysToUnset: [String]
    let automaticallyInjectsCommandBoundaries: Bool
}

enum TerminalShellIntegrationBootstrap {
    private static let preservedZDOTDIREnvironmentName = "KUROTTY_ZSH_ZDOTDIR"

    static var bundledResourceDirectory: URL? {
        Bundle.module.url(forResource: "ShellIntegration", withExtension: nil)
    }

    static func bundledConfiguration(
        shellPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalShellLaunchConfiguration {
        configuration(
            shellPath: shellPath,
            environment: environment,
            resourceDirectory: bundledResourceDirectory
        )
    }

    static func configuration(
        shellPath: String,
        environment: [String: String],
        resourceDirectory: URL?
    ) -> TerminalShellLaunchConfiguration {
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        let fallback = TerminalShellLaunchConfiguration(
            argumentZero: "-\(shellName)",
            arguments: ["-i"],
            environment: [:],
            environmentKeysToUnset: [],
            automaticallyInjectsCommandBoundaries: false
        )
        guard let resourceDirectory else {
            return fallback
        }

        switch shellName {
        case "zsh":
            let integrationDirectory = resourceDirectory.appendingPathComponent("zsh", isDirectory: true)
            guard FileManager.default.fileExists(atPath: integrationDirectory.appendingPathComponent(".zshenv").path) else {
                return fallback
            }
            var overrides = ["ZDOTDIR": integrationDirectory.path]
            var keysToUnset: [String] = []
            if let existingZDOTDIR = environment["ZDOTDIR"], !existingZDOTDIR.isEmpty {
                overrides[preservedZDOTDIREnvironmentName] = existingZDOTDIR
            } else {
                keysToUnset.append(preservedZDOTDIREnvironmentName)
            }
            return TerminalShellLaunchConfiguration(
                argumentZero: "-zsh",
                arguments: ["-i"],
                environment: overrides,
                environmentKeysToUnset: keysToUnset,
                automaticallyInjectsCommandBoundaries: true
            )
        case "bash":
            let script = resourceDirectory.appendingPathComponent("bash/kurotty.bash")
            guard FileManager.default.fileExists(atPath: script.path) else {
                return fallback
            }
            return TerminalShellLaunchConfiguration(
                argumentZero: "bash",
                arguments: ["--rcfile", script.path, "-i"],
                environment: [:],
                environmentKeysToUnset: [],
                automaticallyInjectsCommandBoundaries: true
            )
        case "fish":
            let fishDataDirectory = resourceDirectory.appendingPathComponent("fish", isDirectory: true)
            let script = fishDataDirectory.appendingPathComponent("share/fish/vendor_conf.d/kurotty-shell-integration.fish")
            guard FileManager.default.fileExists(atPath: script.path) else {
                return fallback
            }
            let existingDataDirectories = environment["XDG_DATA_DIRS"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let dataDirectories = [fishDataDirectory.path, existingDataDirectories]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: ":")
            return TerminalShellLaunchConfiguration(
                argumentZero: "-fish",
                arguments: ["-i"],
                environment: ["XDG_DATA_DIRS": dataDirectories],
                environmentKeysToUnset: [],
                automaticallyInjectsCommandBoundaries: true
            )
        default:
            return fallback
        }
    }
}
