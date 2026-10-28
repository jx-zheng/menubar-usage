import SwiftUI

@main
struct MenuBarUsageApp: App {
    @StateObject private var model: AppModel

    init() {
        if CommandLine.arguments.contains("--dump") {
            DumpReport.runAndExit()
        }
        _model = StateObject(wrappedValue: AppModel())
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanelHost(model: model)
        } label: {
            StatusLabel(model: model)
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct UsagePanelHost: View {
    @ObservedObject var model: AppModel

    var body: some View {
        UsagePanelView(content: model.content, actions: actions)
    }

    private var actions: PanelActions {
        PanelActions(
            refresh: { Task { await model.refreshUsage() } },
            quit: { model.quit() },
            openCursor: { model.openCursor() },
            openDashboard: { model.openDashboard() },
            saveToken: { model.savePastedToken($0) },
            forgetToken: { model.forgetPastedToken() }
        )
    }
}

private struct StatusLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let parts = model.statusParts
        HStack(spacing: 0) {
            if let cpu = parts.cpuPercent {
                metric(symbol: StatusItemParts.cpuSymbol, percent: cpu)
            }
            if parts.cpuPercent != nil, parts.memoryPercent != nil {
                Text(" · ")
            }
            if let memory = parts.memoryPercent {
                metric(symbol: StatusItemParts.memorySymbol, percent: memory)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilitySummary)
    }

    private func metric(symbol: String, percent: String) -> some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .symbolRenderingMode(.monochrome)
            Text(" \(percent)")
                .monospacedDigit()
        }
    }
}
