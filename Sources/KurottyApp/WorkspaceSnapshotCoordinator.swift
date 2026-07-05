import Foundation

struct WorkspaceSnapshotCoordinator {
    struct WorkspaceDescriptor: Equatable {
        var windows: [WindowDescriptor]
        var activeWindowID: String?

        init(
            windows: [WindowDescriptor],
            activeWindowID: String? = nil
        ) {
            self.windows = windows
            self.activeWindowID = activeWindowID
        }
    }

    struct WindowDescriptor: Equatable {
        var id: String
        var title: String?
        var frame: WorkspaceWindowFrameSnapshot?
        var tabs: [TabDescriptor]
        var activeTabID: String?

        init(
            id: String,
            title: String? = nil,
            frame: WorkspaceWindowFrameSnapshot? = nil,
            tabs: [TabDescriptor],
            activeTabID: String? = nil
        ) {
            self.id = id
            self.title = title
            self.frame = frame
            self.tabs = tabs
            self.activeTabID = activeTabID
        }
    }

    struct TabDescriptor: Equatable {
        var id: String
        var title: String?
        var root: SplitTreeDescriptor
        var activePaneID: String?

        init(
            id: String,
            title: String? = nil,
            root: SplitTreeDescriptor,
            activePaneID: String? = nil
        ) {
            self.id = id
            self.title = title
            self.root = root
            self.activePaneID = activePaneID
        }
    }

    enum SplitTreeDescriptor: Equatable {
        case pane(PaneDescriptor)
        case split(SplitDescriptor)
    }

    struct SplitDescriptor: Equatable {
        var id: String
        var axis: WorkspaceSplitAxis
        var children: [SplitTreeDescriptor]
        var proportions: [Double]?

        init(
            id: String,
            axis: WorkspaceSplitAxis,
            children: [SplitTreeDescriptor],
            proportions: [Double]? = nil
        ) {
            self.id = id
            self.axis = axis
            self.children = children
            self.proportions = proportions
        }
    }

    struct PaneDescriptor: Equatable {
        var id: String
        var title: String?
        var workingDirectory: String?
        var profileName: String?
        var restoreSafety: TerminalRestoreSafetyMetadata

        init(
            id: String,
            title: String? = nil,
            workingDirectory: String? = nil,
            profileName: String? = nil,
            restoreSafety: TerminalRestoreSafetyMetadata = .layoutOnly
        ) {
            self.id = id
            self.title = title
            self.workingDirectory = workingDirectory
            self.profileName = profileName
            self.restoreSafety = restoreSafety
        }
    }

    private let store: WorkspaceSnapshotStore

    init(store: WorkspaceSnapshotStore = WorkspaceSnapshotStore()) {
        self.store = store
    }

    func makeLayoutOnlySnapshot(from descriptor: WorkspaceDescriptor) -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            windows: descriptor.windows.map(makeWindowSnapshot),
            activeWindowID: descriptor.activeWindowID.map { WorkspaceWindowSnapshot.ID($0) }
        )
    }

    func saveLayoutOnlySnapshot(
        from descriptor: WorkspaceDescriptor,
        to url: URL
    ) throws -> WorkspaceSnapshotSaveReport {
        try store.save(makeLayoutOnlySnapshot(from: descriptor), to: url)
    }

    private func makeWindowSnapshot(from descriptor: WindowDescriptor) -> WorkspaceWindowSnapshot {
        WorkspaceWindowSnapshot(
            id: WorkspaceWindowSnapshot.ID(descriptor.id),
            title: descriptor.title,
            frame: descriptor.frame,
            tabs: descriptor.tabs.map(makeTabSnapshot),
            activeTabID: descriptor.activeTabID.map { WorkspaceTabSnapshot.ID($0) }
        )
    }

    private func makeTabSnapshot(from descriptor: TabDescriptor) -> WorkspaceTabSnapshot {
        WorkspaceTabSnapshot(
            id: WorkspaceTabSnapshot.ID(descriptor.id),
            title: descriptor.title,
            root: makeSplitTreeSnapshot(from: descriptor.root),
            activePaneID: descriptor.activePaneID.map { WorkspacePaneSnapshot.ID($0) }
        )
    }

    private func makeSplitTreeSnapshot(
        from descriptor: SplitTreeDescriptor
    ) -> WorkspaceSplitTreeSnapshot {
        switch descriptor {
        case let .pane(pane):
            return .pane(makePaneSnapshot(from: pane))
        case let .split(split):
            return .split(WorkspaceSplitSnapshot(
                id: WorkspaceSplitSnapshot.ID(split.id),
                axis: split.axis,
                children: split.children.map(makeSplitTreeSnapshot),
                proportions: split.proportions
            ))
        }
    }

    private func makePaneSnapshot(from descriptor: PaneDescriptor) -> WorkspacePaneSnapshot {
        WorkspacePaneSnapshot(
            id: WorkspacePaneSnapshot.ID(descriptor.id),
            title: descriptor.title,
            workingDirectory: descriptor.workingDirectory,
            profileName: descriptor.profileName,
            restoreSafety: .layoutOnly
        )
    }
}
