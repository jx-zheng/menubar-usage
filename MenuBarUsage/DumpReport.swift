import Foundation

enum DumpReport {
    struct Row: Encodable {
        var id: String
        var title: String
        var percent: Double?
        var resetsAt: String?
    }

    struct Payload: Encodable {
        var cpuPercent: Double?
        var memoryUsedBytes: UInt64?
        var memoryTotalBytes: UInt64?
        var memoryPercent: Double?
        var auth: String
        var plan: String?
        var note: String?
        var rows: [Row]
        var status: String?
    }

    static func runAndExit() -> Never {
        let box = DumpBox()
        Task {
            let payload = await make()
            box.payload = payload
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
        if let payload = box.payload {
            print(payload)
        }
        exit(0)
    }

    static func make() async -> String {
        let previous = SystemSampler.cpuTicks()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let current = SystemSampler.cpuTicks()
        let cpu = previous.flatMap { earlier in
            current.flatMap { SystemSampler.cpuPercent(from: earlier, to: $0) }
        }
        let memory = SystemSampler.memory()

        let credential: SessionCredential
        switch SessionResolver.resolve() {
        case let .success(value):
            credential = value
        case let .failure(failure):
            return encode(Payload(
                cpuPercent: cpu,
                memoryUsedBytes: memory?.usedBytes,
                memoryTotalBytes: memory?.totalBytes,
                memoryPercent: memory?.percent,
                auth: failure.dumpLabel,
                plan: nil,
                note: nil,
                rows: [],
                status: failure.message
            ))
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
            let presentation = UsagePresenter.present(facts)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return encode(Payload(
                cpuPercent: cpu,
                memoryUsedBytes: memory?.usedBytes,
                memoryTotalBytes: memory?.totalBytes,
                memoryPercent: memory?.percent,
                auth: credential.source == .keychain ? "keychain" : "cursor-database",
                plan: presentation.planName,
                note: presentation.note,
                rows: presentation.rows.map { row in
                    Row(
                        id: row.id,
                        title: row.title,
                        percent: row.percent,
                        resetsAt: row.resetsAt.map { formatter.string(from: $0) }
                    )
                },
                status: fetch.sandFailed ? "sand-unavailable" : nil
            ))
        } catch let error as UsageClientError {
            let auth = error.isUnauthorized ? "rejected" : credential.source == .keychain ? "keychain" : "cursor-database"
            return encode(Payload(
                cpuPercent: cpu,
                memoryUsedBytes: memory?.usedBytes,
                memoryTotalBytes: memory?.totalBytes,
                memoryPercent: memory?.percent,
                auth: auth,
                plan: nil,
                note: nil,
                rows: [],
                status: error.localizedDescription
            ))
        } catch {
            return encode(Payload(
                cpuPercent: cpu,
                memoryUsedBytes: memory?.usedBytes,
                memoryTotalBytes: memory?.totalBytes,
                memoryPercent: memory?.percent,
                auth: credential.source == .keychain ? "keychain" : "cursor-database",
                plan: nil,
                note: nil,
                rows: [],
                status: "The usage service could not be reached."
            ))
        }
    }

    private static func encode(_ payload: Payload) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) else {
            return "{\"auth\":\"unreadable\"}"
        }
        return text
    }
}

private final class DumpBox: @unchecked Sendable {
    var payload: String?
}

private extension UsageClientError {
    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}
