import AppKit
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
        // Read the published samples directly so the label invalidates for both.
        let parts = UsageFormatting.statusItem(cpu: model.cpuPercent, memory: model.memory?.percent)
        let tokens = parts.tokens(memorySymbol: Self.memorySymbol)
        Group {
            if tokens.isEmpty {
                EmptyView()
            } else {
                // One Text, not nested stacks. MenuBarExtra sizes a multi-view
                // label to the first pair and clips the memory symbol and percent.
                line(tokens)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilitySummary)
    }

    private static var memorySymbol: String {
        for name in [StatusItemParts.memorySymbol, StatusItemParts.memorySymbolFallback] {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                return name
            }
        }
        return StatusItemParts.memorySymbol
    }

    private func line(_ tokens: [StatusItemParts.Token]) -> Text {
        tokens.reduce(Text("")) { line, token in
            if let symbol = token.symbol {
                let mark = Text(Image(systemName: symbol).symbolRenderingMode(.monochrome))
                return line + mark + Text(" \(token.text)").monospacedDigit()
            }
            return line + Text(" \(token.text) ")
        }
    }
}
