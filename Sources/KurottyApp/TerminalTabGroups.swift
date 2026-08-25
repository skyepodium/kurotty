import AppKit

struct TerminalTabGroup: Equatable {
    let id: String
    var name: String
    var colorIndex: Int
    var tabIDs: [String]
    var isCollapsed: Bool
}

enum TerminalTabBarItem: Equatable {
    case groupHeader(TerminalTabGroup)
    case tab(id: String)
}

struct TerminalTabGroupState: Equatable {
    private(set) var groups: [TerminalTabGroup] = []
    private var nextGroupNumber = 1

    var hasGroups: Bool { !groups.isEmpty }

    func group(containing tabID: String) -> TerminalTabGroup? {
        groups.first { $0.tabIDs.contains(tabID) }
    }

    mutating func createGroup(containing tabID: String, preferredName: String? = nil) -> TerminalTabGroup {
        remove(tabID: tabID)
        let number = nextGroupNumber
        nextGroupNumber += 1
        let group = TerminalTabGroup(
            id: UUID().uuidString,
            name: preferredName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Group \(number)",
            colorIndex: (number - 1) % TerminalTabGroupPalette.colorCount,
            tabIDs: [tabID],
            isCollapsed: false
        )
        groups.append(group)
        return group
    }

    mutating func add(tabID: String, to groupID: String) {
        remove(tabID: tabID)
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].tabIDs.append(tabID)
    }

    mutating func remove(tabID: String) {
        for index in groups.indices {
            groups[index].tabIDs.removeAll { $0 == tabID }
        }
        groups.removeAll { $0.tabIDs.isEmpty }
    }

    mutating func removeMissingTabs(keeping tabIDsInOrder: [String]) {
        let liveIDs = Set(tabIDsInOrder)
        for index in groups.indices {
            groups[index].tabIDs.removeAll { !liveIDs.contains($0) }
        }
        groups.removeAll { $0.tabIDs.isEmpty }
    }

    mutating func toggleCollapsed(groupID: String, activeTabID: String?) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].isCollapsed.toggle()
    }

    func orderedTabIDs(for tabIDsInOrder: [String]) -> [String] {
        let liveIDs = Set(tabIDsInOrder)
        let groupedIDs = Set(groups.flatMap(\.tabIDs))
        var emittedGroups: Set<String> = []
        var ordered: [String] = []

        for tabID in tabIDsInOrder {
            guard liveIDs.contains(tabID) else { continue }
            guard let group = group(containing: tabID) else {
                if !groupedIDs.contains(tabID) {
                    ordered.append(tabID)
                }
                continue
            }
            guard !emittedGroups.contains(group.id) else { continue }
            emittedGroups.insert(group.id)
            ordered.append(contentsOf: group.tabIDs.filter { liveIDs.contains($0) })
        }

        return ordered
    }

    func visibleItems(for tabIDsInOrder: [String], activeTabID: String?) -> [TerminalTabBarItem] {
        let orderedIDs = orderedTabIDs(for: tabIDsInOrder)
        var emittedGroups: Set<String> = []
        var items: [TerminalTabBarItem] = []

        for tabID in orderedIDs {
            guard let group = group(containing: tabID) else {
                items.append(.tab(id: tabID))
                continue
            }
            if !emittedGroups.contains(group.id) {
                emittedGroups.insert(group.id)
                items.append(.groupHeader(group))
                if group.isCollapsed {
                    let visibleMember = activeTabID.flatMap { group.tabIDs.contains($0) ? $0 : nil }
                        ?? group.tabIDs.first
                    if let visibleMember {
                        items.append(.tab(id: visibleMember))
                    }
                    continue
                }
            }
            guard !group.isCollapsed else { continue }
            items.append(.tab(id: tabID))
        }

        return items
    }
}

enum TerminalTabGroupPalette {
    static let colorCount = 6

    @MainActor
    static func color(for group: TerminalTabGroup, theme: DesignTokens.ChromeTheme) -> NSColor {
        switch group.colorIndex % colorCount {
        case 0:
            return theme.activeIndicator
        case 1:
            return theme.success
        case 2:
            return theme.warning
        case 3:
            return theme.error
        case 4:
            return theme.textSecondary
        default:
            return theme.focusRing
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
