import SwiftUI

/// In-content header that replaces the window toolbar: title on the left, controls on the right.
/// It is the first item of the page's scroll content, so it scrolls away instead of floating over posters.
/// On the Mac and iPad a tab's own page drops the title (the highlighted sidebar row or tab already
/// names it) and keeps the subtitle; pushed pages and iPhone, with its large titles, keep it.
struct ScreenHeader<Controls: View>: View {
    @Environment(AppModel.self) private var app
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    var title: String
    var subtitle: String?
    @ViewBuilder var controls: Controls

    var body: some View {
        Group {
            if isCompact {
                // iPhone: a large title, with the controls on their own swipeable row below.
                VStack(alignment: .leading, spacing: 12) {
                    titleBlock(font: .largeTitle.weight(.bold))
                    ScrollView(.horizontal) {
                        GlassEffectContainer(spacing: 8) {
                            HStack(spacing: 8) { controls }.labelsHidden()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.never)
                    .padding(.horizontal, -16)
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    if showsTitle {
                        titleBlock(font: .title2.weight(.bold))
                    } else if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) { controls }.labelsHidden()
                    }
                }
            }
        }
        // Leave room for the floating back button when a page is pushed.
        .padding(.leading, isCompact ? 16 : (app.path.isEmpty ? 28 : 76))
        .padding(.trailing, isCompact ? 16 : 28)
        .padding(.top, isCompact ? 8 : 18)
        .padding(.bottom, 12)
    }

    private func titleBlock(font: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(font)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var showsTitle: Bool { !app.path.isEmpty }

    private var isCompact: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
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
