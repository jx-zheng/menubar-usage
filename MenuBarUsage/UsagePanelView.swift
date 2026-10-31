import AppKit
import SwiftUI

struct UsagePanelView: View {
    var content: PanelContent
    var actions: PanelActions

    @State private var pastedToken = ""
    @State private var pasteNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                macMetrics
                Divider().opacity(0.6).padding(.top, 4)
                aiSection
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider().opacity(0.6)
            footer
        }
        .frame(width: 332)
        .background(panelBackground)
    }

    private var panelBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var macMetrics: some View {
        VStack(alignment: .leading, spacing: 0) {
            cpuRow
            metricDivider
            memoryRow
            metricDivider
            networkRow
            if content.battery != nil {
                metricDivider
                batteryRow
            }
        }
    }

    private var metricDivider: some View {
        Divider().opacity(0.45)
    }

    private var cpuRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                metricIcon("cpu")
                Text("CPU")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text(cpuText)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            Text("All cores")
                .font(.caption)
                .foregroundStyle(.secondary)
            if content.cpuHistory.count >= 2 {
                LevelSparkline(values: content.cpuHistory, height: 26, filled: true)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.cpuPercent == nil ? "CPU, unavailable, All cores" : "CPU, \(cpuText), All cores")
    }

    private var cpuText: String {
        content.cpuPercent.map(UsageFormatting.menuPercent) ?? "—"
    }

    private var memoryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                metricIcon("memorychip")
                Text("Memory")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text(memoryPercentText)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            if let memoryDetail {
                Text(memoryDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if content.memoryHistory.count >= 2 {
                LevelSparkline(values: content.memoryHistory, height: 26, filled: true)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(memoryAccessibility)
    }

    private var memoryPercentText: String {
        guard content.memoryUsed != nil, let percent = content.memoryPercent else { return "—" }
        return UsageFormatting.menuPercent(percent)
    }

    private var memoryDetail: String? {
        guard let used = content.memoryUsed, let total = content.memoryTotal, total > 0 else { return nil }
        return "\(ByteText.string(used)) of \(ByteText.string(total))"
    }

    private var memoryAccessibility: String {
        guard content.memoryUsed != nil, content.memoryPercent != nil else {
            return "Memory, unavailable"
        }
        var parts = ["Memory", memoryPercentText]
        if let memoryDetail {
            parts.append(memoryDetail)
        }
        return parts.joined(separator: ", ")
    }

    private var networkRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                metricIcon("arrow.up.arrow.down")
                Text("Network")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text(downLabel)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                Text(upLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if content.networkDownHistory.count >= 2, content.networkUpHistory.count >= 2 {
                DualSparkline(down: content.networkDownHistory, up: content.networkUpHistory)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network, down \(downLabel), up \(upLabel)")
    }

    private var downLabel: String {
        content.networkDown.map { "↓ \(Throughput.rate($0))" } ?? "↓ —"
    }

    private var upLabel: String {
        content.networkUp.map { "↑ \(Throughput.rate($0))" } ?? "↑ —"
    }

    private var batteryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                metricIcon(batterySymbol)
                Text("Battery")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text(content.battery.map { UsageFormatting.menuPercent($0.percent) } ?? "—")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                if let source = content.battery?.source.label {
                    Text(source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let caption = content.battery?.timeCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if content.batteryHistory.count >= 2 {
                LevelSparkline(values: content.batteryHistory)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var batterySymbol: String {
        switch content.battery?.source {
        case .charging: return "bolt.fill"
        case .powerAdapter: return "powerplug"
        case .battery, nil: return "battery.100"
        }
    }

    private func metricIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 16)
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionTitle("AI usage")
                Spacer(minLength: 8)
                if let plan = content.planName, content.authMessage == nil {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = content.note, content.authMessage == nil {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let authMessage = content.authMessage {
                signIn(message: authMessage)
            } else if content.rows.isEmpty && content.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Cursor…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(content.rows) { row in
                    usageRow(row)
                }
            }
            tokenControls
        }
        .padding(.top, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if content.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Text(updatedLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let session = content.sessionLabel, content.authMessage == nil {
                    Text(session)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let status = content.statusMessage, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(action: actions.refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(content.isRefreshing)
                Spacer(minLength: 0)
                Button("Activity Monitor", action: actions.openActivityMonitor)
                Button("Quit", action: actions.quit)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var updatedLine: String {
        guard let updated = content.updatedAt else { return "AI usage not loaded yet" }
        return "AI updated \(updated.formatted(date: .omitted, time: .shortened))"
    }

    private var tokenControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(content.hasPastedToken ? "Pasted session token" : "Paste a session token") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved only in this Mac's login Keychain. It is not written into the app or the repo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SecureField("WorkosCursorSessionToken", text: $pastedToken)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save in Keychain") {
                            let result = actions.saveToken(pastedToken)
                            if let result {
                                pasteNote = result
                            } else {
                                pastedToken = ""
                                pasteNote = "Saved in the Keychain."
                            }
                        }
                        .disabled(pastedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if content.hasPastedToken {
                            Button("Forget", action: actions.forgetToken)
                        }
                    }
                    .controlSize(.small)
                    if let pasteNote {
                        Text(pasteNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
    }

    private func signIn(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(content.authTitle ?? "Sign in to Cursor")
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Usage percentages stay blank until a real session answers. Nothing is filled in as a guess.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Cursor", action: actions.openCursor)
                    .buttonStyle(.borderedProminent)
                Button("Usage dashboard", action: actions.openDashboard)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }

    private func usageRow(_ row: UsageRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.callout)
                Spacer(minLength: 8)
                Text(row.percentText)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(row.percent.map { UsageBar.tint(for: $0) } ?? Color.primary)
            }
            if !row.detail.isEmpty {
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let percent = row.percent, !row.unlimited {
                UsageBar(percent: percent)
            }
            if let reset = row.resetsAt {
                Text(ResetText.line(for: reset))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
    }
}

private extension PanelContent {
    var memoryPercent: Double? {
        guard let used = memoryUsed, let total = memoryTotal, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }
}

enum ByteText {
    /// Shared by the panel. Byte count formatting happens on the main thread.
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.includesUnit = true
        return formatter
    }()

    static func string(_ bytes: UInt64) -> String {
        formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

enum ResetText {
    /// Shared by the panel. Relative formatting happens on the main thread.
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func line(for date: Date, now: Date = Date()) -> String {
        let day = date.formatted(.dateTime.month(.abbreviated).day().year())
        guard date > now else { return "Reset \(day)" }
        return "Resets \(day) · \(relative.localizedString(for: date, relativeTo: now))"
    }
}

struct UsageBar: View {
    var percent: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(percent, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                if fraction > 0 {
                    Capsule()
                        .fill(Self.tint(for: percent))
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 7)
        .accessibilityHidden(true)
    }

    static func tint(for percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 75 { return .orange }
        return .green
    }
}

private struct DualSparkline: View {
    var down: [Double]
    var up: [Double]

    var body: some View {
        Canvas { context, size in
            let count = min(down.count, up.count)
            guard count >= 2 else { return }
            let peak = max(down.suffix(count).max() ?? 0, up.suffix(count).max() ?? 0, 1)
            stroke(down.suffix(count), peak: peak, color: Color.green, in: context, size: size)
            stroke(up.suffix(count), peak: peak, color: Color.secondary.opacity(0.9), in: context, size: size)
        }
        .frame(height: 22)
        .accessibilityHidden(true)
    }

    private func stroke(
        _ values: ArraySlice<Double>,
        peak: Double,
        color: Color,
        in context: GraphicsContext,
        size: CGSize
    ) {
        var path = Path()
        let last = CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let x = size.width * CGFloat(index) / last
            let y = size.height * (1 - CGFloat(max(0, value) / peak))
            let point = CGPoint(x: x, y: min(max(y, 0), size.height))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
    }
}

private struct LevelSparkline: View {
    var values: [Double]
    var height: CGFloat = 18
    var filled: Bool = false

    var body: some View {
        Canvas { context, size in
            guard values.count >= 2 else { return }
            var line = Path()
            let last = CGFloat(values.count - 1)
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / last
                let y = size.height * (1 - CGFloat(min(max(value, 0), 100) / 100))
                let point = CGPoint(x: x, y: y)
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            if filled {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(Color.accentColor.opacity(0.18)))
            }
            let lineWidth: CGFloat = filled ? 1.5 : 1.25
            context.stroke(
                line,
                with: .color(Color.accentColor),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

#Preview("Signed in") {
    UsagePanelView(
        content: PanelContent(
            cpuPercent: 12,
            cpuHistory: [22, 28, 18, 14, 16, 12, 19, 11, 9, 13, 12],
            memoryUsed: 18_400_000_000,
            memoryTotal: 36_000_000_000,
            memoryHistory: [44, 45, 47, 46, 48, 49, 50, 51, 50, 51, 51],
            networkDown: 1_250_000,
            networkUp: 84_000,
            networkDownHistory: [400_000, 900_000, 1_250_000, 700_000],
            networkUpHistory: [40_000, 80_000, 84_000, 50_000],
            battery: BatteryStatus(percent: 86, source: .charging, minutesRemaining: 75),
            batteryHistory: [80, 82, 84, 86],
            planName: "Pro+",
            rows: [
                UsageRow(id: "grok", title: "Grok Bot", detail: "", percent: 12.7, resetsAt: Date().addingTimeInterval(3 * 86_400)),
                UsageRow(id: "cursor", title: "Cursor models", detail: "", percent: 34.4, resetsAt: Date().addingTimeInterval(8 * 86_400)),
                UsageRow(id: "other", title: "Other models", detail: "", percent: 0, resetsAt: Date().addingTimeInterval(8 * 86_400))
            ],
            isRefreshing: false,
            sessionLabel: "Cursor",
            hasPastedToken: false
        ),
        actions: PanelActions(refresh: {}, quit: {}, openCursor: {}, openDashboard: {}, openActivityMonitor: {}, saveToken: { _ in nil }, forgetToken: {})
    )
}

#Preview("Sign in") {
    UsagePanelView(
        content: PanelContent(
            cpuPercent: 8,
            cpuHistory: [4, 6, 5, 8],
            memoryUsed: 20_000_000_000,
            memoryTotal: 36_000_000_000,
            memoryHistory: [52, 53, 55, 56],
            rows: [],
            authMessage: "Cursor is not signed in on this Mac.",
            isRefreshing: false,
            hasPastedToken: false
        ),
        actions: PanelActions(refresh: {}, quit: {}, openCursor: {}, openDashboard: {}, openActivityMonitor: {}, saveToken: { _ in nil }, forgetToken: {})
    )
}
