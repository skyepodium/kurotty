import AppKit

/// Where the running app bundle sits, and whether that location will keep it
/// from updating itself.
///
/// Sparkle refuses to update an app running from a read-only volume or a
/// temporary path, and its only guidance is "use Finder to copy it to the
/// Applications folder". The app can do that itself when the bundle is merely
/// read-only — a mounted DMG is still readable — so the decision is split from
/// the AppKit work: `verdict(for:)` is pure and testable, and
/// `AppInstallLocationPrompt` owns the alert, the copy, and the relaunch.
enum AppInstallLocation {
    enum Verdict: Equatable {
        /// The bundle can update itself where it is.
        case installed
        /// A read-only volume, typically the DMG the release ships in. The app
        /// can copy itself out of here.
        case readOnlyVolume
        /// Gatekeeper's randomized read-only mount. The bundle the user sees in
        /// Finder is somewhere else entirely, so copying *this* path would
        /// install the translocated copy rather than the real download.
        case translocated
        /// A temporary directory that the system may clear at any point.
        case temporary

        /// Whether the app can fix this itself by copying the bundle.
        var isSelfCorrectable: Bool {
            switch self {
            case .readOnlyVolume, .temporary: true
            case .installed, .translocated: false
            }
        }
    }

    /// Directories an installed app legitimately runs from.
    static let installedPrefixes = ["/Applications", "/System/Applications"]

    /// Paths the system hands out for temporary or randomized copies.
    private static let translocationMarker = "/AppTranslocation/"
    private static let temporaryPrefixes = ["/private/var/folders/", "/private/tmp/", "/tmp/"]

    /// - Parameters:
    ///   - bundlePath: the running bundle's path.
    ///   - homeDirectoryPath: used to accept a per-user `~/Applications` install.
    ///   - isVolumeReadOnly: whether the volume holding the bundle rejects writes.
    static func verdict(
        bundlePath: String,
        homeDirectoryPath: String,
        isVolumeReadOnly: Bool
    ) -> Verdict {
        // Translocation is checked before anything else: a translocated bundle
        // is also read-only, and reporting it as merely read-only would offer a
        // copy that installs the wrong thing.
        if bundlePath.contains(translocationMarker) {
            return .translocated
        }

        let installedRoots = installedPrefixes + ["\(homeDirectoryPath)/Applications"]
        if installedRoots.contains(where: { bundlePath == $0 || bundlePath.hasPrefix("\($0)/") }) {
            return .installed
        }

        if isVolumeReadOnly {
            return .readOnlyVolume
        }

        if temporaryPrefixes.contains(where: { bundlePath.hasPrefix($0) }) {
            return .temporary
        }

        return .installed
    }

    /// Reads the read-only flag off the volume holding `url`. Treated as
    /// writable when the value is unavailable, so an unreadable resource value
    /// can never turn into an unsolicited move prompt.
    static func isVolumeReadOnly(for url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly ?? false
    }

    static func verdictForRunningBundle(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectoryPath: String = NSHomeDirectory()
    ) -> Verdict {
        verdict(
            bundlePath: bundleURL.resolvingSymlinksInPath().path,
            homeDirectoryPath: homeDirectoryPath,
            isVolumeReadOnly: isVolumeReadOnly(for: bundleURL)
        )
    }
}

/// Offers to move the bundle into `/Applications` when it is running somewhere
/// that blocks updates, then relaunches from the new copy.
@MainActor
enum AppInstallLocationPrompt {
    /// Runs the whole check. A no-op when the app is already installed.
    static func presentIfNeeded(
        verdict: AppInstallLocation.Verdict = AppInstallLocation.verdictForRunningBundle(),
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        switch verdict {
        case .installed:
            return
        case .translocated:
            presentTranslocatedAlert()
        case .readOnlyVolume, .temporary:
            presentMoveOffer(bundleURL: bundleURL)
        }
    }

    private static func presentMoveOffer(bundleURL: URL) {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.moveToApplicationsTitle)
        alert.informativeText = AppLocalization.format(
            .moveToApplicationsMessage,
            AppConstants.Bundle.displayName
        )
        alert.addButton(withTitle: AppLocalization.string(.moveToApplications))
        alert.addButton(withTitle: AppLocalization.string(.moveToApplicationsLater))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let destination = try moveToApplications(bundleURL: bundleURL)
            relaunch(from: destination)
        } catch {
            presentFailureAlert(error)
        }
    }

    /// Copies the bundle into `/Applications`, replacing an older copy. The
    /// source may be read-only — that is the case this exists for — so this
    /// copies and never moves.
    static func moveToApplications(
        bundleURL: URL,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = applicationsDirectory
            .appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: bundleURL)
            return destination
        }
        try fileManager.copyItem(at: bundleURL, to: destination)
        return destination
    }

    private static func relaunch(from destination: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    private static func presentTranslocatedAlert() {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.moveToApplicationsTitle)
        alert.informativeText = AppLocalization.format(
            .translocatedMessage,
            AppConstants.Bundle.displayName
        )
        alert.addButton(withTitle: AppLocalization.string(.ok))
        alert.runModal()
    }

    private static func presentFailureAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = AppLocalization.string(.moveToApplicationsFailedTitle)
        alert.informativeText = AppLocalization.format(
            .moveToApplicationsFailedMessage,
            error.localizedDescription
        )
        alert.addButton(withTitle: AppLocalization.string(.ok))
        alert.runModal()
    }
}
