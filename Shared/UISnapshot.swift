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
/// critical, over-anchor) get looked at. Add `--render-ui-dark` to render every
/// panel in both appearances.
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

    /// `--render-ui-dark` renders every panel in the dark palette as well. Both
    /// appearances have to be looked at — a colour that reads on the lavender
    /// surface can vanish on Mocha — and the appearance is injected into the
    /// environment rather than taken from the app, so the render cannot depend
    /// on which mode the machine happens to be in.
    private static var wantsDark: Bool {
        CommandLine.arguments.contains("--render-ui-dark")
    }

    @MainActor
    public static func render(to directory: URL, model: AppModel) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if wantsSample {
            model.previewInstallSampleReading()
        }
        let schemes: [ColorScheme] = wantsDark ? [.light, .dark] : [.light]
        var written: [String] = []
        for scheme in schemes {
            for (name, view, size) in panels(model: model) {
                // The opaque backdrop is load-bearing: `ImageRenderer` composites onto
                // a transparent canvas, and text drawn straight onto it comes out
                // blank — text inside a view that has its own fill survives, which is
                // what made a working popover look like it had lost half its rows.
                //
                // `fixedSize(vertical:)` is the second half of that lesson, learned
                // the hard way: a frame *taller* than the content lets a VStack
                // stretch its flexible rows and widen its own gaps, so the spacing in
                // the image is not the spacing in the popover. Pin the height to the
                // content's ideal and the render matches the window — which is also
                // sized to that ideal.
                let framed = view
                    .environment(\.colorScheme, scheme)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(Palette.surface(scheme))
                let renderer = ImageRenderer(content: AnyView(framed))
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let data = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: data),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    print("FIREWORKS --render-ui: could not render \(name)")
                    continue
                }
                let suffix = scheme == .dark ? "-dark" : ""
                let url = directory.appendingPathComponent("\(name)\(suffix).png")
                do {
                    try png.write(to: url)
                    written.append(url.path)
                } catch {
                    print("FIREWORKS --render-ui: could not write \(url.path): \(error)")
                }
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
            ("popover", AnyView(OverviewView(onOpenSettings: {}).environment(model)), CGSize(width: 340, height: 505)),
            // The setup screen is what a fresh install sees, so its preview gets
            // the same shell the popover puts it in — the surface and the inset.
            // Drawn bare it sat flush against the window edge, and the review was
            // of the harness rather than of the card.
            ("popover-empty", AnyView(SetupCard().environment(model)
                .padding(Rhythm.inset)
                .frame(width: Rhythm.width, alignment: .leading)),
             CGSize(width: 340, height: 430)),
            // No settings *pane* here: it is a `Form`, and the offscreen renderer
            // draws one as nothing at all. A blank image is worse than no image —
            // it reads as a broken pane. The account hint is a Core function
            // covered by a test instead.
            //
            // The settings *sidebar* is different, and is worth a picture: it is a
            // list of rows, so it renders, and it is the one place where a mistake
            // is silent — an SF Symbol name that does not resolve draws an empty
            // gap, which no assertion here can catch. Badges are drawn with a
            // version in the update slot so both kinds appear.
            ("settings-sidebar", AnyView(VStack(alignment: .leading, spacing: 7) {
                ForEach(SettingsPane.allCases) { item in
                    SettingsSidebarRow(pane: item, reading: model.reading, availableUpdate: "1.1")
                }
            }
            .padding(12)), CGSize(width: 210, height: 200)),
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
            // The badge on its own: the popover only shows the fire when a real
            // forecast is tight, so a sample at 3.8 days renders without it — and
            // an unverified glyph is how a glyph ships broken.
            Tile(title: "Pace with badge", value: "$2.20/day", note: "~2.4 days left", badge: "🔥")
            Text("after the components").font(.system(size: 12))
        }
        .padding(12)
    }
}
#endif
