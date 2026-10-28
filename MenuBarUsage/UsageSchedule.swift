import Foundation

/// Cadence for AI usage fetches and the lighter system sampler.
enum UsageSchedule {
    static let openUsageInterval: TimeInterval = 90
    static let closedUsageInterval: TimeInterval = 12 * 60
    static let staleRefresh: TimeInterval = 60
    static let planInterval: TimeInterval = 60 * 60
    static let maxUsageInterval: TimeInterval = 30 * 60
    static let openSystemInterval: TimeInterval = 3
    static let closedSystemInterval: TimeInterval = 5
    static let batteryInterval: TimeInterval = 30

    static func usageInterval(panelOpen: Bool, transportFailures: Int) -> TimeInterval {
        let base = panelOpen ? openUsageInterval : closedUsageInterval
        guard transportFailures > 0 else { return base }
        let exponent = min(transportFailures, 5)
        let multiplier = pow(2.0, Double(exponent))
        return min(base * multiplier, maxUsageInterval)
    }

    static func systemInterval(panelOpen: Bool, firstSample: Bool) -> TimeInterval {
        if firstSample { return 1 }
        return panelOpen ? openSystemInterval : closedSystemInterval
    }

    static func shouldRefreshOnOpen(updatedAt: Date?, now: Date) -> Bool {
        guard let updatedAt else { return true }
        return now.timeIntervalSince(updatedAt) >= staleRefresh
    }

    static func shouldFetchPlan(fetchedAt: Date?, now: Date) -> Bool {
        guard let fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) >= planInterval
    }

    /// Next usage fetch after the panel opens or closes. Time since the last
    /// attempt counts, so a fresh result is not fetched again immediately.
    static func nextDeadline(
        now: Date,
        lastAttempt: Date?,
        panelOpen: Bool,
        transportFailures: Int
    ) -> Date {
        let interval = usageInterval(panelOpen: panelOpen, transportFailures: transportFailures)
        guard let lastAttempt else { return now }
        let remaining = interval - now.timeIntervalSince(lastAttempt)
        return now.addingTimeInterval(max(0, remaining))
    }
}

/// Remembers a value until `ttl` elapses.
struct TimedCache<Value> {
    var ttl: TimeInterval
    private var entry: (value: Value, at: Date)?

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    mutating func resolve(now: Date, read: () -> Value) -> Value {
        if let entry, now.timeIntervalSince(entry.at) < ttl {
            return entry.value
        }
        let value = read()
        entry = (value, now)
        return value
    }
}
