import AppKit

/// Bottom status bar integration for the terminal window.
///
/// The bar is mounted in `TerminalWindowController.configureTabs(initialPane:)`
/// and owns the bottom strip: the sidebar split view is pinned to its
/// `topAnchor`, so a collapsed bar returns every point to the terminal content.
/// Everything the bar needs is pulled through `TerminalStatusBarDataSource`;
/// the bar never reaches into this controller's view tree.
///
/// Extracted from `TerminalWindowController` to keep the controller focused on
/// tab/window behavior, matching the command-history and file-explorer splits.
extension TerminalWindowController {
    // MARK: - Refresh seams

    /// The bar reads its panes through the data source, so every place that
    /// adds, removes, splits, or selects a pane has to tell it to re-read.
    /// Re-reading also resets CPU delta state, so a pane change cannot leave a
    /// stale percentage attached to a new process.
    func refreshStatusBarPanes() {
        statusBarView.refreshPanes()
    }

    /// Pane focus only changes which pane's agent status the left segment
    /// shows; the sampled pane set is unchanged, so this deliberately does not
    /// reset the sampler.
    func observePaneFocus() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paneFocusDidChange(_:)),
            name: TerminalSurfaceView.focusDidChangeNotification,
            object: nil
        )
    }

    @objc func paneFocusDidChange(_ notification: Notification) {
        statusBarView.refreshAgentSegment()
    }

    // MARK: - Window lifecycle

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        statusBarView.startSampling()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        statusBarView.startSampling()
    }

    func windowWillClose(_ notification: Notification) {
        statusBarView.stopSampling()
    }

    /// Sampling costs one `libproc` walk per pane subtree, so a fully occluded
    /// or miniaturized window must re-evaluate the gate instead of paying for
    /// numbers nobody can read.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        statusBarView.windowVisibilityDidChange()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        statusBarView.windowVisibilityDidChange()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        statusBarView.windowVisibilityDidChange()
    }
}

// MARK: - Data source

extension TerminalWindowController: TerminalStatusBarDataSource {
    func statusBarPaneDescriptors() -> [TerminalStatusBarPaneDescriptor] {
        currentSplitView()?.statusBarPaneDescriptors() ?? []
    }

    func statusBarActivePaneIdentifier() -> String? {
        currentSplitView()?.activeStatusBarPaneIdentifier()
    }

    func statusBarSamplingContext() -> TerminalStatusBarSamplingContext {
        // A miniaturized window reports `isVisible == false`, and a window
        // fully covered by another one drops `.visible` from its occlusion
        // state; both must stop the sampler.
        let isWindowVisible = window?.isVisible ?? false
        let isWindowOccluded = !(window?.occlusionState.contains(.visible) ?? false)
        return TerminalStatusBarSamplingContext(
            isWindowVisible: isWindowVisible,
            isWindowOccluded: isWindowOccluded,
            paneCount: statusBarPaneDescriptors().count,
            isStatusBarVisible: statusBarView.isEnabled
        )
    }

    /// Insert only. The bar has no execute path at all, so the text lands on
    /// the prompt without a trailing newline and the user presses Return.
    func statusBarInsertText(_ text: String, paneIdentifier: String) {
        sendTextToActivePane(text)
        currentSplitView()?.focusFirstPane()
    }

    func statusBarOpenPreferences() {
        NSApp.sendAction(#selector(AppDelegate.openPreferences), to: nil, from: nil)
    }
}
