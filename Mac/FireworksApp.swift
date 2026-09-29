import SwiftUI
import AppKit
import FireworksCore

/// The Mac app: a menu-bar item and a popover, and nothing else. There is no
/// window to close, no Dock icon to quit from — which is why the refresh loop is
/// started by the app delegate rather than by a view. A menu-bar app whose data
/// only updates while its popover is open would be a worse version of the plugin
/// it replaces.
@main
struct FireworksApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            OverviewView(onOpenSettings: { openSettings() })
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    /// SwiftUI's Settings scene is opened through the environment on macOS 14+,
    /// but `openSettings` is only available inside a Scene, so it lives here and
    /// is handed to the popover as a closure.
    @Environment(\.openSettings) private var openSettings
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Diagnostics.log("launch: delegate didFinishLaunching")
        if let directory = UISnapshot.requestedDirectory {
            UISnapshot.render(to: directory, model: AppModel.shared)
            NSApp.terminate(nil)
            return
        }
        Task { await AppModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }
}

/// The menu-bar label. It is separate from the view so it can be observed
/// independently — the text has to move on every refresh, and the popover is
/// usually closed while that happens.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let reading = model.reading, model.config.anchorBalance > 0 {
            let ink = Palette.ink(remaining: reading.remaining,
                                  low: model.config.lowThreshold,
                                  critical: model.config.criticalThreshold,
                                  scheme: scheme)
            HStack(spacing: 3) {
                Image(systemName: reading.remaining <= 0 ? "flame.fill" : "flame")
                Text(short(reading.remaining))
                    .monospacedDigit()
            }
            .foregroundStyle(ink)
            .help("\(Money.formatted(reading.remaining)) left of \(Money.formatted(reading.anchorBalance)) · \(Money.formatted(reading.spend)) spent since \(Time.displayStamp(reading.anchorTime))")
        } else {
            Image(systemName: "flame")
                .help(model.freshnessText())
        }
    }

    /// "8.44" rather than "$8.44": in a menu bar the currency is noise, but the
    /// cents are not — they are what moves.
    private func short(_ value: Double) -> String {
        let text = String(format: "%.2f", value)
        return text.hasPrefix("-") ? "−" + text.dropFirst() : text
    }
}
