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
        if let directory = MenuBarDial.probeDirectory {
            MenuBarDial.writeProbe(to: directory)
            NSApp.terminate(nil)
            return
        }
        if let directory = UISnapshot.requestedDirectory {
            UISnapshot.render(to: directory, model: AppModel.shared)
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--open-settings") {
            // A script cannot open an accessory app's Settings window — there is no
            // menu bar to click and no AppleScript command for it — so the only way
            // to measure that window is to have the app open it. WindowSizeProbe
            // logs what it measures; both selectors are sent because the SwiftUI
            // one was renamed between macOS releases.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
        Task { await AppModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }
}

/// The menu-bar label: the dial, and nothing else — the same reading the plugin
/// showed once its dial was asked for (`monochrome_icon`), with the numbers on
/// the tooltip and the panel one click away.
///
/// It is separate from the view so it can be observed independently — the dial
/// has to move on every refresh, and the popover is usually closed while that
/// happens.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if let reading = model.reading, model.config.anchorBalance > 0 {
            Image(nsImage: MenuBarDial.image(fraction: reading.share))
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .help("\(Money.formatted(reading.remaining)) left of \(Money.formatted(reading.anchorBalance))"
                      + " · \(Int((reading.share * 100).rounded()))% left"
                      + " · \(Money.formatted(reading.spend)) spent since \(Time.displayStamp(reading.anchorTime))")
        } else {
            // Unknown is not empty: a dial at zero share is a state someone can
            // be in, so the unconfigured case stays a different glyph.
            Image(systemName: "flame")
                .help(model.freshnessText())
        }
    }
}

/// The dial: how much of the anchor is left, as a ring in the menu bar.
///
/// Drawn as an AppKit template image (`isTemplate`), so macOS tints it — black on
/// a light menu bar, white on a dark one, dimmed when the bar is inactive — which
/// a coloured SwiftUI drawing cannot do for itself. Geometry is the plugin's, to
/// the point: an 18pt ring with a 2pt stroke, swept clockwise from 12 o'clock,
/// with the unused arc left visible at ~28% alpha so an empty dial still reads as
/// a gauge instead of nothing.
///
/// `--render-dial <dir>` writes it at several fractions, because the menu bar
/// itself cannot be screenshotted on a Mac where Screen Recording is denied and
/// "does the ring encode the fraction" is a question about pixels.
enum MenuBarDial {
    /// Calibrated against the system, in the crop's own pixels: the old dial's ink
    /// measured 113px against Control Center's 91px and the calendar's 105px, and
    /// at 16.1pt of ink that makes the crop 7.02px to the point. 100px of ink —
    /// between Control Center and the calendar, where it was asked to sit — is
    /// 14.25pt, so the canvas is 15.25pt (a canvas draws 1pt less ink than its
    /// size). The stroke stays 1.8pt: the system glyphs' walls measure ~13px
    /// there, and a ring thinner than that reads as a drawn circle rather than a
    /// control.
    static let size: CGFloat = 15.25
    static let stroke: CGFloat = 1.8
    /// Alpha of the unfilled track. High enough to read as a ring, low enough
    /// that the filled arc is obviously the figure.
    static let trackAlpha: CGFloat = 70.0 / 255.0

    static func image(fraction: Double, size: CGFloat = MenuBarDial.size) -> NSImage {
        let share = max(0.0, min(1.0, fraction))
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let centre = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2 - stroke / 2 - 0.5

            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = stroke
            NSColor.black.withAlphaComponent(trackAlpha).setStroke()
            track.stroke()

            let sweep = share * 360
            if sweep > 0.5 {
                // From 12 o'clock, clockwise: AppKit measures counter-clockwise
                // from 3 o'clock, so the arc runs 90° → 90° − sweep.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: centre, radius: radius,
                              startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                arc.lineWidth = stroke
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static var probeDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-dial"), index + 1 < arguments.count else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func writeProbe(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scale = 8
        for step in [0.0, 0.12, 0.5, 0.97, 1.0] {
            let dial = image(fraction: step)
            let side = Int(dial.size.width) * scale
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // `.copy` for the clear, `.sourceOver` for the dial: a plain fill with
            // a clear colour blends *over* whatever the buffer held, which is how
            // a first version of this probe wrote five opaque black squares and
            // "measured" them.
            context.compositingOperation = .copy
            NSColor.clear.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
            context.compositingOperation = .sourceOver
            dial.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            let name = String(format: "dial-%03d.png", Int((step * 100).rounded()))
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent(name))
                print("FIREWORKS dial \(name)")
            }
        }
    }
}
