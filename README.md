# VStream

Native macOS media player for Stremio addons, built with SwiftUI and Liquid Glass.

- Stremio addon protocol: catalogs, meta, streams, subtitles; install by URL or `stremio://` link
- Playback with libmpv ([Nuvio's MPVKit fork](https://github.com/NuvioMedia/MPVKit/tree/Nuvio), whose MoltenVK context follows window resizes): Metal/MoltenVK, VideoToolbox hardware decoding, HDR/EDR
- Torrent streaming with nuvio-engine (libtorrent, local HTTP range server)
- Debrid: Real-Debrid, TorBox, Premiumize (API key), with automatic P2P fallback
- Stremio account sync (addon collection, library, watch progress) and Trakt (scrobble, history, watchlist)

## Requirements

- macOS 26+, Xcode 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build

```bash
./scripts/bootstrap.sh      # clones ../MPVKit and ../nuvio-engine if missing, fetches the engine xcframework, generates the project
open VStream.xcodeproj
```

From the command line:

```bash
xcodebuild -project VStream.xcodeproj -scheme VStream -configuration Debug -derivedDataPath build/DerivedData build
(cd VStreamKit && swift test)
```

## Layout

| Path | Contents |
|---|---|
| `VStreamKit/Sources/AddonKit` | Addon protocol models, lenient decoding, URL building, HTTP client |
| `VStreamKit/Sources/StremioAPI` | `api.strem.io` client and `LibraryItem` |
| `VStreamKit/Sources/TraktKit` | Trakt device auth, scrobble, sync |
| `VStreamKit/Sources/DebridKit` | Debrid providers and torrent file selection |
| `VStreamKit/Sources/TorrentKit` | nuvio-engine wrapper |
| `VStreamKit/Sources/PlayerKit` | libmpv controller, `PlayerModel`, video view, Now Playing |
| `VStreamKit/Sources/VStreamCore` | Addon store, content service, stream resolver, library, account sync |
| `VStream/` | SwiftUI app |

## Player shortcuts

Space play/pause · ←/→ seek 10 s · ↑/↓ volume · F full screen · M mute · S/A cycle subtitles/audio · N next episode

## Debugging

Debug builds can open the player directly and log state to stderr:

```bash
VSTREAM_DEBUG_PLAY="<https url or magnet>" VSTREAM_MPV_LOG=v \
  build/DerivedData/Build/Products/Debug/VStream.app/Contents/MacOS/VStream
```

Metal API validation is disabled in the scheme because MoltenVK trips it on HDR content.

## Trakt

VStream ships a public Trakt client ID (no secret). Sign-in uses the authorization code flow with PKCE: Connect
opens the browser, and the redirect to `http://localhost:8765/trakt` is captured on the loopback interface.
To use your own Trakt app, register that redirect URI and set its client ID in Settings → Accounts.

## License

GPL-3.0. See [LICENSE](LICENSE). Bundles libmpv/FFmpeg (LGPL) via MPVKit and nuvio-engine (GPL-3.0) with libtorrent (BSD).
