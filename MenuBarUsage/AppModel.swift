import AppKit
import Foundation
import SwiftUI

struct PanelContent: Equatable {
    var cpuPercent: Double?
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var networkDown: Double?
    var networkUp: Double?
    var networkDownHistory: [Double] = []
    var networkUpHistory: [Double] = []
    var battery: BatteryStatus?
    var batteryHistory: [Double] = []
    var planName: String?
    var note: String?
    var rows: [UsageRow] = []
    var authMessage: String?
    var statusMessage: String?
    var updatedAt: Date?
    var isRefreshing = false
    var sessionLabel: String?
    var hasPastedToken = false
}

struct PanelActions {
    var refresh: () -> Void
    var quit: () -> Void
    var openCursor: () -> Void
    var openDashboard: () -> Void
    var saveToken: (String) -> String?
    var forgetToken: () -> Void
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var memory: SystemSampler.Memory?
    @Published private(set) var networkDown: Double?
    @Published private(set) var networkUp: Double?
    @Published private(set) var networkDownHistory: [Double] = []
    @Published private(set) var networkUpHistory: [Double] = []
    @Published private(set) var battery: BatteryStatus?
    @Published private(set) var batteryHistory: [Double] = []
    @Published private(set) var presentation = UsagePresentation(planName: nil, note: nil, rows: [])
    @Published private(set) var authMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var sessionLabel: String?
    @Published private(set) var hasPastedToken = false

    private var systemLoop: Task<Void, Never>?
    private var usageLoop: Task<Void, Never>?
    private var suppressKeychain = false
    private var started = false
    private var pendingStatus: String?
    private var networkMark: (bytesIn: UInt64, bytesOut: UInt64, at: Date)?
    private let historyLimit = 30

    var content: PanelContent {
        PanelContent(
            cpuPercent: cpuPercent,
            memoryUsed: memory?.usedBytes,
            memoryTotal: memory?.totalBytes,
            networkDown: networkDown,
            networkUp: networkUp,
            networkDownHistory: networkDownHistory,
            networkUpHistory: networkUpHistory,
            battery: battery,
            batteryHistory: batteryHistory,
            planName: presentation.planName,
            note: presentation.note,
            rows: presentation.rows,
            authMessage: authMessage,
            statusMessage: statusMessage,
            updatedAt: updatedAt,
            isRefreshing: isRefreshing,
            sessionLabel: sessionLabel,
            hasPastedToken: hasPastedToken
        )
    }

    var menuBarText: String? {
        UsageFormatting.statusItem(cpu: cpuPercent, memory: memory?.percent)
    }

    var accessibilitySummary: String {
        var parts = ["Menu Bar Usage"]
        if let text = menuBarText {
            parts.append(text)
        }
        if let authMessage {
            parts.append(authMessage)
        }
        return parts.joined(separator: ", ")
    }

    func start() {
        guard !started else { return }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        started = true
        hasPastedToken = KeychainTokenStore.read() != nil
        systemLoop = Task { [weak self] in
            var previous: SystemSampler.CPUTicks?
            var interval: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                guard let self else { return }
                if let ticks = SystemSampler.cpuTicks() {
                    if let previous {
                        self.cpuPercent = SystemSampler.cpuPercent(from: previous, to: ticks)
                    }
                    previous = ticks
                }
                self.memory = SystemSampler.memory()
                self.sampleNetwork()
                self.sampleBattery()
                try? await Task.sleep(nanoseconds: interval)
                interval = 3_000_000_000
            }
        }
        usageLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshUsage()
                try? await Task.sleep(nanoseconds: 90_000_000_000)
            }
        }
    }

    func refreshUsage() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        hasPastedToken = KeychainTokenStore.read() != nil

        let credential: SessionCredential
        switch SessionResolver.resolve(allowKeychain: !suppressKeychain) {
        case let .success(value):
            credential = value
        case let .failure(failure):
            authMessage = failure.message
            sessionLabel = nil
            presentation = UsagePresentation(planName: nil, note: nil, rows: [])
            return
        }

        do {
            let fetch = try await UsageClient.shared.fetch(cookie: credential.cookie)
            let facts = UsageFacts(
                summary: fetch.summary,
                plan: fetch.plan,
                period: fetch.period,
                sand: fetch.sand,
                sandFailed: fetch.sandFailed
            )
            presentation = UsagePresenter.present(facts)
            authMessage = nil
            sessionLabel = credential.source.label
            updatedAt = Date()
            if let pendingStatus {
                statusMessage = pendingStatus
                self.pendingStatus = nil
            } else if fetch.sandFailed, presentation.rows.contains(where: { $0.id == "grok" && $0.percent == nil }) {
                statusMessage = "Grok Bot usage didn't load. Cursor usage is current."
            } else {
                statusMessage = nil
            }
        } catch UsageClientError.unauthorized {
            if credential.source == .keychain, case .success = SessionResolver.databaseCredential() {
                suppressKeychain = true
                pendingStatus = "The pasted token was rejected. Showing the Cursor session."
                isRefreshing = false
                await refreshUsage()
                return
            }
            authMessage = AuthFailure.rejected.message
            sessionLabel = nil
            presentation = UsagePresentation(planName: presentation.planName, note: nil, rows: [])
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
            if sessionLabel == nil {
                sessionLabel = credential.source.label
            }
        }
    }

    func savePastedToken(_ raw: String) -> String? {
        guard let cookie = SessionCookie.normalizePasted(raw) else {
            return "That is not a Cursor session token."
        }
        guard KeychainTokenStore.save(cookie) else {
            return "The token could not be saved in the Keychain."
        }
        suppressKeychain = false
        hasPastedToken = true
        statusMessage = nil
        Task { await refreshUsage() }
        return nil
    }

    func forgetPastedToken() {
        KeychainTokenStore.delete()
        suppressKeychain = false
        hasPastedToken = false
        Task { await refreshUsage() }
    }

    func openCursor() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
        let fallback = URL(fileURLWithPath: "/Applications/Cursor.app")
        if FileManager.default.fileExists(atPath: fallback.path) {
            NSWorkspace.shared.openApplication(at: fallback, configuration: configuration)
            return
        }
        openDashboard()
        statusMessage = "Cursor is not installed. Opened the usage dashboard."
    }

    func openDashboard() {
        NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard/usage")!)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func sampleNetwork() {
        guard let totals = InterfaceSelection.totals(
            interfaces: LinkCounters.read(),
            primary: PrimaryInterface.name()
        ) else { return }
        let now = Date()
        if let mark = networkMark,
           let down = Throughput.bytesPerSecond(previous: mark.bytesIn, current: totals.bytesIn, seconds: now.timeIntervalSince(mark.at)),
           let up = Throughput.bytesPerSecond(previous: mark.bytesOut, current: totals.bytesOut, seconds: now.timeIntervalSince(mark.at)) {
            networkDown = down
            networkUp = up
            SampleHistory.append(down, to: &networkDownHistory, limit: historyLimit)
            SampleHistory.append(up, to: &networkUpHistory, limit: historyLimit)
        }
        networkMark = (totals.bytesIn, totals.bytesOut, now)
    }

    private func sampleBattery() {
        guard let reading = BatterySampler.read() else {
            battery = nil
            batteryHistory = []
            return
        }
        battery = reading
        SampleHistory.append(reading.percent, to: &batteryHistory, limit: historyLimit)
    }
}
