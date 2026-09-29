import Foundation
import SwiftUI
import FireworksCore

#if os(macOS)
import AppKit

/// Render the UI offscreen and write PNGs.
///
/// This exists because the honest answer to "does the popover look right?" cannot
/// be a screenshot on a Mac where Screen Recording permission is denied: the
/// capture comes back empty. `ImageRenderer` draws the same views into a bitmap
/// with no screen capture involved, so the layout can be inspected — by a person,
/// or by a vision model in a test run.
///
///     Fireworks.app/Contents/MacOS/Fireworks --render-ui /tmp/fireworks-ui
///
/// Add `--render-ui-sample` to draw a synthetic reading instead of whatever is on
/// disk, which is how the states a real account only rarely reaches (low,
/// critical, over-anchor) get looked at.
///
/// Two things this renderer cannot do, both of which have already been mistaken
/// for app bugs — read them before believing a blank panel:
///
/// * **Text needs an opaque backdrop.** `ImageRenderer` composites onto a
///   transparent canvas and silently drops text drawn straight onto it, while
///   text inside a view that has its own fill survives. That is why every panel
///   is drawn over `Palette.surface`; without it half the popover looks empty.
/// * **Controls do not rasterize.** `Toggle`, `Button` and `Link` come out as a
///   yellow "no entry" placeholder. That is the renderer, not the layout: check
///   controls on screen, and use this for the numbers and the arrangement.
public enum UISnapshot {
    public static var requestedDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-ui"), index + 1 < arguments.count else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    private static var wantsSample: Bool {
        CommandLine.arguments.contains("--render-ui-sample")
    }

    @MainActor
    public static func render(to directory: URL, model: AppModel) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if wantsSample {
            model.previewInstallSampleReading()
        }
        var written: [String] = []
        for (name, view, size) in panels(model: model) {
            // The opaque backdrop is load-bearing: `ImageRenderer` composites onto
            // a transparent canvas, and text drawn straight onto it comes out
            // blank — text inside a view that has its own fill survives, which is
            // what made a working popover look like it had lost half its rows.
            let framed = view
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Palette.surface(.light))
            let renderer = ImageRenderer(content: AnyView(framed))
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                print("FIREWORKS --render-ui: could not render \(name)")
                continue
            }
            let url = directory.appendingPathComponent("\(name).png")
            do {
                try png.write(to: url)
                written.append(url.path)
            } catch {
                print("FIREWORKS --render-ui: could not write \(url.path): \(error)")
            }
        }
        for path in written { print("FIREWORKS rendered \(path)") }
        print("FIREWORKS --render-ui done (\(written.count) panels)")
    }

    @MainActor
    private static func panels(model: AppModel) -> [(String, AnyView, CGSize)] {
        // Heights are deliberately generous. A fixed frame *smaller* than the
        // content makes SwiftUI compress the flexible rows — the text-only ones —
        // to nothing, which looks exactly like a layout bug in the app. The real
        // popover is sized by its content, so the snapshot has to allow for it.
        [
            ("popover", AnyView(OverviewView().environment(model)), CGSize(width: 340, height: 900)),
            ("popover-empty", AnyView(SetupCard().environment(model)), CGSize(width: 340, height: 430)),
            ("settings", AnyView(SettingsView().environment(model)), CGSize(width: 460, height: 760)),
            ("probe", AnyView(probe), CGSize(width: 340, height: 340))
        ]
    }

    /// The isolation harness: the same components the popover uses, laid out on
    /// their own, plus the two plainest text cases there are. When a rendered
    /// panel loses some rows, this says whether the component or the context is
    /// at fault.
    private static var probe: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("plain text, no modifiers").font(.system(size: 12))
            Text("secondary text").font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("hstack left").font(.system(size: 12))
                Spacer(minLength: 8)
                Text("hstack right").font(.system(size: 12))
            }
            HStack(spacing: 8) {
                Circle().fill(.purple).frame(width: 7, height: 7)
                Text("with a dot").font(.system(size: 11))
                Spacer(minLength: 4)
                Text("$1.00").font(.system(size: 11)).monospacedDigit()
            }
            MetricRow(label: "MetricRow", value: "$1.00", note: "note")
            Tile(title: "Tile", value: "$2.00", note: "note")
            Text("after the components").font(.system(size: 12))
        }
        .padding(12)
    }
}
#endif
