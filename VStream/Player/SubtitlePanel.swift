import PlayerKit
import SwiftUI
import VStreamCore

/// Subtitle picker modelled on Stremio's: languages on the left, that language's variants in the
/// middle (embedded tracks and addon subtitles), timing and appearance on the right.
struct SubtitlePanel: View {
    @Environment(AppModel.self) private var app
    let player: PlayerModel
    @State private var language: String?

    private static let offID = "__off__"

    /// Tracks grouped by language name, preferred language first, then alphabetical.
    private var groups: [(name: String, tracks: [MediaTrack])] {
        let preferred = app.settings.settings.preferredSubtitleLanguages
        let grouped = Dictionary(grouping: player.subtitleTracks.filter(Self.isReal)) { Languages.name(for: $0.language) }
        return grouped
            .map { (name: $0.key, tracks: $0.value) }
            .sorted { lhs, rhs in
                let l = lhs.tracks.contains { Languages.matches($0.language, any: preferred) }
                let r = rhs.tracks.contains { Languages.matches($0.language, any: preferred) }
                if l != r { return l }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Some addons report failures as fake subtitles (e.g. language "!SubMaker Error").
    private static func isReal(_ track: MediaTrack) -> Bool {
        let name = Languages.name(for: track.language)
        guard let first = name.first, first.isLetter else { return false }
        return !name.localizedCaseInsensitiveContains("error")
    }

    private var selectedLanguage: String {
        if let language { return language }
        if let id = player.selectedSubtitleID, let track = player.subtitleTracks.first(where: { $0.id == id }) {
            return Languages.name(for: track.language)
        }
        return Self.offID
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            column("Languages", width: 190) {
                row(title: "Off", detail: nil, selected: selectedLanguage == Self.offID) {
                    language = Self.offID
                    player.selectSubtitle(nil)
                }
                ForEach(groups, id: \.name) { group in
                    row(title: group.name, detail: "\(group.tracks.count)", selected: selectedLanguage == group.name) {
                        language = group.name
                        if !group.tracks.contains(where: { $0.id == player.selectedSubtitleID }), let first = group.tracks.first {
                            player.selectSubtitle(first.id)
                        }
                    }
                }
            }
            Divider().opacity(0.4)
            column("Variants", width: 270) {
                let tracks = groups.first { $0.name == selectedLanguage }?.tracks ?? []
                if tracks.isEmpty {
                    Text(selectedLanguage == Self.offID ? "Subtitles are off" : "No variants")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    row(
                        title: variantTitle(track, index: index),
                        detail: track.isExternal ? "Addon" : "Embedded",
                        selected: player.selectedSubtitleID == track.id
                    ) {
                        player.selectSubtitle(track.id)
                    }
                }
            }
            Divider().opacity(0.4)
            column("Settings", width: 250) {
                stepper("Delay", value: String(format: "%+.2f s", player.subtitleDelay)) {
                    player.setSubtitleDelay(player.subtitleDelay - 0.25)
                } increase: {
                    player.setSubtitleDelay(player.subtitleDelay + 0.25)
                }
                stepper("Size", value: "\(Int(style.fontSize))") {
                    updateStyle { $0.fontSize = max($0.fontSize - 4, 20) }
                } increase: {
                    updateStyle { $0.fontSize = min($0.fontSize + 4, 90) }
                }
                stepper("Position", value: "\(Int(style.position))%") {
                    updateStyle { $0.position = max($0.position - 2, 60) }
                } increase: {
                    updateStyle { $0.position = min($0.position + 2, 100) }
                }
                Toggle("Background", isOn: Binding(get: { style.backgroundOpacity > 0 }, set: { on in
                    updateStyle { $0.backgroundOpacity = on ? 0.55 : 0 }
                }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            }
        }
        .frame(height: 340)
        .environment(\.colorScheme, .dark)
    }

    private var style: SubtitleStyle { app.settings.settings.subtitleStyle }

    /// Appearance changes persist as the default style and apply immediately.
    private func updateStyle(_ change: (inout SubtitleStyle) -> Void) {
        var style = app.settings.settings.subtitleStyle
        change(&style)
        app.settings.settings.subtitleStyle = style
        player.apply(style)
    }

    private func variantTitle(_ track: MediaTrack, index: Int) -> String {
        if let title = track.title, !title.isEmpty, title != Languages.name(for: track.language) { return title }
        return "\(track.isExternal ? "Subtitle" : "Track") \(index + 1)" + (track.codec.map { " · \($0.uppercased())" } ?? "")
    }

    private func column<Content: View>(_ title: String, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) { content() }
            }
            .scrollIndicators(.never)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .frame(width: width)
    }

    private func row(title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                }
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func stepper(_ title: String, value: String, decrease: @escaping () -> Void, increase: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.callout).fixedSize()
            Spacer(minLength: 8)
            Button(action: decrease) { Image(systemName: "minus").frame(width: 22, height: 22) }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
            Text(value)
                .font(.callout.monospacedDigit())
                .frame(minWidth: 58)
            Button(action: increase) { Image(systemName: "plus").frame(width: 22, height: 22) }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
