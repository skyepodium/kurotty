import XCTest
@testable import KurottyApp

final class TerminalTabGroupTests: XCTestCase {
    func testCreatingAGroupKeepsTheCurrentTabVisible() {
        var state = TerminalTabGroupState()

        let group = state.createGroup(containing: "tab-2", preferredName: "Build")

        XCTAssertEqual(group.name, "Build")
        XCTAssertEqual(
            state.visibleItems(for: ["tab-1", "tab-2", "tab-3"], activeTabID: "tab-2"),
            [.tab(id: "tab-1"), .groupHeader(group), .tab(id: "tab-2"), .tab(id: "tab-3")]
        )
    }

    func testGroupedTabsAreOrderedContiguously() {
        var state = TerminalTabGroupState()
        let group = state.createGroup(containing: "tab-1")
        state.add(tabID: "tab-3", to: group.id)

        XCTAssertEqual(
            state.orderedTabIDs(for: ["tab-1", "tab-2", "tab-3", "tab-4"]),
            ["tab-1", "tab-3", "tab-2", "tab-4"]
        )
    }

    func testCollapsedGroupKeepsActiveMemberVisible() {
        var state = TerminalTabGroupState()
        let group = state.createGroup(containing: "tab-1", preferredName: "Servers")
        state.add(tabID: "tab-2", to: group.id)
        state.toggleCollapsed(groupID: group.id, activeTabID: "tab-2")

        let header = try? XCTUnwrap(state.group(containing: "tab-1"))
        XCTAssertEqual(
            state.visibleItems(for: ["tab-1", "tab-2", "tab-3"], activeTabID: "tab-2"),
            [.groupHeader(header!), .tab(id: "tab-2"), .tab(id: "tab-3")]
        )
    }

    func testRemovingTabsPrunesEmptyGroups() {
        var state = TerminalTabGroupState()
        _ = state.createGroup(containing: "tab-1")

        state.removeMissingTabs(keeping: ["tab-2"])

        XCTAssertFalse(state.hasGroups)
        XCTAssertEqual(state.visibleItems(for: ["tab-2"], activeTabID: "tab-2"), [.tab(id: "tab-2")])
    }
}
