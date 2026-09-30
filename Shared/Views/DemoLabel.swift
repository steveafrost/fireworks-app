import SwiftUI
import FireworksCore

/// Says, wherever sample numbers are on screen, that they are not the account's.
///
/// The demo exists so the app can be read before it is configured, and its figures are
/// deliberately indistinguishable from measured ones — so this has to be impossible to
/// miss rather than tasteful. It carries the way out too, so leaving the demo does not
/// mean hunting through Settings for a switch that was never a setting.
///
/// The wording lives in `DemoReading`, in Core, because the popover cannot be
/// screenshotted on a Mac without Screen Recording permission — so what it says is
/// verified by test rather than by eye.
public struct DemoLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    public init() {}

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
            Text(DemoReading.label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
            Text(DemoReading.explanation)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Exit demo") { model.exitDemo() }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .underline()
        }
        .foregroundStyle(Palette.accent(scheme))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Palette.accent(scheme).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
