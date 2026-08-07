import AppKit

/// Project file palette integration for the terminal window.
///
/// The palette needs three things from the window and nothing else: where to
/// scan, where to put a path, and how to open a file. Each already exists for
/// the file explorer, so this file is wiring rather than mechanism.
extension TerminalWindowController {
    func openProjectFilePalette() {
        // Scanning the home directory would walk every project the user owns
        // plus their whole Library, which is not a "project" by any reading —
        // so the palette needs a pane with a working directory and does nothing
        // without one.
        guard let rootDirectory = projectFilePaletteRootDirectory() else {
            return
        }

        let controller = ProjectFileQuickOpenWindowController(
            rootDirectory: rootDirectory,
            language: AppLocalization.language,
            chromeTheme: chromeTheme,
            insertPathHandler: { [weak self] path in
                self?.insertFileExplorerPathIntoActiveTerminal(path)
            },
            openFileHandler: { [weak self] url in
                self?.openEditorTab(for: url)
            }
        )
        projectFilePaletteController = controller
        controller.showWindow(nil)
    }

    /// The active pane's working directory, or `nil` when there is no local
    /// one. A remote pane is excluded deliberately: its OSC 7 path names a
    /// directory on the far host, and scanning the identically-named local path
    /// would answer a question nobody asked.
    private func projectFilePaletteRootDirectory() -> URL? {
        guard let surface = currentSplitView()?.activeTerminalSurface() else {
            return nil
        }
        let location = surface.workingDirectoryLocation
        guard !location.isRemote, !location.path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: location.path, isDirectory: true)
    }
}
