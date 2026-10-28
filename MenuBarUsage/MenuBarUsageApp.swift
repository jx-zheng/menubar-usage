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
        // Machine samples are published only while this window is open, so a
        // hidden panel does not rebuild on the sampler tick. `onAppear` refreshes
        // AI usage when the last result is older than a minute. The body is not
        // gated on that flag: the flag flips in `onAppear`, which is after the
        // first layout, and an empty branch there would flash a blank window.
        // If this host stays mounted after close, `onDisappear` (and the panel
        // window's close notification) stop those publishes. The status item
        // reads a cached image and does not draw a new one for other updates.
        UsagePanelView(content: model.content, actions: actions)
            .onAppear { model.panelDidOpen() }
            .onDisappear { model.panelDidClose() }
    }

    private var actions: PanelActions {
        PanelActions(
            refresh: { Task { await model.refreshUsage() } },
            quit: { model.quit() },
            openCursor: { model.openCursor() },
            openDashboard: { model.openDashboard() },
            openActivityMonitor: { model.openActivityMonitor() },
            saveToken: { model.savePastedToken($0) },
            forgetToken: { model.forgetPastedToken() }
        )
    }
}

private struct StatusLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // `statusImage` changes only when the rounded CPU and memory percents
        // change. Other publishes reuse that NSImage; the bitmap is not rebuilt.
        // One template image, framed to its full point size. A stack gets
        // clipped after the CPU pair, and Text+Image drops the symbols.
        if let image = model.statusImage {
            Image(nsImage: image)
                .frame(width: image.size.width, height: image.size.height)
                .fixedSize()
                .accessibilityLabel(model.statusAccessibility)
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
