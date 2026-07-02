import Foundation

struct TerminalCommandHistoryNavigator: Equatable {
    private let spans: [TerminalCommandSpan]

    init(spans: [TerminalCommandSpan]) {
        self.spans = spans
    }

    func latest() -> TerminalCommandSpan? {
        spans.last
    }

    func previous(from spanID: TerminalCommandSpan.ID) -> TerminalCommandSpan? {
        guard let index = spans.firstIndex(where: { $0.id == spanID }),
              index > spans.startIndex
        else {
            return nil
        }

        return spans[spans.index(before: index)]
    }

    func next(from spanID: TerminalCommandSpan.ID) -> TerminalCommandSpan? {
        guard let index = spans.firstIndex(where: { $0.id == spanID }) else {
            return nil
        }

        let nextIndex = spans.index(after: index)
        guard nextIndex < spans.endIndex else {
            return nil
        }

        return spans[nextIndex]
    }

    func search(
        cwd: String? = nil,
        exitCode: Int? = nil,
        text: String? = nil
    ) -> [TerminalCommandSpan] {
        spans.filter { span in
            if let cwd, span.cwd != cwd {
                return false
            }
            if let exitCode, span.exitCode != exitCode {
                return false
            }
            if let text {
                guard let commandText = span.commandText else {
                    return false
                }
                return commandText.localizedCaseInsensitiveContains(text)
            }
            return true
        }
    }
}

struct TerminalCommandOutputFoldState: Equatable {
    private var collapsedSpanIDs: Set<TerminalCommandSpan.ID>

    init(collapsedSpanIDs: Set<TerminalCommandSpan.ID> = []) {
        self.collapsedSpanIDs = collapsedSpanIDs
    }

    func isCollapsed(spanID: TerminalCommandSpan.ID) -> Bool {
        collapsedSpanIDs.contains(spanID)
    }

    func isExpanded(spanID: TerminalCommandSpan.ID) -> Bool {
        !isCollapsed(spanID: spanID)
    }

    mutating func collapse(spanID: TerminalCommandSpan.ID) {
        collapsedSpanIDs.insert(spanID)
    }

    mutating func expand(spanID: TerminalCommandSpan.ID) {
        collapsedSpanIDs.remove(spanID)
    }

    mutating func toggle(spanID: TerminalCommandSpan.ID) {
        if isCollapsed(spanID: spanID) {
            expand(spanID: spanID)
        } else {
            collapse(spanID: spanID)
        }
    }
}
