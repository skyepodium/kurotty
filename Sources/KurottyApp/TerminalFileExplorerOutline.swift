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
