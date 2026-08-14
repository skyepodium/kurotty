import Foundation

/// What has to happen to the page to turn one screen of rows into the next.
///
/// **Scrolling is rows moving, not rows changing.** When a terminal scrolls, the
/// new row *n* is the old row *n + k* — the same markup, one position up. A
/// renderer that only knows "these rows are dirty" sees every row dirty and
/// rebuilds the whole screen; a renderer that recognises the shift moves the
/// existing elements and reparses only the *k* rows that genuinely arrived.
/// Moving a node is a pointer operation in the DOM. Parsing a row is a parse, a
/// node build, and a layout box.
///
/// This is a pure function over the rendered markup, deliberately: it needs no
/// web view to test, and it cannot be fooled by damage bookkeeping, because it
/// compares what was actually put on the page against what is about to be.
enum TerminalHTMLRowDiff {
    /// A shift, plus the rows that still differ once it has been applied.
    struct Plan: Equatable {
        /// Rows the surviving content moved by. Positive moves content up, which
        /// is ordinary scrolling; negative moves it down, which is what a
        /// reverse index or a pager scrolling back produces.
        var shift: Int
        /// Indexes, in the *new* screen, whose contents must be replaced after
        /// the shift.
        var rows: [Int]
        /// The whole screen is replaced in one parse instead.
        var replacesScreen: Bool

        static let unchanged = Plan(shift: 0, rows: [], replacesScreen: false)
        static let screen = Plan(shift: 0, rows: [], replacesScreen: true)

        var isEmpty: Bool {
            shift == 0 && rows.isEmpty && !replacesScreen
        }
    }

    private enum Search {
        /// How many shift candidates are checked in full.
        ///
        /// A candidate is a position where the old screen carries the new
        /// screen's first row, and a screen with many blank rows offers many of
        /// them. Checking every one is quadratic for no gain: the real shift is
        /// among the first few, because a scroll that moved further than the
        /// screen leaves no surviving content to find.
        static let candidateCOUNT = 4
    }

    private enum Replacement {
        /// The share of a screen that makes replacing it cheaper than patching
        /// it row by row.
        ///
        /// A patched row costs its own payload across the bridge and its own
        /// parse; a replaced screen costs one of each for the whole thing. The
        /// crossover was measured rather than guessed: a TUI redraw that
        /// changed 55 of 62 rows cost 4.1-4.4ms as 55 patches and 3.05-3.12ms as
        /// one replacement, which puts the break-even near two thirds of the
        /// screen. Half is the conservative side of that.
        ///
        /// The first version of this diff had no ratio at all and replaced the
        /// screen only when *every* row changed. A repaint almost never changes
        /// every row — the bottom of the screen stays blank — so it fell off
        /// the cliff on exactly the workload it was meant to help.
        static let screenRATIO = 0.5
    }

    /// The cheapest plan that produces `new` from `old`.
    ///
    /// A screen whose row count changed is replaced outright: the page's element
    /// list has to grow or shrink, and no amount of patching does that.
    static func plan(from old: [String], to new: [String]) -> Plan {
        guard !new.isEmpty, old.count == new.count else {
            return .screen
        }

        let direct = changedRows(from: old, to: new, shift: 0)
        guard !direct.isEmpty else {
            return .unchanged
        }

        var best = Plan(shift: 0, rows: direct, replacesScreen: false)

        for shift in candidateShifts(from: old, to: new) {
            let rows = changedRows(from: old, to: new, shift: shift)
            // Strictly fewer rows to parse, or the shift was not worth its own
            // element moves.
            guard rows.count < best.rows.count else {
                continue
            }
            best = Plan(shift: shift, rows: rows, replacesScreen: false)
        }

        // Too little survived to be worth patching around.
        guard Double(best.rows.count) < Double(new.count) * Replacement.screenRATIO else {
            return .screen
        }

        return best
    }

    /// Positions at which the old screen still holds the new screen's edge row.
    ///
    /// Anchoring on a single row makes finding the shift a scan rather than a
    /// comparison of every alignment against every other. A shift whose anchor
    /// row happens to have changed is missed, and the result is the plan that
    /// was going to be produced anyway.
    private static func candidateShifts(from old: [String], to new: [String]) -> [Int] {
        var shifts: [Int] = []

        // Content moved up: the new top row is somewhere below in the old screen.
        for shift in 1..<old.count where old[shift] == new[0] {
            shifts.append(shift)
            if shifts.count == Search.candidateCOUNT {
                break
            }
        }

        // Content moved down: the old top row is somewhere below in the new one.
        var downward = 0
        for shift in 1..<new.count where new[shift] == old[0] {
            shifts.append(-shift)
            downward += 1
            if downward == Search.candidateCOUNT {
                break
            }
        }

        return shifts
    }

    /// Rows of the new screen that the shifted old screen does not already
    /// carry. A row the shift pushed off the screen has no old counterpart and
    /// always counts as changed.
    private static func changedRows(from old: [String], to new: [String], shift: Int) -> [Int] {
        var rows: [Int] = []

        for row in new.indices {
            let source = row + shift
            guard source >= 0, source < old.count, old[source] == new[row] else {
                rows.append(row)
                continue
            }
        }

        return rows
    }
}
