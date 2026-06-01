import Combine
import Foundation

/// Tracks how the user actually exercises Ghost Pepper. Counters are
/// UserDefaults-backed so they survive launches without needing a database;
/// each call appends a timestamp into a per-event date list, which lets us
/// answer both "lifetime use" and "last 7 days" without separate buckets.
///
/// Wired from AppState at the few hot paths (dictation completion, Granola
/// import, meeting recording finish, agent Q&A submission). The right-side
/// "Usage report" panel reads counts and shoves them at a local model so it
/// can write back a "spend more time on X" feature-request note.
@MainActor
final class UsageStatsStore: ObservableObject {
    enum Event: String, CaseIterable, Identifiable {
        case dictation

        var id: String { rawValue }

        /// Short label for axes/legends. Long-form descriptions live in the
        /// LLM prompt only — the chart axis can't render multiline text.
        var shortLabel: String {
            switch self {
            case .dictation: return "Dictation"
            }
        }

        /// Sentence the LLM sees so it can write a coherent feature request.
        var promptDescription: String {
            switch self {
            case .dictation: return "Voice-to-text dictation"
            }
        }
    }

    /// Reporting window the Usage report panel can flip between.
    enum Window: String, CaseIterable, Identifiable {
        case sevenDays
        case thirtyDays
        case lifetime

        var id: String { rawValue }
        var title: String {
            switch self {
            case .sevenDays: return "7 days"
            case .thirtyDays: return "30 days"
            case .lifetime: return "Lifetime"
            }
        }
        /// `nil` means lifetime (no cutoff). Otherwise the number of trailing
        /// days to include.
        var trailingDays: Int? {
            switch self {
            case .sevenDays: return 7
            case .thirtyDays: return 30
            case .lifetime: return nil
            }
        }
    }

    /// Bumped on every record so SwiftUI views observing the store re-render.
    @Published private(set) var version: Int = 0

    private let defaults: UserDefaults
    private static let storageKey = "usageStats.events.v1"

    /// Per-event timestamp lists: `[event.rawValue: [unix-seconds...]]`. We
    /// trim each list at write time so it can't grow without bound.
    private var events: [String: [TimeInterval]]

    private static let retentionDays: Int = 90
    private static let maxEventsPerKind: Int = 5_000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.dictionary(forKey: Self.storageKey) as? [String: [TimeInterval]] {
            self.events = raw
        } else {
            self.events = [:]
        }
    }

    func record(_ event: Event, count: Int = 1, at date: Date = Date()) {
        guard count > 0 else { return }
        let now = date.timeIntervalSince1970
        var list = events[event.rawValue] ?? []
        for _ in 0..<count { list.append(now) }
        list = trim(list)
        events[event.rawValue] = list
        defaults.set(events, forKey: Self.storageKey)
        version &+= 1
    }

    /// Lifetime count for one event.
    func lifetimeCount(_ event: Event) -> Int {
        events[event.rawValue]?.count ?? 0
    }

    /// Count for the trailing N days (default 7).
    func recentCount(_ event: Event, days: Int = 7, asOf reference: Date = Date()) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = reference.timeIntervalSince1970 - Double(days) * 86_400
        return (events[event.rawValue] ?? []).filter { $0 >= cutoff }.count
    }

    /// Snapshot used by both the chart and the LLM prompt. Returns events in
    /// `Event.allCases` order so the bar chart preserves a stable layout
    /// across renders.
    struct Snapshot: Equatable {
        struct Row: Equatable, Identifiable {
            let event: Event
            let lifetime: Int
            /// Count for the selected window. Equals `lifetime` when
            /// `window == .lifetime`, otherwise the trailing-N-days count.
            let windowed: Int
            var id: String { event.id }
        }
        let rows: [Row]
        let window: Window
        let totalWindowed: Int
        let totalLifetime: Int
    }

    /// One data point for the line chart: a single bucket, single event.
    struct SeriesPoint: Equatable, Identifiable {
        let event: Event
        let date: Date
        let count: Int
        var id: String { "\(event.rawValue)-\(Int(date.timeIntervalSince1970))" }
    }

    /// Returns flattened points (one row per bucket per event, including
    /// zeros) so Swift Charts can draw a continuous line per event.
    ///
    /// Bucketing:
    /// - 7 days  → 7 daily buckets ending today
    /// - 30 days → 30 daily buckets ending today
    /// - lifetime → monthly buckets from first event's month through this month
    func timeSeries(window: Window, asOf reference: Date = Date()) -> [SeriesPoint] {
        let calendar = Calendar(identifier: .gregorian)
        let bucketStarts: [Date]
        let bucketFor: (TimeInterval) -> Date?

        switch window {
        case .sevenDays, .thirtyDays:
            let days = window.trailingDays ?? 7
            let today = calendar.startOfDay(for: reference)
            bucketStarts = (0..<days).reversed().compactMap { i in
                calendar.date(byAdding: .day, value: -i, to: today)
            }
            bucketFor = { ts in
                let date = Date(timeIntervalSince1970: ts)
                return calendar.startOfDay(for: date)
            }
        case .lifetime:
            let allTimestamps = events.values.flatMap { $0 }
            guard let earliest = allTimestamps.min().map({ Date(timeIntervalSince1970: $0) }) else {
                return []
            }
            let firstMonth = calendar.dateInterval(of: .month, for: earliest)?.start ?? earliest
            let thisMonth = calendar.dateInterval(of: .month, for: reference)?.start ?? reference
            var monthList: [Date] = []
            var cursor = firstMonth
            while cursor <= thisMonth {
                monthList.append(cursor)
                guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
            }
            bucketStarts = monthList
            bucketFor = { ts in
                let date = Date(timeIntervalSince1970: ts)
                return calendar.dateInterval(of: .month, for: date)?.start
            }
        }

        // Accumulate counts per (event, bucket).
        var counts: [Event: [Date: Int]] = [:]
        for event in Event.allCases {
            counts[event] = Dictionary(uniqueKeysWithValues: bucketStarts.map { ($0, 0) })
            for ts in events[event.rawValue] ?? [] {
                guard let bucket = bucketFor(ts) else { continue }
                if counts[event]?[bucket] != nil {
                    counts[event]?[bucket, default: 0] += 1
                }
            }
        }

        var points: [SeriesPoint] = []
        for event in Event.allCases {
            for bucket in bucketStarts {
                let c = counts[event]?[bucket] ?? 0
                points.append(SeriesPoint(event: event, date: bucket, count: c))
            }
        }
        return points
    }

    func snapshot(window: Window = .sevenDays, asOf reference: Date = Date()) -> Snapshot {
        let rows = Event.allCases.map { event in
            let lifetime = lifetimeCount(event)
            let windowed: Int
            if let days = window.trailingDays {
                windowed = recentCount(event, days: days, asOf: reference)
            } else {
                windowed = lifetime
            }
            return Snapshot.Row(event: event, lifetime: lifetime, windowed: windowed)
        }
        let totalWindowed = rows.reduce(0) { $0 + $1.windowed }
        let totalLifetime = rows.reduce(0) { $0 + $1.lifetime }
        return Snapshot(rows: rows, window: window, totalWindowed: totalWindowed, totalLifetime: totalLifetime)
    }

    private func trim(_ list: [TimeInterval]) -> [TimeInterval] {
        let cutoff = Date().timeIntervalSince1970 - Double(Self.retentionDays) * 86_400
        var filtered = list.filter { $0 >= cutoff }
        if filtered.count > Self.maxEventsPerKind {
            filtered = Array(filtered.suffix(Self.maxEventsPerKind))
        }
        return filtered
    }
}
