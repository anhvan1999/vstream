import AppKit
import MediaAccessibility
import SwiftUI

/// The user's caption style from System Settings → Accessibility → Captions, read through
/// MediaAccessibility like the Apple TV app does.
struct SystemCaptionStyle: Equatable {
    var font: NSFont
    var relativeSize: CGFloat
    var textColor: Color
    /// Behind each line of text.
    var backgroundColor: Color
    /// Behind the whole caption block.
    var windowColor: Color
    var windowCornerRadius: CGFloat
    var edge: MACaptionAppearanceTextEdgeStyle

    static let changed = Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)

    static func current() -> SystemCaptionStyle {
        let domain = MACaptionAppearanceDomain.user
        func color(_ copy: (MACaptionAppearanceDomain, UnsafeMutablePointer<MACaptionAppearanceBehavior>?) -> Unmanaged<CGColor>, opacity: CGFloat) -> Color {
            let cgColor = copy(domain, nil).takeRetainedValue()
            return Color(nsColor: NSColor(cgColor: cgColor) ?? .clear).opacity(opacity)
        }
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, nil, .default).takeRetainedValue()
        return SystemCaptionStyle(
            font: NSFont(descriptor: descriptor, size: 0) ?? .systemFont(ofSize: 0, weight: .medium),
            relativeSize: MACaptionAppearanceGetRelativeCharacterSize(domain, nil),
            textColor: color(MACaptionAppearanceCopyForegroundColor, opacity: MACaptionAppearanceGetForegroundOpacity(domain, nil)),
            backgroundColor: color(MACaptionAppearanceCopyBackgroundColor, opacity: MACaptionAppearanceGetBackgroundOpacity(domain, nil)),
            windowColor: color(MACaptionAppearanceCopyWindowColor, opacity: MACaptionAppearanceGetWindowOpacity(domain, nil)),
            windowCornerRadius: MACaptionAppearanceGetWindowRoundedCornerRadius(domain, nil),
            edge: MACaptionAppearanceGetTextEdgeStyle(domain, nil)
        )
    }

    /// Opens the Captions pane of System Settings.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Captions")!
}

/// Caption lines drawn with the system style: each line on its background, the block on the
/// window color.
struct SystemCaptionText: View {
    var text: String
    var style: SystemCaptionStyle
    /// Height of the video picture; captions scale with it.
    var videoHeight: CGFloat

    var body: some View {
        let size = max(videoHeight * 0.05 * style.relativeSize, 12)
        VStack(spacing: size * 0.12) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(Font(style.font.withSize(size)))
                    .foregroundStyle(style.textColor)
                    .modifier(EdgeEffect(edge: style.edge, size: size))
                    .padding(.horizontal, size * 0.3)
                    .padding(.vertical, size * 0.06)
                    .background(style.backgroundColor, in: .rect(cornerRadius: size * 0.15))
            }
        }
        .multilineTextAlignment(.center)
        .padding(size * 0.25)
        .background(style.windowColor, in: .rect(cornerRadius: style.windowCornerRadius))
    }

    private struct EdgeEffect: ViewModifier {
        var edge: MACaptionAppearanceTextEdgeStyle
        var size: CGFloat

        func body(content: Content) -> some View {
            let unit = max(size / 24, 1)
            switch edge {
            case .dropShadow:
                content.shadow(color: .black.opacity(0.8), radius: unit, x: unit, y: unit)
            case .uniform:
                content
                    .shadow(color: .black, radius: 0, x: unit, y: 0)
                    .shadow(color: .black, radius: 0, x: -unit, y: 0)
                    .shadow(color: .black, radius: 0, x: 0, y: unit)
                    .shadow(color: .black, radius: 0, x: 0, y: -unit)
            case .raised:
                content.shadow(color: .black.opacity(0.9), radius: 0, x: unit, y: unit)
            case .depressed:
                content.shadow(color: .white.opacity(0.6), radius: 0, x: unit, y: unit)
            default:
                content
            }
        }
    }
}
