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
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill")
            if let text = model.menuBarText {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(model.accessibilitySummary)
    }
}
