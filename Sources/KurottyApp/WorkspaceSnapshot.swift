import Foundation

struct WorkspaceSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var windows: [WorkspaceWindowSnapshot]
    var activeWindowID: WorkspaceWindowSnapshot.ID?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        windows: [WorkspaceWindowSnapshot],
        activeWindowID: WorkspaceWindowSnapshot.ID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.windows = windows
        self.activeWindowID = activeWindowID
    }

    var unsafeCommandReplayPaneIDs: [WorkspacePaneSnapshot.ID] {
        windows.flatMap(\.unsafeCommandReplayPaneIDs)
    }
}

struct WorkspaceWindowSnapshot: Codable, Equatable {
    struct ID: RawRepresentable, Codable, Equatable, Hashable, ExpressibleByStringLiteral {
        var rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        init(stringLiteral value: StringLiteralType) {
            rawValue = value
        }
    }

    var id: ID
    var title: String?
    var frame: WorkspaceWindowFrameSnapshot?
    var tabs: [WorkspaceTabSnapshot]
    var activeTabID: WorkspaceTabSnapshot.ID?

    init(
        id: ID,
        title: String? = nil,
        frame: WorkspaceWindowFrameSnapshot? = nil,
        tabs: [WorkspaceTabSnapshot],
        activeTabID: WorkspaceTabSnapshot.ID? = nil
    ) {
        self.id = id
        self.title = title
        self.frame = frame
        self.tabs = tabs
        self.activeTabID = activeTabID
    }

    var unsafeCommandReplayPaneIDs: [WorkspacePaneSnapshot.ID] {
        tabs.flatMap(\.unsafeCommandReplayPaneIDs)
    }
}

struct WorkspaceWindowFrameSnapshot: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

struct WorkspaceTabSnapshot: Codable, Equatable {
    struct ID: RawRepresentable, Codable, Equatable, Hashable, ExpressibleByStringLiteral {
        var rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        init(stringLiteral value: StringLiteralType) {
            rawValue = value
        }
    }

    var id: ID
    var title: String?
    var root: WorkspaceSplitTreeSnapshot
    var activePaneID: WorkspacePaneSnapshot.ID?

    init(
        id: ID,
        title: String? = nil,
        root: WorkspaceSplitTreeSnapshot,
        activePaneID: WorkspacePaneSnapshot.ID? = nil
    ) {
        self.id = id
        self.title = title
        self.root = root
        self.activePaneID = activePaneID
    }

    var unsafeCommandReplayPaneIDs: [WorkspacePaneSnapshot.ID] {
        root.unsafeCommandReplayPaneIDs
    }
}

enum WorkspaceSplitTreeSnapshot: Codable, Equatable {
    case pane(WorkspacePaneSnapshot)
    case split(WorkspaceSplitSnapshot)

    private enum CodingKeys: String, CodingKey {
        case kind
        case pane
        case split
    }

    private enum Kind: String, Codable {
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .pane:
            self = .pane(try container.decode(WorkspacePaneSnapshot.self, forKey: .pane))
        case .split:
            self = .split(try container.decode(WorkspaceSplitSnapshot.self, forKey: .split))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(pane):
            try container.encode(Kind.pane, forKey: .kind)
            try container.encode(pane, forKey: .pane)
        case let .split(split):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(split, forKey: .split)
        }
    }

    var paneIDs: [WorkspacePaneSnapshot.ID] {
        switch self {
        case let .pane(pane):
            return [pane.id]
        case let .split(split):
            return split.children.flatMap(\.paneIDs)
        }
    }

    var unsafeCommandReplayPaneIDs: [WorkspacePaneSnapshot.ID] {
        switch self {
        case let .pane(pane):
            return pane.restoreSafety.commandReplayRisk == .none ? [] : [pane.id]
        case let .split(split):
            return split.children.flatMap(\.unsafeCommandReplayPaneIDs)
        }
    }
}

struct WorkspaceSplitSnapshot: Codable, Equatable {
    struct ID: RawRepresentable, Codable, Equatable, Hashable, ExpressibleByStringLiteral {
        var rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        init(stringLiteral value: StringLiteralType) {
            rawValue = value
        }
    }

    var id: ID
    var axis: WorkspaceSplitAxis
    var children: [WorkspaceSplitTreeSnapshot]
    var proportions: [Double]?

    init(
        id: ID,
        axis: WorkspaceSplitAxis,
        children: [WorkspaceSplitTreeSnapshot],
        proportions: [Double]? = nil
    ) {
        self.id = id
        self.axis = axis
        self.children = children
        self.proportions = proportions
    }
}

enum WorkspaceSplitAxis: String, Codable, Equatable {
    case horizontal
    case vertical
}

struct WorkspacePaneSnapshot: Codable, Equatable {
    struct ID: RawRepresentable, Codable, Equatable, Hashable, ExpressibleByStringLiteral {
        var rawValue: String

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        init(stringLiteral value: StringLiteralType) {
            rawValue = value
        }
    }

    var id: ID
    var title: String?
    var workingDirectory: String?
    var profileName: String?
    var restoreSafety: TerminalRestoreSafetyMetadata

    init(
        id: ID,
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

struct TerminalRestoreSafetyMetadata: Codable, Equatable {
    static let layoutOnly = TerminalRestoreSafetyMetadata(
        commandLine: nil,
        commandReplay: .disabled,
        capturedAtPromptBoundary: false
    )

    var commandLine: String?
    var commandReplay: TerminalCommandReplayPolicy
    var capturedAtPromptBoundary: Bool

    init(
        commandLine: String?,
        commandReplay: TerminalCommandReplayPolicy,
        capturedAtPromptBoundary: Bool
    ) {
        self.commandLine = commandLine
        self.commandReplay = commandReplay
        self.capturedAtPromptBoundary = capturedAtPromptBoundary
    }

    var allowsAutomaticProcessRestore: Bool {
        false
    }

    var commandReplayRisk: TerminalCommandReplayRisk {
        guard commandLine?.isEmpty == false else {
            return .none
        }
        guard commandReplay == .optedIn else {
            return commandReplay == .disabled ? .none : .requiresExplicitOptIn
        }
        return capturedAtPromptBoundary ? .none : .unsafePromptState
    }
}

enum TerminalCommandReplayPolicy: String, Codable, Equatable {
    case disabled
    case requiresExplicitOptIn
    case optedIn
}

enum TerminalCommandReplayRisk: String, Codable, Equatable {
    case none
    case requiresExplicitOptIn
    case unsafePromptState
}
