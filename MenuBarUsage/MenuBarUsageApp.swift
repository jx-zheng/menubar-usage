import AppKit
import SwiftUI

@main
struct MenuBarUsageApp: App {
    @StateObject private var model: AppModel

    init() {
        if let url = statusImageURL() {
            exit(StatusItemArtwork.writePreview(to: url))
        }
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
        // Read the published samples directly so the label invalidates for both.
        let parts = UsageFormatting.statusItem(cpu: model.cpuPercent, memory: model.memory?.percent)
        if let image = StatusItemArtwork.image(for: parts) {
            // One template image, framed to its full point size. A stack gets
            // clipped after the CPU pair, and Text+Image drops the symbols.
            Image(nsImage: image)
                .frame(width: image.size.width, height: image.size.height)
                .fixedSize()
                .accessibilityLabel(model.accessibilitySummary)
        }
    }
}

private func statusImageURL() -> URL? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--dump-status-image"), index + 1 < arguments.count else {
        return nil
    }
    return URL(fileURLWithPath: arguments[index + 1])
}
