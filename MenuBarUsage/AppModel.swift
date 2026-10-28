import AppKit
import Foundation
import SwiftUI

struct PanelContent: Equatable {
    var cpuPercent: Double?
    var cpuHistory: [Double] = []
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var memoryHistory: [Double] = []
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
    var openActivityMonitor: () -> Void
    var saveToken: (String) -> String?
    var forgetToken: () -> Void
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memory: SystemSampler.Memory?
    @Published private(set) var memoryHistory: [Double] = []
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
    /// Template image for the status item. Replaced only when the rounded percents change.
    @Published private(set) var statusImage: NSImage?
    @Published private(set) var statusAccessibility = "Menu Bar Usage"

    private var systemLoop: Task<Void, Never>?
    private var usageLoop: Task<Void, Never>?
    private var suppressKeychain = false
    private var started = false
    private var pendingStatus: String?
    private var networkMark: (bytesIn: UInt64, bytesOut: UInt64, at: Date)?
    private let historyLimit = 30

    private var panelVisible = false
    /// The popover window that became key. MenuBarExtra hides it; it does not close.
    private weak var panelWindow: NSWindow?
    private var seededMachineMetrics = false
    private var pauseReasons: Set<PauseReason> = []
    private var samplingSuspended: Bool { !pauseReasons.isEmpty }
    private var dropCPUBaseline = false
    private var sleepGeneration = 0
    private var transportFailures = 0
    private var lastUsageAttemptAt: Date?
    private var nextUsageFetchAt = Date()
    private var cachedCredential: SessionCredential?
    private var cachedPlan: PlanInfoDTO?
    private var planFetchedAt: Date?
    /// JWT user id the cached plan belongs to. Token rotation keeps the same id.
    private var planOwner: String?
    private var lastBatterySample = Date.distantPast
    private var notificationTokens: [NSObjectProtocol] = []
    private var resumeContinuations: [CheckedContinuation<Void, Never>] = []
    private var sleepers: [SleepBox] = []

    private var cpuValue: Double?
    private var cpuSamples: [Double] = []
    private var memoryValue: SystemSampler.Memory?
    private var memorySamples: [Double] = []
    private var networkDownValue: Double?
    private var networkUpValue: Double?
    private var networkDownSamples: [Double] = []
    private var networkUpSamples: [Double] = []
    private var batteryValue: BatteryStatus?
    private var batterySamples: [Double] = []
    private var renderedStatusParts = StatusItemParts(cpuPercent: nil, memoryPercent: nil)

    /// Rounded CPU and memory strings currently drawn in the status item.
    var statusParts: StatusItemParts { renderedStatusParts }

    var content: PanelContent {
        PanelContent(
            cpuPercent: cpuPercent,
            cpuHistory: cpuHistory,
            memoryUsed: memory?.usedBytes,
            memoryTotal: memory?.totalBytes,
            memoryHistory: memoryHistory,
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

    func start() {
        guard !started else { return }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        started = true
        hasPastedToken = KeychainTokenStore.read() != nil
        observePowerAndSession()
        observePanelWindow()
        BatterySampler.startWatching { [weak self] in
            Task { @MainActor in
                self?.recordBattery(force: true)
            }
        }
        systemLoop = Task { [weak self] in
            var previous: SystemSampler.CPUTicks?
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                await self.waitWhileSuspended()
                guard !Task.isCancelled else { return }
                if self.dropCPUBaseline {
                    previous = nil
                    self.dropCPUBaseline = false
                }
                if let ticks = SystemSampler.cpuTicks() {
                    if let previous {
                        self.noteCpuReading(SystemSampler.cpuPercent(from: previous, to: ticks))
                    }
                    previous = ticks
                }
                self.noteMemoryReading(SystemSampler.memory())
                self.recordNetwork()
                self.recordBattery(force: false)
                let interval = UsageSchedule.systemInterval(panelOpen: self.panelVisible, firstSample: first)
                first = false
                let generation = self.sleepGeneration
                _ = await self.sleep(seconds: interval, generation: generation)
            }
        }
        usageLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.waitWhileSuspended()
                guard !Task.isCancelled else { return }
                if Date() >= self.nextUsageFetchAt {
                    if !self.isRefreshing {
                        await self.refreshUsage()
                    }
                    self.nextUsageFetchAt = Date().addingTimeInterval(self.currentUsageInterval())
                }
                let generation = self.sleepGeneration
                let remaining = self.nextUsageFetchAt.timeIntervalSinceNow
                let interrupted = await self.sleep(seconds: remaining, generation: generation)
                guard !Task.isCancelled else { return }
                if interrupted, !self.samplingSuspended, self.nextUsageFetchAt > Date() {
                    self.nextUsageFetchAt = UsageSchedule.nextDeadline(
                        now: Date(),
                        lastAttempt: self.lastUsageAttemptAt,
                        panelOpen: self.panelVisible,
                        transportFailures: self.transportFailures
                    )
                }
            }
        }
    }

    /// The menu-bar window opened. Refreshes AI usage when the last result is older than a minute.
    func panelDidOpen() {
        let wasOpen = panelVisible
        panelVisible = true
        mirrorMachineMetrics()
        guard !wasOpen else { return }
        // One fetch: arm the usage loop instead of starting a second request here.
        // A deadline that is already due is left in place when the loop wakes.
        if started, UsageSchedule.shouldRefreshOnOpen(updatedAt: updatedAt, now: Date()) {
            nextUsageFetchAt = Date()
        }
        interruptSleepers()
    }

    func panelDidClose() {
        guard panelVisible else { return }
        panelVisible = false
        interruptSleepers()
    }

    func refreshUsage() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastUsageAttemptAt = Date()
        }

        let credential: SessionCredential
        switch credentialForRefresh() {
        case let .success(value):
            credential = value
        case let .failure(failure):
            authMessage = failure.message
            sessionLabel = nil
            presentation = UsagePresentation(planName: nil, note: nil, rows: [])
            refreshStatusItem()
            return
        }

        do {
            let now = Date()
            let includePlan = UsageSchedule.shouldFetchPlan(fetchedAt: planFetchedAt, now: now)
            let fetch = try await UsageClient.shared.fetch(cookie: credential.cookie, includePlan: includePlan)
            if includePlan {
                if let plan = fetch.plan {
                    cachedPlan = plan
                    planFetchedAt = now
                } else if cachedPlan != nil {
                    // A miss while we already have a plan should not retry every poll.
                    planFetchedAt = now
                }
            }
            let facts = UsageFacts(
                summary: fetch.summary,
                plan: fetch.plan ?? cachedPlan,
                period: fetch.period,
                sand: fetch.sand,
                sandFailed: fetch.sandFailed
            )
            presentation = UsagePresenter.present(facts)
            authMessage = nil
            sessionLabel = credential.source.label
            updatedAt = Date()
            transportFailures = 0
            if let pendingStatus {
                statusMessage = pendingStatus
                self.pendingStatus = nil
            } else if fetch.sandFailed, presentation.rows.contains(where: { $0.id == "grok" && $0.percent == nil }) {
                statusMessage = "Grok Bot usage didn't load. Cursor usage is current."
            } else {
                statusMessage = nil
            }
            refreshStatusItem()
        } catch UsageClientError.transport {
            transportFailures = min(transportFailures + 1, 6)
            statusMessage = UsageClientError.transport.localizedDescription
            if sessionLabel == nil {
                sessionLabel = credential.source.label
            }
        } catch UsageClientError.unauthorized {
            transportFailures = 0
            cachedCredential = nil
            cachedPlan = nil
            planFetchedAt = nil
            KeychainTokenStore.invalidateCache()
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
            refreshStatusItem()
        } catch {
            transportFailures = 0
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
        cachedCredential = SessionCredential(cookie: cookie, source: .keychain)
        cachedPlan = nil
        planFetchedAt = nil
        statusMessage = nil
        Task { await refreshUsage() }
        return nil
    }

    func forgetPastedToken() {
        KeychainTokenStore.delete()
        suppressKeychain = false
        hasPastedToken = false
        cachedCredential = nil
        cachedPlan = nil
        planFetchedAt = nil
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

    func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func currentUsageInterval() -> TimeInterval {
        UsageSchedule.usageInterval(panelOpen: panelVisible, transportFailures: transportFailures)
    }

    private func credentialForRefresh() -> Result<SessionCredential, AuthFailure> {
        if let cachedCredential,
           cachedCredential.source == .keychain,
           !SessionCredentialFreshness.isNearExpiry(cachedCredential.cookie) {
            notePastedToken()
            return .success(cachedCredential)
        }
        if cachedCredential?.source == .keychain {
            KeychainTokenStore.invalidateCache()
        }
        let result = SessionResolver.resolve(allowKeychain: !suppressKeychain)
        switch result {
        case let .success(value):
            notePlanOwner(value.cookie)
            // Only a pasted token is reused. Cursor's database is read every refresh.
            cachedCredential = value.source == .keychain ? value : nil
            notePastedToken()
        case .failure:
            cachedCredential = nil
        }
        return result
    }

    /// Drops plan info when the signed-in user changes. A new JWT for the same user does not.
    private func notePlanOwner(_ cookie: String) {
        guard let owner = SessionCredentialFreshness.userIdentity(of: cookie) else { return }
        if let planOwner, planOwner != owner {
            cachedPlan = nil
            planFetchedAt = nil
        }
        planOwner = owner
    }

    /// A denied Keychain prompt is not cached, so a later successful read must show Forget.
    private func notePastedToken() {
        hasPastedToken = KeychainTokenStore.read() != nil
    }

    func noteCpuReading(_ percent: Double?) {
        cpuValue = percent
        if let percent {
            SampleHistory.append(percent, to: &cpuSamples, limit: historyLimit)
        }
        mirrorMachineMetrics()
        refreshStatusItem()
    }

    func noteMemoryReading(_ reading: SystemSampler.Memory?) {
        memoryValue = reading
        if let percent = reading?.percent {
            SampleHistory.append(percent, to: &memorySamples, limit: historyLimit)
        }
        mirrorMachineMetrics()
        refreshStatusItem()
    }

    private func recordNetwork() {
        guard let totals = InterfaceSelection.totals(
            interfaces: LinkCounters.read(),
            primary: PrimaryInterface.name()
        ) else { return }
        let now = Date()
        if let mark = networkMark,
           let down = Throughput.bytesPerSecond(previous: mark.bytesIn, current: totals.bytesIn, seconds: now.timeIntervalSince(mark.at)),
           let up = Throughput.bytesPerSecond(previous: mark.bytesOut, current: totals.bytesOut, seconds: now.timeIntervalSince(mark.at)) {
            networkDownValue = down
            networkUpValue = up
            SampleHistory.append(down, to: &networkDownSamples, limit: historyLimit)
            SampleHistory.append(up, to: &networkUpSamples, limit: historyLimit)
            mirrorMachineMetrics()
        }
        networkMark = (totals.bytesIn, totals.bytesOut, now)
    }

    private func recordBattery(force: Bool) {
        let now = Date()
        let due = now.timeIntervalSince(lastBatterySample) >= UsageSchedule.batteryInterval
        if !force, !due { return }
        guard let reading = BatterySampler.read() else {
            let hadBattery = batteryValue != nil || !batterySamples.isEmpty
            guard hadBattery else {
                if due { lastBatterySample = now }
                return
            }
            batteryValue = nil
            batterySamples = []
            lastBatterySample = now
            mirrorMachineMetrics()
            return
        }
        // A power-source notification with the same charge waits for the normal cadence.
        if batteryValue == reading, !due { return }
        lastBatterySample = now
        batteryValue = reading
        SampleHistory.append(reading.percent, to: &batterySamples, limit: historyLimit)
        mirrorMachineMetrics()
    }

    /// Copies the latest samples into published properties while the panel is open.
    /// The first reading is published too, so the window is not blank before it appears.
    /// Later hidden ticks stay on the private storage and do not rebuild the panel.
    private func mirrorMachineMetrics() {
        let shouldPublish = panelVisible || !seededMachineMetrics
        guard shouldPublish else { return }
        if cpuPercent != cpuValue { cpuPercent = cpuValue }
        if cpuHistory != cpuSamples { cpuHistory = cpuSamples }
        if memory != memoryValue { memory = memoryValue }
        if memoryHistory != memorySamples { memoryHistory = memorySamples }
        if networkDown != networkDownValue { networkDown = networkDownValue }
        if networkUp != networkUpValue { networkUp = networkUpValue }
        if networkDownHistory != networkDownSamples { networkDownHistory = networkDownSamples }
        if networkUpHistory != networkUpSamples { networkUpHistory = networkUpSamples }
        if battery != batteryValue { battery = batteryValue }
        if batteryHistory != batterySamples { batteryHistory = batterySamples }
        // Keep publishing through the second tick so the first CPU percent is in the panel.
        if cpuValue != nil {
            seededMachineMetrics = true
        }
    }

    private func refreshStatusItem() {
        let next = UsageFormatting.statusItem(cpu: cpuValue, memory: memoryValue?.percent)
        if next != renderedStatusParts {
            renderedStatusParts = next
            let drawn = StatusItemArtwork.image(for: next)
            if drawn !== statusImage {
                statusImage = drawn
            }
        }
        let summary = StatusAccessibility.summary(parts: next, authMessage: authMessage)
        if summary != statusAccessibility {
            statusAccessibility = summary
        }
    }

    private func observePowerAndSession() {
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Notification.Name, PauseReason)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, .asleep),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .displaysAsleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive)
        ]
        for (pause, resume, reason) in pairs {
            notificationTokens.append(center.addObserver(forName: pause, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setPause(reason, active: true)
                }
            })
            notificationTokens.append(center.addObserver(forName: resume, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setPause(reason, active: false)
                }
            })
        }
        // Ctrl-Cmd-Q locks the screen without sleep, display sleep, or session resign.
        let distributed = DistributedNotificationCenter.default
        notificationTokens.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setPause(.locked, active: true)
            }
        })
        notificationTokens.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.setPause(.locked, active: false)
            }
        })
    }

    /// MenuBarExtra hides its window instead of closing it, so `willClose` never fires.
    /// The window that becomes key is the panel; resigning key is dismiss.
    private func observePanelWindow() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                self?.notePanelBecameKey(window)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            Task { @MainActor in
                guard let self, window === self.panelWindow else { return }
                self.panelDidClose()
            }
        })
    }

    private func notePanelBecameKey(_ window: NSWindow) {
        guard panelWindow == nil || window === panelWindow else { return }
        panelWindow = window
        panelDidOpen()
    }

    private func setPause(_ reason: PauseReason, active: Bool) {
        let wasSuspended = samplingSuspended
        if active {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }
        guard samplingSuspended != wasSuspended else { return }
        if samplingSuspended {
            dropCPUBaseline = true
            interruptSleepers()
            return
        }
        let waiters = resumeContinuations
        resumeContinuations.removeAll()
        for waiter in waiters {
            Task { @MainActor in
                waiter.resume()
            }
        }
    }

    private func waitWhileSuspended() async {
        guard samplingSuspended else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !samplingSuspended {
                continuation.resume()
                return
            }
            resumeContinuations.append(continuation)
        }
    }

    /// `true` when the wait was cut short because the panel or the machine changed state.
    private func sleep(seconds: TimeInterval, generation: Int) async -> Bool {
        if seconds <= 0 || samplingSuspended || sleepGeneration != generation {
            return sleepGeneration != generation || samplingSuspended
        }
        return await withCheckedContinuation { continuation in
            if samplingSuspended || sleepGeneration != generation || Task.isCancelled {
                continuation.resume(returning: true)
                return
            }
            let box = SleepBox(continuation: continuation)
            sleepers.append(box)
            let tolerance = min(30, max(0.05, seconds * 0.1))
            box.task = Task {
                try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(tolerance))
                await MainActor.run { [weak self] in
                    self?.completeSleep(box, interrupted: false)
                }
            }
        }
    }

    private func interruptSleepers() {
        sleepGeneration &+= 1
        let pending = sleepers
        sleepers.removeAll()
        for box in pending {
            box.finish(interrupted: true)
        }
    }

    private func completeSleep(_ box: SleepBox, interrupted: Bool) {
        sleepers.removeAll { $0 === box }
        box.finish(interrupted: interrupted)
    }
}

private enum PauseReason: Hashable {
    case asleep
    case displaysAsleep
    case locked
    case sessionInactive
}

/// One in-flight `Task.sleep`. Resumed from the main actor, and only once.
private final class SleepBox {
    var continuation: CheckedContinuation<Bool, Never>?
    var task: Task<Void, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(interrupted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        task?.cancel()
        task = nil
        Task { @MainActor in
            continuation.resume(returning: interrupted)
        }
    }
}
