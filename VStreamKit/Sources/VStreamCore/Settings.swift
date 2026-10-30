import DebridKit
import Foundation
import Observation
import PlayerKit
import TorrentKit

public enum TorrentMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Use debrid when configured and cached, otherwise stream peer-to-peer.
    case automatic
    case debridOnly
    case peerToPeerOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "Debrid, then P2P"
        case .debridOnly: "Debrid only"
        case .peerToPeerOnly: "P2P only"
        }
    }
}

public struct AppSettings: Codable, Sendable, Hashable {
    public var debridService: DebridService?
    public var torrentMode: TorrentMode = .automatic
    public var torrent = TorrentSettings()
    public var hardwareDecoding = true
    public var autoplayNextEpisode = true
    public var preferredAudioLanguages: [String] = []
    public var preferredSubtitleLanguages: [String] = []
    public var subtitleStyle = SubtitleStyle()
    public var showAdultCatalogs = false
    /// VStream's Trakt API app; users can replace it with their own.
    public static let defaultTraktClientID = "Gygs0cYBI-9RRis34B3ldyJ9na__i8jAs3ULbuyhqCY"
    public var traktClientID = AppSettings.defaultTraktClientID
    public var hiddenHomeRows: Set<String> = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case debridService, torrentMode, torrent, hardwareDecoding, autoplayNextEpisode, preferredAudioLanguages
        case preferredSubtitleLanguages, subtitleStyle, showAdultCatalogs, traktClientID, hiddenHomeRows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        debridService = try? container.decodeIfPresent(DebridService.self, forKey: .debridService)
        torrentMode = (try? container.decode(TorrentMode.self, forKey: .torrentMode)) ?? defaults.torrentMode
        torrent = (try? container.decode(TorrentSettings.self, forKey: .torrent)) ?? defaults.torrent
        hardwareDecoding = (try? container.decode(Bool.self, forKey: .hardwareDecoding)) ?? defaults.hardwareDecoding
        autoplayNextEpisode = (try? container.decode(Bool.self, forKey: .autoplayNextEpisode)) ?? defaults.autoplayNextEpisode
        preferredAudioLanguages = (try? container.decode([String].self, forKey: .preferredAudioLanguages)) ?? []
        preferredSubtitleLanguages = (try? container.decode([String].self, forKey: .preferredSubtitleLanguages)) ?? []
        subtitleStyle = (try? container.decode(SubtitleStyle.self, forKey: .subtitleStyle)) ?? defaults.subtitleStyle
        showAdultCatalogs = (try? container.decode(Bool.self, forKey: .showAdultCatalogs)) ?? false
        let clientID = (try? container.decode(String.self, forKey: .traktClientID)) ?? ""
        traktClientID = clientID.isEmpty ? AppSettings.defaultTraktClientID : clientID
        hiddenHomeRows = (try? container.decode(Set<String>.self, forKey: .hiddenHomeRows)) ?? []
    }
}

@MainActor
@Observable
public final class SettingsStore {
    public var settings: AppSettings {
        didSet {
            JSONStore.save(settings, to: "settings")
            if oldValue.torrent != settings.torrent {
                let torrent = settings.torrent
                Task { await TorrentStreamer.shared.apply(torrent) }
            }
        }
    }

    /// API key for `settings.debridService`, kept in the Keychain.
    public var debridAPIKey: String {
        didSet { Keychain.set(debridAPIKey.isEmpty ? nil : debridAPIKey, for: "debrid.\(settings.debridService?.rawValue ?? "none")") }
    }

    public init() {
        let settings = JSONStore.load(AppSettings.self, from: "settings") ?? AppSettings()
        self.settings = settings
        debridAPIKey = settings.debridService.flatMap { Keychain.string("debrid.\($0.rawValue)") } ?? ""
        let torrent = settings.torrent
        Task { await TorrentStreamer.shared.apply(torrent) }
    }

    public func selectDebrid(_ service: DebridService?) {
        settings.debridService = service
        debridAPIKey = service.flatMap { Keychain.string("debrid.\($0.rawValue)") } ?? ""
    }

    public var debridProvider: (any DebridProvider)? {
        guard let service = settings.debridService, !debridAPIKey.isEmpty else { return nil }
        return service.provider(apiKey: debridAPIKey)
    }
}
