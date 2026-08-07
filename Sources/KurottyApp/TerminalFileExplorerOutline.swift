import AppKit

/// Tree-side collaborators of `TerminalFileExplorerPanelView`: the callback
/// surface, the outline item wrapper that keeps `NSOutlineView` identity
/// stable, and the coalesced root-directory watcher. Extracted from the panel
/// view so the view file owns presentation only.

// MARK: - Callbacks

struct TerminalFileExplorerCallbacks {
    var openFile: (URL) -> Void
    var insertPath: (String) -> Void

    init(
        openFile: @escaping (URL) -> Void = { _ in },
        insertPath: @escaping (String) -> Void = { _ in }
    ) {
        self.openFile = openFile
        self.insertPath = insertPath
    }
}

// MARK: - Outline view

/// Outline that hands Finder's two entry shortcuts to the panel.
///
/// `NSOutlineView` routes neither on its own, and a key equivalent on a
/// contextual menu item only fires while that menu is open — so the item still
/// carries one, for the shortcut to be visible where the action is, but the
/// working binding is read off the key event here.
@MainActor
final class TerminalFileExplorerOutlineView: NSOutlineView {
    /// Return, as Finder renames.
    var onRenameKey: (() -> Void)?
    /// Command-Delete, as Finder trashes. Bare Delete is deliberately not
    /// bound: this list sits beside a terminal and takes focus on a click, and
    /// a single unmodified keystroke is too small a gesture for a delete.
    var onTrashKey: (() -> Void)?
    /// `/` jumps to the panel's search field, as it does in the history list.
    /// The badge in the field advertises the same key in both panels.
    var onFilterKey: (() -> Void)?

    /// Tint for the disclosure chevron, kept in step with the panel's theme.
    var disclosureTintColor: NSColor = DesignTokens.ChromeTheme.dark.textTertiary {
        didSet {
            guard disclosureTintColor != oldValue else { return }
            reloadData()
        }
    }

    /// AppKit's stock disclosure triangle is a filled system triangle drawn in
    /// a system colour, so it ignores the chrome ramp entirely -- on a themed
    /// panel it lands somewhere between invisible and wrong. The history list
    /// already replaces it with a quiet chevron; this is the same substitution,
    /// so both sidebars disclose the same way.
    override func makeView(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        owner: Any?
    ) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        guard identifier == NSOutlineView.disclosureButtonIdentifier,
              let button = view as? NSButton
        else {
            return view
        }
        let pointSizePT = DesignTokens.Component.commandHistoryDisclosurePointSizePT
        button.image = Icon.symbol(
            IconSymbol.disclosureCollapsed,
            pointSizePT: pointSizePT,
            weight: .semibold,
            tint: disclosureTintColor
        )
        button.alternateImage = Icon.symbol(
            IconSymbol.disclosureExpanded,
            pointSizePT: pointSizePT,
            weight: .semibold,
            tint: disclosureTintColor
        )
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = disclosureTintColor
        let boxSize = DesignTokens.Component.commandHistoryDisclosureBoxSizePX
        button.frame = NSRect(
            origin: button.frame.origin,
            size: NSSize(width: boxSize, height: boxSize)
        )
        return button
    }

    private static let returnCharacter: Character = "\r"
    private static let enterCharacter = Character(UnicodeScalar(NSEnterCharacter)!)
    private static let deleteCharacter = Character(UnicodeScalar(NSDeleteCharacter)!)

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let character = event.charactersIgnoringModifiers?.first else {
            super.keyDown(with: event)
            return
        }
        if modifiers.isEmpty,
           character == Self.returnCharacter || character == Self.enterCharacter,
           let onRenameKey {
            onRenameKey()
            return
        }
        if modifiers == .command, character == Self.deleteCharacter, let onTrashKey {
            onTrashKey()
            return
        }
        if TerminalSidebarFilterKey.matches(event), let onFilterKey {
            onFilterKey()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Outline item

/// Reference wrapper around `FileExplorerNode` so `NSOutlineView` keeps stable
/// item identity (and expansion state) across refreshes. Children are listed
/// lazily on first expansion; refresh re-lists only already-loaded subtrees.
@MainActor
final class TerminalFileExplorerOutlineItem {
    let node: FileExplorerNode
    /// Non-nil only for flat filter-result rows.
    let filterDisplayPath: String?
    private(set) var loadedChildItems: [TerminalFileExplorerOutlineItem]?

    init(node: FileExplorerNode, filterDisplayPath: String? = nil) {
        self.node = node
        self.filterDisplayPath = filterDisplayPath
    }

    var isExpandable: Bool {
        filterDisplayPath == nil && node.kind == .directory && !node.isGitDirectory
    }

    func childItems() -> [TerminalFileExplorerOutlineItem] {
        if let loadedChildItems {
            return loadedChildItems
        }
        let children = FileExplorerDirectoryLister.listChildren(of: node.url)
            .map { TerminalFileExplorerOutlineItem(node: $0) }
        loadedChildItems = children
        return children
    }

    /// The items from this one down to `pathComponents`, one per component,
    /// listing each directory on the way. Empty when any component is missing,
    /// which is the ordinary answer for a path that went away.
    ///
    /// Used to walk to an entry the panel just created: every item but the last
    /// has to be expanded for the new row to be on screen at all.
    func chain(toPathComponents pathComponents: ArraySlice<String>) -> [TerminalFileExplorerOutlineItem] {
        var chain: [TerminalFileExplorerOutlineItem] = []
        var current = self
        for component in pathComponents {
            guard let child = current.childItems().first(where: { $0.node.name == component }) else {
                return []
            }
            chain.append(child)
            current = child
        }
        return chain
    }

    /// Re-lists every already-loaded directory, reusing existing item objects
    /// for unchanged paths so outline expansion state survives reloads.
    /// Never loads directories the user has not expanded.
    func refreshLoadedSubtree() {
        guard let existingChildren = loadedChildItems else {
            return
        }
        var existingByPath: [String: TerminalFileExplorerOutlineItem] = [:]
        for child in existingChildren {
            existingByPath[child.node.url.path] = child
        }
        loadedChildItems = FileExplorerDirectoryLister.listChildren(of: node.url).map { node in
            guard let reused = existingByPath[node.url.path], reused.node == node else {
                return TerminalFileExplorerOutlineItem(node: node)
            }
            reused.refreshLoadedSubtree()
            return reused
        }
    }
}

// MARK: - Root watcher

/// Coalesced `DispatchSource` watcher on the panel's root directory. The
/// source is scheduled on the main queue, so its handlers run on the main
/// actor; changes are debounced before invoking `onChange`.
@MainActor
final class TerminalFileExplorerRootWatcher {
    private let source: DispatchSourceFileSystemObject
    private var pendingChange: DispatchWorkItem?
    private let onChange: () -> Void

    init?(directoryURL: URL, onChange: @escaping () -> Void) {
        let fileDescriptor = open(directoryURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return nil
        }
        self.onChange = onChange
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .link],
            queue: .main
        )
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.setEventHandler { [weak self] in
            // Safe: this source is scheduled on DispatchQueue.main, so the
            // event handler always executes on the main actor.
            MainActor.assumeIsolated {
                self?.scheduleCoalescedChange()
            }
        }
        source.resume()
    }

    deinit {
        // The pending debounce work item only holds `self` weakly, so it
        // no-ops after deallocation; cancelling the source closes the fd.
        source.cancel()
    }

    func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        source.cancel()
    }

    private func scheduleCoalescedChange() {
        pendingChange?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            // Safe: the work item is enqueued on DispatchQueue.main below.
            MainActor.assumeIsolated {
                self?.onChange()
            }
        }
        pendingChange = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(AppConstants.FileExplorer.watcherDebounceMS),
            execute: workItem
        )
    }
}
