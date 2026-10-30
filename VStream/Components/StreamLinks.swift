import AddonKit
import AppKit
import SwiftUI

/// Copy/open actions for a stream, like Stremio's "Copy stream link".
enum StreamLinks {
    /// The link someone else could open: the HTTP URL, or the magnet for torrents.
    static func shareable(_ stream: AddonStream) -> String? {
        stream.url?.absoluteString ?? stream.magnetURI ?? stream.externalUrl?.absoluteString
            ?? stream.ytId.map { "https://www.youtube.com/watch?v=\($0)" }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Menu items shared by the stream card's context menu and its "…" button.
struct StreamLinkMenuItems: View {
    var stream: AddonStream
    var play: () -> Void

    var body: some View {
        Button("Play", systemImage: "play.fill", action: play)
        Divider()
        if let link = StreamLinks.shareable(stream) {
            Button("Copy Stream Link", systemImage: "link") { StreamLinks.copy(link) }
        }
        if stream.isTorrent {
            if let magnet = stream.magnetURI, stream.url != nil {
                Button("Copy Magnet Link", systemImage: "point.3.connected.trianglepath.dotted") { StreamLinks.copy(magnet) }
            }
            if let hash = stream.infoHash {
                Button("Copy Info Hash", systemImage: "number") { StreamLinks.copy(hash) }
            }
        }
        if let url = stream.url {
            Button("Open in Browser", systemImage: "safari") { NSWorkspace.shared.open(url) }
        }
    }
}
