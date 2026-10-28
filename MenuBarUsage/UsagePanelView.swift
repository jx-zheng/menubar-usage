import AppKit
import SwiftUI

struct UsagePanelView: View {
    var content: PanelContent
    var actions: PanelActions

    @State private var pastedToken = ""
    @State private var pasteNote: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("This Mac")
                machineCard(
                    symbol: "cpu",
                    title: "CPU",
                    value: content.cpuPercent.map(UsageFormatting.menuPercent) ?? "—",
                    detail: "All cores",
                    percent: content.cpuPercent
                )
                machineCard(
                    symbol: "memorychip",
                    title: "Memory",
                    value: content.memoryUsed.flatMap { _ in content.memoryPercent.map(UsageFormatting.menuPercent) } ?? "—",
                    detail: memoryDetail,
                    percent: content.memoryPercent
                )

                sectionTitle("AI usage")
                if let authMessage = content.authMessage {
                    signIn(message: authMessage)
                } else if content.rows.isEmpty && content.isRefreshing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking Cursor…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(content.rows) { row in
                        usageCard(row)
                    }
                }
                tokenControls
            }
            .padding(14)

            Divider().opacity(0.6)
            footer
        }
        .frame(width: 332)
        .background(panelBackground)
    }

    private var panelBackground: Color {
        Color(nsColor: colorScheme == .dark ? .windowBackgroundColor : .windowBackgroundColor)
    }

    private var memoryDetail: String {
        guard let used = content.memoryUsed, let total = content.memoryTotal, total > 0 else {
            return "Used of installed"
        }
        return "\(ByteText.string(used)) of \(ByteText.string(total))"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 32, height: 32)
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Usage")
                    .font(.headline)
                if let note = content.note, content.authMessage == nil {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("CPU, memory, and included AI")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let plan = content.planName, content.authMessage == nil {
                Text(plan)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
                Button("Dashboard", action: actions.openDashboard)
                Button("Quit", action: actions.quit)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var updatedLine: String {
        guard let updated = content.updatedAt else { return "Not updated yet" }
        return "Updated \(updated.formatted(date: .omitted, time: .shortened))"
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign in to Cursor")
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Usage percentages stay blank until a real session answers. Nothing is filled in as a guess.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Button("Open Cursor", action: actions.openCursor)
                    .buttonStyle(.borderedProminent)
                Button("Usage dashboard", action: actions.openDashboard)
                    .buttonStyle(.bordered)
            }
            .controlSize(.regular)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(cardStroke)
    }

    private func machineCard(symbol: String, title: String, value: String, detail: String, percent: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let percent {
                UsageBar(percent: percent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(cardStroke)
        .accessibilityElement(children: .combine)
    }

    private func usageCard(_ row: UsageRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(.callout.weight(.medium))
                Spacer()
                Text(row.percentText)
                    .font(.callout.weight(.semibold))
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(cardStroke)
        .accessibilityElement(children: .combine)
    }

    private var cardFill: Color {
        Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .controlBackgroundColor)
    }

    private var cardStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 1)
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
    static func string(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.includesUnit = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}

enum ResetText {
    static func line(for date: Date, now: Date = Date()) -> String {
        let day = date.formatted(.dateTime.month(.abbreviated).day().year())
        guard date > now else { return "Reset \(day)" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
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

#Preview("Signed in") {
    UsagePanelView(
        content: PanelContent(
            cpuPercent: 12,
            memoryUsed: 18_400_000_000,
            memoryTotal: 36_000_000_000,
            planName: "Pro+",
            rows: [
                UsageRow(id: "grok", title: "Grok Bot", detail: "", percent: 12.7, resetsAt: Date().addingTimeInterval(3 * 86_400)),
                UsageRow(id: "cursor", title: "Cursor models", detail: "", percent: 34.4, resetsAt: Date().addingTimeInterval(8 * 86_400))
            ],
            isRefreshing: false,
            sessionLabel: "Cursor",
            hasPastedToken: false
        ),
        actions: PanelActions(refresh: {}, quit: {}, openCursor: {}, openDashboard: {}, saveToken: { _ in nil }, forgetToken: {})
    )
}

#Preview("Sign in") {
    UsagePanelView(
        content: PanelContent(
            cpuPercent: 8,
            memoryUsed: 20_000_000_000,
            memoryTotal: 36_000_000_000,
            rows: [],
            authMessage: "Cursor is not signed in on this Mac.",
            isRefreshing: false,
            hasPastedToken: false
        ),
        actions: PanelActions(refresh: {}, quit: {}, openCursor: {}, openDashboard: {}, saveToken: { _ in nil }, forgetToken: {})
    )
}
