import AppKit
import Foundation
import XCTest
@testable import MenuBarUsage

final class UsagePresenterTests: XCTestCase {
    private let grokReset = DateParser.parse("2026-10-31T10:39:44Z")!
    private let cycleEnd = DateParser.parse("2026-11-05T06:01:20Z")!
    private let weekEnd = DateParser.parse("2026-10-30T00:00:00Z")!

    func testLegacyPlanShowsGrokBotAndCursorModels() {
        let facts = UsageFacts(
            membershipType: "pro_plus",
            planLabel: "Pro+",
            billingCycleEnd: cycleEnd,
            autoPercent: 34.438333,
            apiPercent: 0,
            totalPercent: 32.223,
            grok: .percent(12.735864, resetsAt: grokReset),
            offeredUnifiedMigration: true
        )

        let presentation = UsagePresenter.present(facts)

        XCTAssertEqual(presentation.planName, "Pro+")
        XCTAssertEqual(presentation.rows.map(\.id), ["grok", "cursor", "other"])
        XCTAssertEqual(presentation.rows.map(\.percentText), ["12.7%", "34.4%", "0%"])
        XCTAssertEqual(presentation.rows.map(\.detail), ["", "", ""])
        XCTAssertEqual(presentation.rows[0].resetsAt, grokReset)
        XCTAssertEqual(presentation.rows[1].resetsAt, cycleEnd)
        XCTAssertEqual(presentation.rows[2].resetsAt, cycleEnd)
        XCTAssertFalse(UsagePresenter.sharesPool(facts))
        XCTAssertEqual(presentation.rows[0].title, "Grok Bot")
        XCTAssertEqual(presentation.rows[1].title, "Cursor models")
        XCTAssertEqual(presentation.rows[2].title, "Other models")
        XCTAssertNil(presentation.note)
    }

    func testWeeklySharedPoolIsOneIncludedRow() {
        let facts = UsageFacts(
            membershipType: "premium",
            billingCycleEnd: cycleEnd,
            autoPercent: 0,
            apiPercent: 0,
            totalPercent: 0,
            includedPeriodWeekly: true,
            weeklyPercent: 35.5,
            weeklyReset: weekEnd,
            grok: .percent(35.5, resetsAt: weekEnd)
        )

        let presentation = UsagePresenter.present(facts)

        XCTAssertTrue(UsagePresenter.sharesPool(facts))
        XCTAssertEqual(presentation.rows.map(\.id), ["included"])
        XCTAssertEqual(presentation.rows[0].title, "Included AI usage")
        XCTAssertEqual(presentation.rows[0].percentText, "35.5%")
        XCTAssertEqual(presentation.rows[0].resetsAt, weekEnd)
        XCTAssertEqual(presentation.note, "One included pool, shared by Cursor and Grok Bot.")
    }

    func testWeeklyPlanShowsSeparateOtherModelsWithoutSubtitle() {
        let facts = UsageFacts(
            membershipType: "premium",
            billingCycleEnd: cycleEnd,
            autoPercent: 0,
            apiPercent: 8.2,
            totalPercent: 0,
            includedPeriodWeekly: true,
            weeklyPercent: 35.5,
            weeklyReset: weekEnd,
            grok: .percent(35.4, resetsAt: weekEnd)
        )

        let rows = UsagePresenter.present(facts).rows

        XCTAssertEqual(rows.map(\.id), ["included", "other"])
        XCTAssertEqual(rows[0].percentText, "35.5%")
        XCTAssertEqual(rows[1].title, "Other models")
        XCTAssertEqual(rows[1].percentText, "8.2%")
        XCTAssertEqual(rows[1].detail, "")
        XCTAssertEqual(rows[1].resetsAt, cycleEnd)
    }

    func testWeeklyStubZerosAreNotShownAsZeroPercent() {
        let facts = UsageFacts(
            membershipType: "plus",
            autoPercent: 0,
            apiPercent: 0,
            totalPercent: 0,
            includedPeriodWeekly: true,
            weeklyPercent: nil,
            grok: .unavailable
        )

        let rows = UsagePresenter.present(facts).rows

        XCTAssertEqual(rows.map(\.id), ["included"])
        XCTAssertNil(rows[0].percent)
        XCTAssertEqual(rows[0].percentText, "—")
    }

    func testAccountWithoutGrokAllowanceOmitsThatRow() {
        let facts = UsageFacts(
            membershipType: "pro",
            billingCycleEnd: cycleEnd,
            autoPercent: 10,
            apiPercent: 3,
            totalPercent: 9,
            grok: .noAllowance
        )

        let presentation = UsagePresenter.present(facts)

        XCTAssertEqual(presentation.rows.map(\.id), ["cursor", "other"])
        XCTAssertEqual(presentation.note, "No separate Grok Bot allowance on this account.")
    }

    func testMatchingMetersCollapseUnlessAMigrationIsOffered() {
        let shared = UsageFacts(
            membershipType: "pro",
            billingCycleEnd: cycleEnd,
            autoPercent: 20,
            apiPercent: 4,
            totalPercent: 20,
            grok: .percent(20, resetsAt: cycleEnd)
        )
        XCTAssertTrue(UsagePresenter.sharesPool(shared))
        XCTAssertEqual(UsagePresenter.present(shared).rows.map(\.id), ["included", "other"])

        var legacy = shared
        legacy.offeredUnifiedMigration = true
        XCTAssertFalse(UsagePresenter.sharesPool(legacy))
        XCTAssertEqual(UsagePresenter.present(legacy).rows.map(\.id), ["grok", "cursor", "other"])
        XCTAssertEqual(UsagePresenter.present(legacy).rows.map(\.detail), ["", "", ""])
    }

    func testUnlimitedPlanDoesNotDrawAZeroBar() {
        let facts = UsageFacts(
            membershipType: "enterprise",
            isUnlimited: true,
            billingCycleEnd: cycleEnd,
            autoPercent: 0,
            apiPercent: 0,
            totalPercent: 0
        )

        let rows = UsagePresenter.present(facts).rows

        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].unlimited)
        XCTAssertEqual(rows[0].percentText, "Unlimited")
        XCTAssertNil(rows[0].percent)
    }

    func testPercentFormattingKeepsTenths() {
        XCTAssertEqual(UsageFormatting.percent(12.735864), "12.7%")
        XCTAssertEqual(UsageFormatting.percent(34.438333), "34.4%")
        XCTAssertEqual(UsageFormatting.percent(0), "0%")
        XCTAssertEqual(UsageFormatting.percent(100), "100%")
        XCTAssertEqual(UsageFormatting.menuPercent(12.7), "13%")
        let both = UsageFormatting.statusItem(cpu: 36.2, memory: 68.4)
        XCTAssertEqual(both.tokens().map(\.symbol), ["cpu", nil, "memorychip"])
        XCTAssertEqual(both.tokens().map(\.text), ["36%", "·", "68%"])
        let visible = both.tokens().map(\.text).joined(separator: " ")
        XCTAssertFalse(visible.contains("CPU"))
        XCTAssertFalse(visible.contains("Mem"))

        let cpuOnly = UsageFormatting.statusItem(cpu: 42, memory: nil)
        XCTAssertEqual(cpuOnly.tokens().map(\.symbol), ["cpu"])
        XCTAssertEqual(cpuOnly.tokens().map(\.text), ["42%"])

        let memoryOnly = UsageFormatting.statusItem(cpu: nil, memory: 68)
        XCTAssertEqual(memoryOnly.tokens().map(\.symbol), ["memorychip"])
        XCTAssertEqual(memoryOnly.tokens().map(\.text), ["68%"])

        XCTAssertTrue(UsageFormatting.statusItem(cpu: nil, memory: nil).tokens().isEmpty)

        let low = UsageFormatting.statusItem(cpu: 36.2, memory: 67.6)
        let high = UsageFormatting.statusItem(cpu: 36.4, memory: 68.4)
        XCTAssertEqual(low, high)
        XCTAssertNotEqual(low, UsageFormatting.statusItem(cpu: 37, memory: 68))
    }

    func testStatusItemImageIsReusedForTheSameRoundedPercents() throws {
        let parts = UsageFormatting.statusItem(cpu: 36.2, memory: 68.4)
        let first = try XCTUnwrap(StatusItemArtwork.image(for: parts))
        let second = try XCTUnwrap(StatusItemArtwork.image(for: UsageFormatting.statusItem(cpu: 36.4, memory: 67.6)))
        XCTAssertTrue(first === second)
        XCTAssertTrue(first.isTemplate)

        let changed = try XCTUnwrap(StatusItemArtwork.image(for: UsageFormatting.statusItem(cpu: 37, memory: 68)))
        XCTAssertFalse(first === changed)
        let restored = try XCTUnwrap(StatusItemArtwork.image(for: parts))
        XCTAssertFalse(restored === first)
        XCTAssertEqual(restored.size, first.size)
    }

    func testStatusItemImageDrawsBothSymbolsAndBothPercents() throws {
        let both = StatusItemArtwork.image(for: UsageFormatting.statusItem(cpu: 36, memory: 68))
        let cpuOnly = StatusItemArtwork.image(for: UsageFormatting.statusItem(cpu: 36, memory: nil))
        let image = try XCTUnwrap(both)
        let cpuImage = try XCTUnwrap(cpuOnly)
        XCTAssertTrue(image.isTemplate)
        XCTAssertGreaterThan(image.size.height, 16)
        XCTAssertGreaterThan(image.size.width, cpuImage.size.width + 24)
        let columns = opaqueColumns(image)
        let first = try XCTUnwrap(columns.first)
        let last = try XCTUnwrap(columns.last)
        XCTAssertLessThan(first, Int(image.size.width * 0.25))
        XCTAssertGreaterThan(last, Int(image.size.width * 0.7))
    }

    private func opaqueColumns(_ image: NSImage) -> [Int] {
        guard let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data) else { return [] }
        var columns: [Int] = []
        for x in 0..<rep.pixelsWide {
            var marked = false
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.15 {
                    marked = true
                    break
                }
            }
            if marked { columns.append(x) }
        }
        return columns
    }

    func testPlanName() {
        XCTAssertEqual(PlanName.format("pro_plus"), "Pro+")
        XCTAssertEqual(PlanName.format("premium"), "Premium")
        XCTAssertEqual(PlanName.format("Pro+"), "Pro+")
    }
}

final class UsageScheduleTests: XCTestCase {
    func testClosedPanelPollsMoreSlowlyAndBacksOffTransportErrors() {
        XCTAssertEqual(UsageSchedule.usageInterval(panelOpen: true, transportFailures: 0), 90)
        XCTAssertEqual(UsageSchedule.usageInterval(panelOpen: false, transportFailures: 0), 12 * 60)
        XCTAssertEqual(UsageSchedule.usageInterval(panelOpen: true, transportFailures: 1), 180)
        XCTAssertEqual(UsageSchedule.usageInterval(panelOpen: false, transportFailures: 1), 24 * 60)
        XCTAssertEqual(UsageSchedule.usageInterval(panelOpen: false, transportFailures: 4), 30 * 60)
        XCTAssertEqual(UsageSchedule.usageInterval(panelOpen: true, transportFailures: 8), 30 * 60)
    }

    func testOpeningRefreshesOnlyWhenTheSnapshotIsStale() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(UsageSchedule.shouldRefreshOnOpen(updatedAt: nil, now: now))
        XCTAssertFalse(UsageSchedule.shouldRefreshOnOpen(updatedAt: now.addingTimeInterval(-59), now: now))
        XCTAssertTrue(UsageSchedule.shouldRefreshOnOpen(updatedAt: now.addingTimeInterval(-60), now: now))
    }

    func testPlanInfoIsFetchedAtLaunchAndThenHourly() {
        let now = Date(timeIntervalSince1970: 50_000)
        XCTAssertTrue(UsageSchedule.shouldFetchPlan(fetchedAt: nil, now: now))
        XCTAssertFalse(UsageSchedule.shouldFetchPlan(fetchedAt: now.addingTimeInterval(-3_599), now: now))
        XCTAssertTrue(UsageSchedule.shouldFetchPlan(fetchedAt: now.addingTimeInterval(-3_600), now: now))
    }

    func testPanelToggleKeepsTheRemainderOfTheCurrentCadence() {
        let now = Date(timeIntervalSince1970: 20_000)
        let fresh = UsageSchedule.nextDeadline(
            now: now,
            lastAttempt: now.addingTimeInterval(-20),
            panelOpen: true,
            transportFailures: 0
        )
        XCTAssertEqual(fresh.timeIntervalSince(now), 70, accuracy: 0.001)

        let quiet = UsageSchedule.nextDeadline(
            now: now,
            lastAttempt: now.addingTimeInterval(-90),
            panelOpen: false,
            transportFailures: 0
        )
        XCTAssertEqual(quiet.timeIntervalSince(now), 12 * 60 - 90, accuracy: 0.001)

        let due = UsageSchedule.nextDeadline(
            now: now,
            lastAttempt: now.addingTimeInterval(-1_000),
            panelOpen: true,
            transportFailures: 0
        )
        XCTAssertEqual(due, now)
    }

    func testClosedPanelSamplesTheSystemALittleSlower() {
        XCTAssertEqual(UsageSchedule.systemInterval(panelOpen: false, firstSample: true), 1)
        XCTAssertEqual(UsageSchedule.systemInterval(panelOpen: true, firstSample: false), 3)
        XCTAssertEqual(UsageSchedule.systemInterval(panelOpen: false, firstSample: false), 5)
    }
}

final class SessionFreshnessTests: XCTestCase {
    func testNearExpiryForcesAnotherResolve() {
        let soon = Self.jwt(subject: "google-oauth2|user_TEST", expiresAt: Date().addingTimeInterval(4 * 60))
        let later = Self.jwt(subject: "google-oauth2|user_TEST", expiresAt: Date().addingTimeInterval(30 * 60))
        XCTAssertTrue(SessionCredentialFreshness.isNearExpiry("user_TEST%3A%3A\(soon)"))
        XCTAssertFalse(SessionCredentialFreshness.isNearExpiry("user_TEST%3A%3A\(later)"))
        XCTAssertFalse(SessionCredentialFreshness.isNearExpiry("not-a-token"))
        XCTAssertEqual(
            SessionCredentialFreshness.expiration(of: "user_TEST::\(later)")?.timeIntervalSince1970 ?? 0,
            Date().addingTimeInterval(30 * 60).timeIntervalSince1970,
            accuracy: 1
        )
    }

    private static func jwt(subject: String, expiresAt: Date) -> String {
        func part(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = part(["alg": "none", "typ": "JWT"])
        let payload = part(["sub": subject, "exp": expiresAt.timeIntervalSince1970])
        return "\(header).\(payload).sig"
    }
}

final class UsageDecodingTests: XCTestCase {
    func testFixtureMapsLegacyPoolsAndDoesNotKeepMigrationURL() throws {
        let summary = """
        {"billingCycleEnd":"2026-11-05T06:01:20.000Z","membershipType":"pro_plus","isUnlimited":false,
         "individualUsage":{"plan":{"used":7000,"limit":7000,"autoPercentUsed":34.4,"apiPercentUsed":0,"totalPercentUsed":32.2}}}
        """.data(using: .utf8)!
        let plan = """
        {"planInfo":{"planName":"Pro+","includedUsagePeriod":"INCLUDED_USAGE_PERIOD_MONTHLY","billingCycleEnd":"1793858480000"}}
        """.data(using: .utf8)!
        let sand = """
        {"usagePercent":"12.7","hasNonZeroIncludedLimit":true,"nextResetTimestampUtc":"2026-10-31T10:39:44.226Z",
         "cursorPlanName":"Pro+","unifiedPlanMigration":{"href":"https://cursor.com/unify?user=user_SHOULD_NOT_APPEAR"}}
        """.data(using: .utf8)!

        let facts = try UsageDecoding.facts(summaryData: summary, planData: plan, sandData: sand, sandFailed: false)
        let presentation = UsagePresenter.present(facts)

        XCTAssertEqual(facts.autoPercent ?? -1, 34.4, accuracy: 0.001)
        XCTAssertEqual(facts.apiPercent ?? -1, 0, accuracy: 0.001)
        XCTAssertFalse(facts.includedPeriodWeekly)
        XCTAssertTrue(facts.offeredUnifiedMigration)
        XCTAssertFalse(String(describing: facts).contains("SHOULD_NOT_APPEAR"))
        XCTAssertEqual(presentation.rows.map(\.id), ["grok", "cursor", "other"])
        XCTAssertEqual(presentation.rows[0].percentText, "12.7%")
        XCTAssertEqual(calendarYear(facts.billingCycleEnd), 2026)
    }

    func testWeeklyPeriodNumberReplacesStubSummary() throws {
        let summary = """
        {"billingCycleEnd":"2026-11-05T06:01:20.000Z","membershipType":"premium","isUnlimited":false,
         "individualUsage":{"plan":{"autoPercentUsed":0,"apiPercentUsed":0,"totalPercentUsed":0}}}
        """.data(using: .utf8)!
        let plan = """
        {"planInfo":{"planName":"Premium","includedUsagePeriod":2,"includedUsageResetsAt":"1793318400000"}}
        """.data(using: .utf8)!
        let period = """
        {"billingCycleStart":"1792713600000","billingCycleEnd":"1793318400000","planUsage":{"totalPercentUsed":35.5,"autoPercentUsed":0,"apiPercentUsed":0}}
        """.data(using: .utf8)!
        let sand = """
        {"usagePercent":35.5,"hasNonZeroIncludedLimit":true,"nextResetTimestampUtc":"2026-10-30T00:00:00Z"}
        """.data(using: .utf8)!

        let facts = try UsageDecoding.facts(
            summaryData: summary,
            planData: plan,
            periodData: period,
            sandData: sand,
            sandFailed: false
        )
        let rows = UsagePresenter.present(facts).rows

        XCTAssertTrue(facts.includedPeriodWeekly)
        XCTAssertEqual(rows.map(\.id), ["included"])
        XCTAssertEqual(rows[0].percentText, "35.5%")
    }

    func testMissingGrokAllowanceFromSand() throws {
        let summary = """
        {"membershipType":"pro","individualUsage":{"plan":{"autoPercentUsed":4,"apiPercentUsed":1}}}
        """.data(using: .utf8)!
        let sand = """
        {"usagePercent":0,"hasNonZeroIncludedLimit":false}
        """.data(using: .utf8)!
        let facts = try UsageDecoding.facts(summaryData: summary, sandData: sand, sandFailed: false)
        XCTAssertEqual(facts.grok, .noAllowance)
        XCTAssertEqual(UsagePresenter.present(facts).rows.map(\.id), ["cursor", "other"])
    }

    func testMillisecondResetParses() {
        let parsed = DateParser.parse("1793858480000")
        XCTAssertEqual(parsed, Date(timeIntervalSince1970: 1_793_858_480))
    }

    private func calendarYear(_ date: Date?) -> Int? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.component(.year, from: date)
    }
}

final class SessionCookieTests: XCTestCase {
    func testBuildsCookieFromJWTSubject() {
        let jwt = Self.jwt(subject: "google-oauth2|user_TEST", expiresAt: Date().addingTimeInterval(3_600))
        let cookie = SessionCookie.value(fromJWT: jwt)
        XCTAssertEqual(cookie, "user_TEST%3A%3A\(jwt)")
    }

    func testExpiredJWTIsNotACookie() {
        let jwt = Self.jwt(subject: "auth0|user_TEST", expiresAt: Date().addingTimeInterval(-120))
        XCTAssertNil(SessionCookie.value(fromJWT: jwt))
    }

    func testPastedCookieAndBareJWTNormalize() {
        let jwt = Self.jwt(subject: "google-oauth2|user_TEST", expiresAt: Date().addingTimeInterval(3_600))
        XCTAssertEqual(
            SessionCookie.normalizePasted("WorkosCursorSessionToken=user_TEST%3A%3A\(jwt)"),
            "user_TEST%3A%3A\(jwt)"
        )
        XCTAssertEqual(SessionCookie.normalizePasted("  \(jwt)\n"), "user_TEST%3A%3A\(jwt)")
        XCTAssertNil(SessionCookie.normalizePasted("not a token"))
    }

    func testReadsTokenFromCursorDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = root.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let jwt = Self.jwt(subject: "google-oauth2|user_TEST", expiresAt: Date().addingTimeInterval(3_600))
        try Self.insert(token: jwt, at: database)
        let loaded = CursorDatabase.load(home: root)
        guard case let .token(value) = loaded else {
            return XCTFail("expected token, got \(loaded)")
        }
        XCTAssertEqual(value, jwt)
        let credential = try XCTUnwrap(try? SessionResolver.resolve(allowKeychain: false, home: root).get())
        XCTAssertEqual(credential.source, .cursorDatabase)
        XCTAssertTrue(credential.cookie.hasPrefix("user_TEST%3A%3A"))
    }

    func testEncryptedDatabaseTokenIsReported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = root.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.insert(token: "cursor-safe-storage:v1:sealed", at: database)
        XCTAssertEqual(CursorDatabase.load(home: root), .encrypted)
    }

    func testMissingDatabase() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertEqual(CursorDatabase.load(home: root), .missing)
    }

    private static func jwt(subject: String, expiresAt: Date) -> String {
        func part(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = part(["alg": "none", "typ": "JWT"])
        let payload = part(["sub": subject, "exp": expiresAt.timeIntervalSince1970])
        return "\(header).\(payload).sig"
    }

    private static func insert(token: String, at database: URL) throws {
        let sql = """
        CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);
        INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', '\(token)');
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

final class MachineTelemetryTests: XCTestCase {
    func testPrimaryInterfaceIsNotAddedToThePhysicalLink() {
        let interfaces = [
            LinkReading(name: "en0", isUp: true, isLoopback: false, bytesIn: 100, bytesOut: 40),
            LinkReading(name: "utun0", isUp: true, isLoopback: false, bytesIn: 80, bytesOut: 20),
            LinkReading(name: "lo0", isUp: true, isLoopback: true, bytesIn: 9, bytesOut: 9)
        ]
        let totals = InterfaceSelection.totals(interfaces: interfaces, primary: "utun0")
        XCTAssertEqual(totals?.bytesIn, 80)
        XCTAssertEqual(totals?.bytesOut, 20)
    }

    func testMissingPrimaryFallsBackToUpEthernet() {
        let interfaces = [
            LinkReading(name: "en0", isUp: true, isLoopback: false, bytesIn: 10, bytesOut: 4),
            LinkReading(name: "en1", isUp: false, isLoopback: false, bytesIn: 50, bytesOut: 50),
            LinkReading(name: "awdl0", isUp: true, isLoopback: false, bytesIn: 7, bytesOut: 7)
        ]
        let totals = InterfaceSelection.totals(interfaces: interfaces, primary: nil)
        XCTAssertEqual(totals?.bytesIn, 10)
        XCTAssertEqual(totals?.bytesOut, 4)
    }

    func testRateIgnoresAResetCounter() {
        XCTAssertNil(Throughput.bytesPerSecond(previous: 500, current: 100, seconds: 1))
        XCTAssertEqual(Throughput.bytesPerSecond(previous: 1_000, current: 2_500, seconds: 1), 1_500)
        XCTAssertNil(Throughput.bytesPerSecond(previous: 0, current: 100, seconds: 0.05))
    }

    func testRateFormattingUsesDecimalUnits() {
        XCTAssertEqual(Throughput.rate(0), "0 B/s")
        XCTAssertEqual(Throughput.rate(1_500), "1.5 KB/s")
        XCTAssertEqual(Throughput.rate(12_500_000), "12.5 MB/s")
        XCTAssertEqual(Throughput.rate(250_000_000), "250 MB/s")
    }

    func testBatteryParser() {
        let charging: [String: Any] = [
            "Current Capacity": 86,
            "Max Capacity": 100,
            "Is Charging": true,
            "Power Source State": "AC Power",
            "Time to Full Charge": 75,
            "Transport Type": "Internal",
            "Is Present": true
        ]
        let status = BatteryStatusParser.parse(charging)
        XCTAssertEqual(status?.percent, 86)
        XCTAssertEqual(status?.source, .charging)
        XCTAssertEqual(status?.minutesRemaining, 75)
        XCTAssertEqual(status?.timeCaption, "1 hr 15 min to full")

        let draining = BatteryStatusParser.parse([
            "Current Capacity": 40,
            "Max Capacity": 100,
            "Is Charging": false,
            "Power Source State": "Battery Power",
            "Time to Empty": 45
        ])
        XCTAssertEqual(draining?.source, .battery)
        XCTAssertEqual(draining?.timeCaption, "45 min left")

        let calculating = BatteryStatusParser.parse([
            "Current Capacity": 40,
            "Max Capacity": 100,
            "Power Source State": "Battery Power",
            "Time to Empty": -1
        ])
        XCTAssertNil(calculating?.minutesRemaining)
        XCTAssertNil(BatteryStatusParser.parse(["Power Source State": "AC Power"]))
        XCTAssertNil(BatteryStatusParser.parse([
            "Current Capacity": 10,
            "Max Capacity": 100,
            "Is Present": false
        ]))
        let numericFlag = BatteryStatusParser.parse([
            "Current Capacity": 50,
            "Max Capacity": 100,
            "Is Charging": 0,
            "Power Source State": "Battery Power",
            "Time to Empty": 10
        ])
        XCTAssertEqual(numericFlag?.source, .battery)
    }

    func testPrefersTheInternalBattery() {
        let chosen = BatteryStatusParser.choose([
            [
                "Current Capacity": 10,
                "Max Capacity": 100,
                "Transport Type": "USB"
            ],
            [
                "Current Capacity": 90,
                "Max Capacity": 100,
                "Power Source State": "AC Power",
                "Is Charging": false,
                "Transport Type": "Internal"
            ]
        ])
        XCTAssertEqual(chosen?.percent, 90)
        XCTAssertEqual(chosen?.source, .powerAdapter)
        XCTAssertNil(chosen?.timeCaption)
    }

    func testHistoryKeepsTheNewestSamples() {
        var history: [Double] = []
        for value in 0..<5 {
            SampleHistory.append(Double(value), to: &history, limit: 3)
        }
        XCTAssertEqual(history, [2, 3, 4])
    }

    func testPrimaryInterfaceCacheReusesAValueUntilItIsStale() {
        var cache = TimedCache<String?>(ttl: 45)
        let start = Date(timeIntervalSince1970: 1_000)
        var reads = 0
        let first = cache.resolve(now: start) { reads += 1; return "en0" }
        let second = cache.resolve(now: start.addingTimeInterval(30)) { reads += 1; return "en1" }
        XCTAssertEqual(first.value, "en0")
        XCTAssertTrue(first.refreshed)
        XCTAssertEqual(second.value, "en0")
        XCTAssertFalse(second.refreshed)
        XCTAssertEqual(reads, 1)

        cache.markStale()
        let third = cache.resolve(now: start.addingTimeInterval(31)) { reads += 1; return nil as String? }
        XCTAssertTrue(third.refreshed)
        XCTAssertNil(third.value)
        let fourth = cache.resolve(now: start.addingTimeInterval(40)) { reads += 1; return "en1" }
        XCTAssertEqual(fourth.value, nil as String?)
        XCTAssertFalse(fourth.refreshed)
        XCTAssertEqual(reads, 2)

        let fifth = cache.resolve(now: start.addingTimeInterval(31 + 45)) { reads += 1; return "en1" }
        XCTAssertEqual(fifth.value, "en1")
        XCTAssertTrue(fifth.refreshed)
        XCTAssertEqual(reads, 3)
    }
}

@MainActor
final class HostSampleHistoryTests: XCTestCase {
    func testReadingsFillCpuAndMemoryHistoryOnTheSharedWindow() {
        let model = AppModel()
        model.panelDidOpen()
        XCTAssertEqual(model.content.cpuHistory, [])
        XCTAssertEqual(model.content.memoryHistory, [])

        model.noteCpuReading(3)
        model.noteMemoryReading(SystemSampler.Memory(usedBytes: 25, totalBytes: 100))
        XCTAssertEqual(model.content.cpuPercent, 3)
        XCTAssertEqual(model.content.cpuHistory, [3])
        XCTAssertEqual(model.content.memoryUsed, 25)
        XCTAssertEqual(model.content.memoryTotal, 100)
        XCTAssertEqual(model.content.memoryHistory, [25])

        // A nil delta clears the live reading and does not insert a zero in the graph.
        model.noteCpuReading(nil)
        model.noteMemoryReading(nil)
        XCTAssertNil(model.content.cpuPercent)
        XCTAssertNil(model.content.memoryUsed)
        XCTAssertEqual(model.content.cpuHistory, [3])
        XCTAssertEqual(model.content.memoryHistory, [25])

        for value in 0..<35 {
            model.noteCpuReading(Double(value))
            model.noteMemoryReading(SystemSampler.Memory(usedBytes: UInt64(value), totalBytes: 100))
        }
        // The early sample plus 0...34 is 36 readings. The panel keeps the newest 30.
        let newest = Array(5...34).map { Double($0) }
        XCTAssertEqual(model.content.cpuHistory, newest)
        XCTAssertEqual(model.content.memoryHistory, newest.map { $0 / 100.0 * 100.0 })
        XCTAssertEqual(model.content.cpuPercent, 34)
        XCTAssertEqual(model.content.memoryUsed, 34)
    }
}
