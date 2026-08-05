import Foundation

/// Daily token totals over a trailing window, built from the session records
/// the index already holds.
///
/// A session is credited to the day it was last updated. That is deliberately
/// coarse: the per-message timestamps exist, but attributing a long session
/// across midnight would cost a full re-read of every transcript to move a bar
/// by a few percent.
struct AgentTokenUsageSummary: Equatable, Sendable {
    struct Day: Equatable, Sendable {
        let date: Date
        let totalTokens: Int
    }

    /// Oldest first, one entry per day in the window, including days with none.
    let days: [Day]
    /// Totals for the most recent day in the window.
    let today: AgentTokenUsage
    /// Totals across the whole window.
    let window: AgentTokenUsage
    let sessionCount: Int

    var peakDayTokens: Int {
        days.map(\.totalTokens).max() ?? 0
    }

    static let empty = AgentTokenUsageSummary(
        days: [],
        today: .zero,
        window: .zero,
        sessionCount: 0
    )

    /// - Parameters:
    ///   - records: sessions to aggregate; any agent, any project.
    ///   - dayCount: how many days the strip covers, ending on `now`.
    static func make(
        records: [AgentSessionRecord],
        now: Date,
        dayCount: Int = 14,
        calendar: Calendar = .current
    ) -> AgentTokenUsageSummary {
        guard dayCount > 0 else { return .empty }
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) else {
            return .empty
        }

        var totalsByDay: [Date: Int] = [:]
        var todayUsage = AgentTokenUsage.zero
        var windowUsage = AgentTokenUsage.zero
        var sessionCount = 0

        for record in records where !record.tokenUsage.isEmpty {
            let day = calendar.startOfDay(for: record.updatedAt)
            guard day >= windowStart, day <= today else { continue }
            totalsByDay[day, default: 0] += record.tokenUsage.totalTokens
            windowUsage = windowUsage + record.tokenUsage
            if day == today {
                todayUsage = todayUsage + record.tokenUsage
            }
            sessionCount += 1
        }

        let days = (0..<dayCount).compactMap { offset -> Day? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: windowStart) else {
                return nil
            }
            return Day(date: date, totalTokens: totalsByDay[date] ?? 0)
        }

        return AgentTokenUsageSummary(
            days: days,
            today: todayUsage,
            window: windowUsage,
            sessionCount: sessionCount
        )
    }
}
