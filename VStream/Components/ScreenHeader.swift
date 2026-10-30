import SwiftUI

/// In-content header that replaces the window toolbar: title on the left, controls on the right,
/// floating on glass above scrolling content.
struct ScreenHeader<Controls: View>: View {
    @Environment(AppModel.self) private var app
    var title: String
    var subtitle: String?
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.bold))
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) { controls }.labelsHidden()
            }
        }
        // Leave room for the floating back button when a page is pushed.
        .padding(.leading, app.path.isEmpty ? 28 : 76)
        .padding(.trailing, 28)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

extension ScreenHeader where Controls == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Floating glass back button used instead of the toolbar's.
struct BackButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            if !app.path.isEmpty { app.path.removeLast() }
        } label: {
            Image(systemName: "chevron.backward")
                .font(.title3.weight(.semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back")
        .padding(.leading, 22)
        .padding(.top, 16)
    }
}
