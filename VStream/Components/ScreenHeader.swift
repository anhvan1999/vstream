import SwiftUI

/// In-content header that replaces the window toolbar: title on the left, controls on the right.
/// It is the first item of the page's scroll content, so it scrolls away instead of floating over posters.
/// On the Mac a tab's own page puts its controls in the window toolbar; on iPad it shows only the
/// controls (the highlighted sidebar row or tab already names the page). Pushed pages and iPhone,
/// with its large titles, keep the title.
struct ScreenHeader<Controls: View>: View {
    @Environment(AppModel.self) private var app
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    var title: String
    var subtitle: String?
    @ViewBuilder var controls: Controls

    var body: some View {
        #if os(macOS)
        // A tab's own page on the Mac: its controls are in the window toolbar (`pageControls`).
        if showsTitle { inPageHeader }
        #else
        inPageHeader
        #endif
    }

    private var inPageHeader: some View {
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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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
        .padding(.top, besideTabStrip ? 30 : 16)
        // iPad: level with the floating tab strip (centred, so its left side is free) rather than
        // below it, where the top safe area would put it.
        .ignoresSafeArea(edges: besideTabStrip ? .top : [])
    }

    private var besideTabStrip: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }
}

extension View {
    /// The Mac shows a tab page's controls centred in the window toolbar, each in its own glass
    /// capsule. Applied to the page itself, outside its scroll view, so they stay put while
    /// scrolling. iPhone/iPad keep them in the page header.
    func pageControls<Controls: View>(@ViewBuilder _ controls: () -> Controls) -> some View {
        #if os(macOS)
        toolbar {
            ToolbarItem(placement: .principal) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        // Modifiers on a Group apply to each control separately.
                        Group { controls() }
                            .labelsHidden()
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
        #else
        self
        #endif
    }
}

extension View {
    /// The top edge of a scrolling page. The Mac window hides its title bar, so once the page is
    /// scrolled a title-bar-style backdrop (bar material and a hairline) appears behind the
    /// toolbar, the way a real title bar picks up its background; at the top the page shows
    /// through. iPhone/iPad use the soft fade under their floating bars.
    func pageScrollEdge() -> some View {
        #if os(macOS)
        modifier(TitleBarBackdrop())
        #else
        scrollEdgeEffectStyle(.soft, for: .top)
        #endif
    }
}

#if os(macOS)
private struct TitleBarBackdrop: ViewModifier {
    @State private var isScrolled = false
    /// The toolbar's height when the page doesn't report it as a safe area.
    private static let toolbarHeight: CGFloat = 52

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 2
            } action: { _, scrolled in
                isScrolled = scrolled
            }
            .overlay(alignment: .top) {
                GeometryReader { proxy in
                    let inset = proxy.safeAreaInsets.top
                    Rectangle()
                        .fill(.bar)
                        .overlay(alignment: .bottom) { Divider() }
                        .frame(height: inset > 0 ? inset : Self.toolbarHeight)
                        .offset(y: -inset)
                        .opacity(isScrolled ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: isScrolled)
                }
                .allowsHitTesting(false)
            }
    }
}
#endif
