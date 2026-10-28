import Foundation

// MARK: - Dates

enum DateParser {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let number = Double(trimmed) {
            return parse(number)
        }
        // Plan, period, and sand decode in parallel, so the formatters are shared under a lock.
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: trimmed) ?? basic.date(from: trimmed)
    }

    static func parse(_ number: Double) -> Date? {
        guard number.isFinite, number > 0 else { return nil }
        if number > 10_000_000_000 {
            return Date(timeIntervalSince1970: number / 1000)
        }
        if number > 1_000_000_000 {
            return Date(timeIntervalSince1970: number)
        }
        return nil
    }
}

extension KeyedDecodingContainer {
    func lossyDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func lossyBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    func lossyDate(_ key: Key) -> Date? {
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return DateParser.parse(text)
        }
        if let number = try? decodeIfPresent(Double.self, forKey: key) {
            return DateParser.parse(number)
        }
        if let number = try? decodeIfPresent(Int.self, forKey: key) {
            return DateParser.parse(Double(number))
        }
        return nil
    }
}

// MARK: - Wire types

struct UsageSummaryDTO: Decodable {
    struct Individual: Decodable {
        var plan: PlanBucket?
        var overall: PlanBucket?
    }

    struct Team: Decodable {
        var pooled: PlanBucket?
    }

    var billingCycleEnd: String?
    var membershipType: String?
    var isUnlimited: Bool?
    var individualUsage: Individual?
    var teamUsage: Team?
}

struct PlanBucket: Decodable {
    var enabled: Bool?
    var used: Double?
    var limit: Double?
    var remaining: Double?
    var autoPercentUsed: Double?
    var apiPercentUsed: Double?
    var totalPercentUsed: Double?

    enum CodingKeys: String, CodingKey {
        case enabled, used, limit, remaining
        case autoPercentUsed, apiPercentUsed, totalPercentUsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = container.lossyBool(.enabled)
        used = container.lossyDouble(.used)
        limit = container.lossyDouble(.limit)
        remaining = container.lossyDouble(.remaining)
        autoPercentUsed = container.lossyDouble(.autoPercentUsed)
        apiPercentUsed = container.lossyDouble(.apiPercentUsed)
        totalPercentUsed = container.lossyDouble(.totalPercentUsed)
    }
}

struct UsagePeriod: Decodable {
    var isWeekly: Bool

    init(isWeekly: Bool) {
        self.isWeekly = isWeekly
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            isWeekly = number == 2
            return
        }
        let name = (try? container.decode(String.self))?.uppercased() ?? ""
        isWeekly = name == "INCLUDED_USAGE_PERIOD_WEEKLY" || name == "WEEKLY" || name == "2"
    }
}

struct PlanInfoDTO: Decodable {
    struct Info: Decodable {
        var planName: String?
        var includedUsagePeriod: UsagePeriod?
        var includedUsageResetsAt: Date?
        var billingCycleEnd: Date?

        enum CodingKeys: String, CodingKey {
            case planName, includedUsagePeriod, includedUsageResetsAt, billingCycleEnd
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            planName = try container.decodeIfPresent(String.self, forKey: .planName)
            includedUsagePeriod = try container.decodeIfPresent(UsagePeriod.self, forKey: .includedUsagePeriod)
            includedUsageResetsAt = container.lossyDate(.includedUsageResetsAt)
            billingCycleEnd = container.lossyDate(.billingCycleEnd)
        }
    }

    var planInfo: Info?
}

struct PeriodUsageDTO: Decodable {
    struct PlanUsage: Decodable {
        var totalPercentUsed: Double?
        var autoPercentUsed: Double?
        var apiPercentUsed: Double?

        enum CodingKeys: String, CodingKey {
            case totalPercentUsed, autoPercentUsed, apiPercentUsed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            totalPercentUsed = container.lossyDouble(.totalPercentUsed)
            autoPercentUsed = container.lossyDouble(.autoPercentUsed)
            apiPercentUsed = container.lossyDouble(.apiPercentUsed)
        }
    }

    var billingCycleStart: Date?
    var billingCycleEnd: Date?
    var planUsage: PlanUsage?

    enum CodingKeys: String, CodingKey {
        case billingCycleStart, billingCycleEnd, planUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        billingCycleStart = container.lossyDate(.billingCycleStart)
        billingCycleEnd = container.lossyDate(.billingCycleEnd)
        planUsage = try container.decodeIfPresent(PlanUsage.self, forKey: .planUsage)
    }
}

struct SandUsageDTO: Decodable {
    var usagePercent: Double?
    var hasNonZeroIncludedLimit: Bool?
    var includedLimitZero: Bool?
    var usesPooledEnterpriseAllowance: Bool?
    var nextResetTimestampUtc: String?
    var grokPlanLabel: String?
    var cursorPlanName: String?
    /// True when the payload offers a move onto the unified plan. The href is
    /// not stored; it can carry an account id.
    var offeredUnifiedMigration: Bool

    enum CodingKeys: String, CodingKey {
        case usagePercent, hasNonZeroIncludedLimit, includedLimitZero
        case usesPooledEnterpriseAllowance, nextResetTimestampUtc
        case grokPlanLabel, cursorPlanName, unifiedPlanMigration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usagePercent = container.lossyDouble(.usagePercent)
        hasNonZeroIncludedLimit = container.lossyBool(.hasNonZeroIncludedLimit)
        includedLimitZero = container.lossyBool(.includedLimitZero)
        usesPooledEnterpriseAllowance = container.lossyBool(.usesPooledEnterpriseAllowance)
        nextResetTimestampUtc = try container.decodeIfPresent(String.self, forKey: .nextResetTimestampUtc)
        grokPlanLabel = try container.decodeIfPresent(String.self, forKey: .grokPlanLabel)
        cursorPlanName = try container.decodeIfPresent(String.self, forKey: .cursorPlanName)
        if container.contains(.unifiedPlanMigration) {
            offeredUnifiedMigration = (try? container.decodeNil(forKey: .unifiedPlanMigration)) == false
        } else {
            offeredUnifiedMigration = false
        }
    }
}

// MARK: - Facts

enum GrokReading: Equatable {
    case noAllowance
    case unavailable
    case percent(Double, resetsAt: Date?)
}

struct UsageFacts: Equatable {
    var membershipType: String?
    var planLabel: String?
    var isUnlimited: Bool
    var billingCycleEnd: Date?
    var autoPercent: Double?
    var apiPercent: Double?
    var totalPercent: Double?
    var includedPeriodWeekly: Bool
    var weeklyPercent: Double?
    var weeklyReset: Date?
    var grok: GrokReading
    var offeredUnifiedMigration: Bool

    init(
        membershipType: String? = nil,
        planLabel: String? = nil,
        isUnlimited: Bool = false,
        billingCycleEnd: Date? = nil,
        autoPercent: Double? = nil,
        apiPercent: Double? = nil,
        totalPercent: Double? = nil,
        includedPeriodWeekly: Bool = false,
        weeklyPercent: Double? = nil,
        weeklyReset: Date? = nil,
        grok: GrokReading = .unavailable,
        offeredUnifiedMigration: Bool = false
    ) {
        self.membershipType = membershipType
        self.planLabel = planLabel
        self.isUnlimited = isUnlimited
        self.billingCycleEnd = billingCycleEnd
        self.autoPercent = autoPercent
        self.apiPercent = apiPercent
        self.totalPercent = totalPercent
        self.includedPeriodWeekly = includedPeriodWeekly
        self.weeklyPercent = weeklyPercent
        self.weeklyReset = weeklyReset
        self.grok = grok
        self.offeredUnifiedMigration = offeredUnifiedMigration
    }
}

enum UsageDecoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    static func facts(
        summaryData: Data,
        planData: Data? = nil,
        periodData: Data? = nil,
        sandData: Data? = nil,
        sandFailed: Bool = false
    ) throws -> UsageFacts {
        let decoder = decoder()
        let summary = try decoder.decode(UsageSummaryDTO.self, from: summaryData)
        let plan = planData.flatMap { try? decoder.decode(PlanInfoDTO.self, from: $0) }
        let period = periodData.flatMap { try? decoder.decode(PeriodUsageDTO.self, from: $0) }
        let sand = sandData.flatMap { try? decoder.decode(SandUsageDTO.self, from: $0) }
        return UsageFacts(summary: summary, plan: plan, period: period, sand: sand, sandFailed: sandFailed || sandData == nil)
    }
}

extension UsageFacts {
    init(
        summary: UsageSummaryDTO,
        plan: PlanInfoDTO?,
        period: PeriodUsageDTO?,
        sand: SandUsageDTO?,
        sandFailed: Bool
    ) {
        membershipType = summary.membershipType
        planLabel = plan?.planInfo?.planName ?? sand?.cursorPlanName
        isUnlimited = summary.isUnlimited ?? false
        billingCycleEnd = DateParser.parse(summary.billingCycleEnd)

        let pools = Self.pools(from: summary)
        autoPercent = pools.auto
        apiPercent = pools.api
        totalPercent = pools.total

        var weekly = plan?.planInfo?.includedUsagePeriod?.isWeekly ?? false
        var weekPercent: Double?
        var weekReset = plan?.planInfo?.includedUsageResetsAt
        if weekly {
            weekPercent = period?.planUsage?.totalPercentUsed
            if weekReset == nil {
                weekReset = period?.billingCycleEnd ?? plan?.planInfo?.billingCycleEnd
            }
        } else if let start = period?.billingCycleStart, let end = period?.billingCycleEnd {
            let days = end.timeIntervalSince(start) / 86_400
            if days > 5, days < 9 {
                weekly = true
                weekPercent = period?.planUsage?.totalPercentUsed
                weekReset = plan?.planInfo?.includedUsageResetsAt ?? end
            }
        }
        includedPeriodWeekly = weekly
        weeklyPercent = weekPercent
        weeklyReset = weekReset

        if !weekly {
            if autoPercent == nil { autoPercent = period?.planUsage?.autoPercentUsed }
            if apiPercent == nil { apiPercent = period?.planUsage?.apiPercentUsed }
            if totalPercent == nil { totalPercent = period?.planUsage?.totalPercentUsed }
        }

        offeredUnifiedMigration = sand?.offeredUnifiedMigration ?? false
        grok = Self.grokReading(sand, failed: sandFailed)
    }

    private static func pools(from summary: UsageSummaryDTO) -> (auto: Double?, api: Double?, total: Double?) {
        let individual = summary.individualUsage?.plan
        let pooled = summary.teamUsage?.pooled
        let chosen: PlanBucket?
        if Self.hasPercents(individual) {
            chosen = individual
        } else if Self.hasPercents(pooled) {
            chosen = pooled
        } else {
            chosen = individual ?? pooled
        }

        let auto = Self.finite(chosen?.autoPercentUsed)
        let api = Self.finite(chosen?.apiPercentUsed)
        var total = Self.finite(chosen?.totalPercentUsed)
        // `used` / `limit` is the plan's cash allowance, a different denominator
        // from the pool percentages. Only use it when no percentage exists.
        if auto == nil, api == nil, total == nil, let percent = Self.moneyPercent(chosen) {
            total = percent
        }
        if auto == nil, api == nil, total == nil, let percent = Self.moneyPercent(summary.individualUsage?.overall) {
            total = percent
        }
        return (auto, api, total)
    }

    private static func hasPercents(_ bucket: PlanBucket?) -> Bool {
        finite(bucket?.autoPercentUsed) != nil
            || finite(bucket?.apiPercentUsed) != nil
            || finite(bucket?.totalPercentUsed) != nil
    }

    private static func moneyPercent(_ bucket: PlanBucket?) -> Double? {
        guard let used = finite(bucket?.used), let limit = finite(bucket?.limit), limit > 0 else { return nil }
        return used / limit * 100
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func grokReading(_ sand: SandUsageDTO?, failed: Bool) -> GrokReading {
        guard !failed, let sand else { return .unavailable }
        if sand.usesPooledEnterpriseAllowance == true { return .noAllowance }
        if sand.includedLimitZero == true || sand.hasNonZeroIncludedLimit == false { return .noAllowance }
        if let percent = finite(sand.usagePercent) {
            return .percent(percent, resetsAt: DateParser.parse(sand.nextResetTimestampUtc))
        }
        return .unavailable
    }
}

// MARK: - Presentation

struct UsageRow: Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var percent: Double?
    var resetsAt: Date?
    var unlimited: Bool = false

    var percentText: String {
        if unlimited { return "Unlimited" }
        guard let percent else { return "—" }
        return UsageFormatting.percent(percent)
    }
}

struct UsagePresentation: Equatable {
    var planName: String?
    var note: String?
    var rows: [UsageRow]
}

enum PlanName {
    static func format(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("_"), trimmed.contains(where: \.isUppercase) || trimmed.contains("+") {
            return trimmed
        }
        var name = ""
        for part in trimmed.split(separator: "_") {
            if part.lowercased() == "plus" {
                name += "+"
            } else {
                let word = part.prefix(1).uppercased() + part.dropFirst().lowercased()
                if !name.isEmpty, !name.hasSuffix("+") { name += " " }
                name += word
            }
        }
        return name.isEmpty ? nil : name
    }
}

enum UsageFormatting {
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let clamped = max(0, value)
        let tenths = (clamped * 10).rounded() / 10
        if abs(tenths - tenths.rounded()) < 0.001 {
            return "\(Int(tenths.rounded()))%"
        }
        return String(format: "%.1f%%", tenths)
    }

    static func menuPercent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        return "\(Int(max(0, value).rounded()))%"
    }

    /// Percents for the menu bar. The symbols are drawn beside these strings;
    /// the words CPU and Mem are not part of the label.
    static func statusItem(cpu: Double?, memory: Double?) -> StatusItemParts {
        StatusItemParts(
            cpuPercent: cpu.map(menuPercent),
            memoryPercent: memory.map(menuPercent)
        )
    }
}

struct StatusItemParts: Equatable {
    struct Token: Equatable {
        var symbol: String?
        var text: String
    }

    static let cpuSymbol = "cpu"
    static let memorySymbol = "memorychip"
    static let memorySymbolFallback = "memorychip.fill"

    var cpuPercent: String?
    var memoryPercent: String?

    var isEmpty: Bool { cpuPercent == nil && memoryPercent == nil }

    /// Flat sequence the menu bar draws as one line: symbol, percent, dot, symbol, percent.
    func tokens(memorySymbol: String = StatusItemParts.memorySymbol) -> [Token] {
        var tokens: [Token] = []
        if let cpuPercent {
            tokens.append(Token(symbol: Self.cpuSymbol, text: cpuPercent))
        }
        if cpuPercent != nil, memoryPercent != nil {
            tokens.append(Token(symbol: nil, text: "·"))
        }
        if let memoryPercent {
            tokens.append(Token(symbol: memorySymbol, text: memoryPercent))
        }
        return tokens
    }
}

enum UsagePresenter {
    /// The X Subscription's included Cursor-model pool is weekly and shared by
    /// Cursor and Grok Bot, so those plans show one included row. Legacy plans
    /// keep Grok Bot and Cursor models separate. Other models is shown only
    /// when that pool is actually separate.
    static func present(_ facts: UsageFacts) -> UsagePresentation {
        let plan = PlanName.format(facts.membershipType) ?? facts.planLabel
        if facts.isUnlimited {
            return UsagePresentation(
                planName: plan,
                note: "This plan reports unlimited included usage.",
                rows: [
                    UsageRow(
                        id: "included",
                        title: "Included AI usage",
                        detail: "No included limit is reported.",
                        percent: nil,
                        resetsAt: facts.billingCycleEnd,
                        unlimited: true
                    )
                ]
            )
        }
        if sharesPool(facts) {
            return presentShared(facts, plan: plan)
        }
        return presentSeparate(facts, plan: plan)
    }

    static func sharesPool(_ facts: UsageFacts) -> Bool {
        if facts.includedPeriodWeekly { return true }
        let tier = (facts.membershipType ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        if ["plus", "premium", "super"].contains(tier) { return true }
        if facts.offeredUnifiedMigration { return false }
        if case let .percent(grokPercent, grokReset) = facts.grok,
           let cursorPercent = facts.autoPercent ?? facts.totalPercent,
           let grokReset,
           let cursorReset = facts.billingCycleEnd,
           abs(grokPercent - cursorPercent) < 0.5,
           abs(grokReset.timeIntervalSince(cursorReset)) < 6 * 3_600 {
            return true
        }
        return false
    }

    private static func presentShared(_ facts: UsageFacts, plan: String?) -> UsagePresentation {
        let percent = includedPercent(facts)
        let grokReset: Date? = {
            if case let .percent(_, reset) = facts.grok { return reset }
            return nil
        }()
        let reset = facts.weeklyReset ?? grokReset ?? facts.billingCycleEnd
        var rows = [
            UsageRow(
                id: "included",
                title: "Included AI usage",
                detail: "Shared by Cursor and Grok Bot.",
                percent: percent,
                resetsAt: reset
            )
        ]
        if let other = otherRow(facts, shared: true, included: percent) {
            rows.append(other)
        }
        return UsagePresentation(
            planName: plan,
            note: "One included pool, shared by Cursor and Grok Bot.",
            rows: rows
        )
    }

    private static func presentSeparate(_ facts: UsageFacts, plan: String?) -> UsagePresentation {
        var rows: [UsageRow] = []
        switch facts.grok {
        case .noAllowance:
            break
        case .unavailable:
            rows.append(UsageRow(
                id: "grok",
                title: "Grok Bot",
                detail: "Didn't load.",
                percent: nil,
                resetsAt: nil
            ))
        case let .percent(value, reset):
            rows.append(UsageRow(
                id: "grok",
                title: "Grok Bot",
                detail: "",
                percent: value,
                resetsAt: reset
            ))
        }
        if let auto = facts.autoPercent {
            rows.append(UsageRow(
                id: "cursor",
                title: "Cursor models",
                detail: "",
                percent: auto,
                resetsAt: facts.billingCycleEnd
            ))
        }
        if let other = otherRow(facts, shared: false, included: nil) {
            rows.append(other)
        }
        if facts.autoPercent == nil, facts.apiPercent == nil {
            rows.append(UsageRow(
                id: "included",
                title: "Included AI usage",
                detail: facts.totalPercent == nil ? "No usage percentage was reported." : "Overall included usage.",
                percent: facts.totalPercent,
                resetsAt: facts.billingCycleEnd
            ))
        }
        let note: String?
        if case .noAllowance = facts.grok {
            note = "No separate Grok Bot allowance on this account."
        } else {
            note = nil
        }
        return UsagePresentation(planName: plan, note: note, rows: rows)
    }

    /// Weekly included percent. Summary zeros are not used in place of a
    /// missing weekly figure — on those plans the monthly pools come back at
    /// 0% while the week is actually spent.
    private static func includedPercent(_ facts: UsageFacts) -> Double? {
        if let weekly = facts.weeklyPercent, weekly.isFinite { return weekly }
        if case let .percent(value, _) = facts.grok, value.isFinite { return value }
        let summary = [facts.totalPercent, facts.autoPercent, facts.apiPercent]
        let summaryEmpty = summary.allSatisfy { ($0 ?? 0) < 0.05 }
        if facts.includedPeriodWeekly, summaryEmpty { return nil }
        return facts.totalPercent ?? facts.autoPercent
    }

    /// Same visibility rules as before the subtitle was removed. The detail
    /// stays empty so the panel shows the percent, bar, and reset only.
    private static func otherRow(_ facts: UsageFacts, shared: Bool, included: Double?) -> UsageRow? {
        guard let api = facts.apiPercent, api.isFinite else { return nil }
        if shared {
            guard let included else { return nil }
            let auto = facts.autoPercent ?? 0
            let stubZero = api < 0.05 && auto < 0.05 && included > 0.5
            if stubZero { return nil }
            if abs(api - included) < 0.5, abs(auto - api) < 0.5 { return nil }
        }
        return UsageRow(
            id: "other",
            title: "Other models",
            detail: "",
            percent: api,
            resetsAt: facts.billingCycleEnd
        )
    }
}
