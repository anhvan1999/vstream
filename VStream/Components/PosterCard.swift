import AddonKit
import NukeUI
import SwiftUI

struct RemoteImage: View {
    var url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .processors([])
        .priority(.normal)
        .animation(.easeOut(duration: 0.2), value: url)
    }
}

struct PosterCard: View {
    var title: String
    var poster: URL?
    var shape: PosterShape = .poster
    var width: CGFloat = 150
    var subtitle: String?
    var progress: Double?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Overlays, not a ZStack: the flexible progress bar would widen the card to its grid
            // cell and leave bars beside the poster.
            RemoteImage(url: poster)
                .frame(width: width, height: width / shape.aspectRatio)
                .overlay {
                    if poster == nil {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(8)
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                    }
                }
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(isHovering ? 0.35 : 0.08), lineWidth: 1))
            .shadow(color: .black.opacity(isHovering ? 0.35 : 0.15), radius: isHovering ? 14 : 6, y: isHovering ? 8 : 3)
            .scaleEffect(isHovering ? 1.04 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .animation(.spring(duration: 0.25), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(.rect)
    }
}

/// A titled horizontal shelf.
struct Shelf<Content: View, Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                accessory
            }
            .padding(.horizontal, 28)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    content
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
        }
    }
}

extension Shelf where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        accessory = EmptyView()
        self.content = content()
    }
}

/// Adaptive poster grid used by Discover, Library and "See all".
struct PosterGrid<Item: Identifiable, Cell: View>: View {
    var items: [Item]
    var minWidth: CGFloat = 150
    var onReachEnd: (() -> Void)?
    @ViewBuilder var cell: (Item) -> Cell

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth, maximum: minWidth + 30), spacing: 18, alignment: .top)], spacing: 22) {
            ForEach(items) { item in
                cell(item)
                    .onAppear {
                        if item.id == items.last?.id { onReachEnd?() }
                    }
            }
        }
        .padding(28)
    }
}

struct EmptyStateView: View {
    var title: String
    var symbol: String
    var message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
