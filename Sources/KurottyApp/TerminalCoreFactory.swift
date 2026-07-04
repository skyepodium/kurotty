import KurottyCore

enum TerminalCoreFactory {
    static func makeDefaultCore(cols: UInt32, rows: UInt32) -> any TerminalCore {
        CoreBridge(cols: cols, rows: rows)
    }

    static func compatibilityDiagnostic(for core: any TerminalCore) -> TerminalCoreCompatibilityDiagnostic {
        guard let diagnosticCore = core as? TerminalCoreCompatibilityDiagnosing else {
            return TerminalCoreCompatibilityDiagnostic(
                bridge: .unknown,
                pty: .unknown,
                parser: .unknown,
                screen: .unknown,
                render: .unknown
            )
        }
        return diagnosticCore.compatibilityDiagnostic
    }

    static func mutationSourceDiagnostic(for core: any TerminalCore) -> TerminalCoreMutationSourceDiagnostic {
        guard let diagnosticCore = core as? TerminalCoreMutationSourceDiagnosing else {
            return TerminalCoreMutationSourceDiagnostic(
                sessionMutationOwner: .unknown,
                frameMutationOwner: .unknown,
                zigBridgeActive: false,
                reason: "diagnostic-unavailable"
            )
        }
        return diagnosticCore.mutationSourceDiagnostic
    }

    static func runtimeBoundaryDiagnostic(for core: any TerminalCore) -> TerminalCoreRuntimeBoundaryDiagnostic {
        guard let diagnosticCore = core as? TerminalCoreRuntimeBoundaryDiagnosing else {
            return TerminalCoreRuntimeBoundaryDiagnostic(
                feedBridgeParticipant: .unknown,
                parserMutationOwner: .unknown,
                screenMutationOwner: .unknown,
                renderMutationOwner: .unknown,
                mutationHandoffReady: false,
                dualWriteRisk: .unknown,
                reason: "diagnostic-unavailable"
            )
        }
        return diagnosticCore.runtimeBoundaryDiagnostic
    }
}
