# VStream

A native macOS media player for Stremio addons, written in SwiftUI with the Liquid Glass design of macOS 26.
It plays HTTP and torrent streams through libmpv, resolves torrents with debrid services or peer-to-peer, and
keeps your Stremio library and Trakt history in sync.

VStream borrows from [Nuvio](https://github.com/NuvioMedia) (its torrent engine, MPVKit fork and playback
behaviour) and [stremio-core](https://github.com/Stremio/stremio-core) (API and data model).

## Features

### Browse
- **Home**:
  - A rotating hero carousel of featured titles.
  - Continue Watching, including the next episode of shows in progress.
  - Your Trakt watchlist and Trakt recommendations.
  - A row for every addon catalog. Rows that fail or come back empty are hidden.
- **Search** across every addon catalog that supports search.
- **Discover** shows catalogs by type and genre, with infinite paging.
- **Library** shows your Stremio library with watch progress, filtered by type and sortable.
- **Detail page**:
  - A full-window backdrop, plus cast, director, genres and trailer.
  - Library and watched toggles.
  - A season and episode list that shows the episodes you watched in Stremio.

### Watch
- **Stream picker**:
  - Streams are grouped by addon, with a filter chip for each addon and a quality filter.
  - Cards are parsed from Torrentio-style titles: quality, HDR/DV, codec, size, seeders.
  - A ⚡ badge marks torrents that are already cached on your debrid service.
  - "Copy stream link" works like Stremio's.
- **Player**:
  - A separate window that sizes itself to the video's aspect ratio and is the only window that goes full screen.
  - Glass controls and an Apple TV–style scrubber.
  - Audio, subtitle and chapter menus, and playback speed.
  - A Stremio-style subtitle panel with addon subtitles and delay.
  - Text subtitles use your **macOS caption style** (System Settings → Accessibility → Captions), drawn by
    the app like the Apple TV app does. Bitmap (PGS/VobSub) and styled ASS subtitles are left to mpv.
  - Remembers where you stopped and offers the next episode.
  - Supports Now Playing and media keys, and keeps the Mac awake during playback.
- **Default languages** for audio and subtitles, matched by ISO 639 codes and names.
- **Configurable stream buffer**, 512 MB in memory by default.

### Play Link
Plays a stream without an addon:
- **What it accepts:** `http(s)` video or HLS URLs, local video files, magnet links, bare info hashes, and
  `.torrent` files (local or downloaded from a URL).
- **How to open one:**
  - Paste it into the Play Link tab (⌘L).
  - Choose a `.torrent` file (⌘O).
  - Drop a file or link anywhere in the main window.
  - Open a `.torrent` file or a `magnet:` link from Finder or a browser.
- **Multi-file torrents** show a file picker.
- **Recent links** are kept for one-click replay.

These plays are not recorded in Continue Watching or Trakt.

### Torrents and debrid
- Debrid services: **Real-Debrid, TorBox and Premiumize**, each set up with an API key.
- Choosing the file inside a season pack follows Nuvio: by file index, then season and episode, then the largest video.
- Torrent modes:

  | Mode | What it does |
  |---|---|
  | Automatic | Uses debrid when the torrent is cached, otherwise falls back to peer-to-peer |
  | Debrid only | Never streams peer-to-peer |
  | P2P only | Never uses debrid |

- **Add uncached torrents to debrid** (on by default): a torrent that isn't cached is sent to the debrid
  service to download while it streams peer-to-peer, so the next play starts instantly. Debrid-only mode
  queues it instead.
- Peer-to-peer streaming uses nuvio-engine (libtorrent), which serves the selected file over a loopback HTTP range server.
  - The engine prioritises the pieces the player needs next.
  - You can choose a speed profile and the disk cache size, and turn uploading off.

### Accounts and sync
- **Stremio**: sign in with email and password.
  - Syncs your addon collection, library items, watch progress and watched episodes.
  - Watched episodes use Stremio's compressed watched bitfield, so the data round-trips with the official apps.
- **Trakt**: OAuth sign-in in the browser.
  - Scrobbling (start, pause, stop) and history import.
  - Watchlist and recommendation rows on Home.

### Addons
- Install an addon from a manifest URL or a `stremio://` link. The app registers the `stremio://` scheme.
- Reorder addons (earlier addons answer first), enable or disable them, and open an addon's configure page.
- **Browse Community Addons** opens [stremio-addons.net](https://stremio-addons.net).

## Install a release

Download `VStream-<version>.dmg` from [Releases](../../releases) and drag VStream into Applications. Release
builds are ad-hoc signed and not notarized, so macOS blocks them the first time. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/VStream.app
```

Or open the app once, then click **Open Anyway** in System Settings → Privacy & Security. macOS 26 or later is
required. The app is a universal binary (Apple Silicon and Intel).

## Requirements

- macOS 26 or later, Xcode 26 or later (Swift 6.2)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Apple Silicon or Intel. The engine and mpv frameworks are universal.

## Build

```bash
./scripts/bootstrap.sh   # clones ../MPVKit and ../nuvio-engine if missing, fetches the engine
                         # xcframework (checksum-verified), writes signing config, generates the project
open VStream.xcodeproj
```

From the command line:

```bash
xcodebuild -project VStream.xcodeproj -scheme VStream -configuration Release \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages \
  -allowProvisioningUpdates build
(cd VStreamKit && swift test)
```

### Signing
`Config/Signing.xcconfig` signs ad-hoc by default, so anyone can build. When Xcode is signed in to an Apple ID,
`bootstrap.sh` writes the git-ignored `Config/Local.xcconfig` with your team, and the app is then signed with
Apple Development. A stable signature lets the Keychain keep trusting the app across rebuilds. Ad-hoc builds
change their code hash on every build, so macOS asks for Keychain access again each time.

## Architecture

```
VStream (SwiftUI app)
 ├─ VStreamCore   AddonStore · ContentService · StreamResolver · LibraryStore · StremioAccount · TraktAccount · Settings
 │   ├─ AddonKit     addon protocol models, lenient decoding, URL building, HTTP client
 │   ├─ StremioAPI   api.strem.io client, LibraryItem, watched bitfield
 │   ├─ TraktKit     OAuth + PKCE, loopback redirect server, scrobble/sync/lists
 │   ├─ DebridKit    Real-Debrid / TorBox / Premiumize, file selection
 │   └─ TorrentKit   nuvio-engine wrapper, .torrent parser
 └─ PlayerKit     libmpv controller, PlayerModel, Metal video view, Now Playing, sleep assertion
```

| Path | Contents |
|---|---|
| `VStreamKit/Sources/AddonKit` | Manifest, meta, stream and subtitle models; `{base}/{resource}/{type}/{id}[/{extra}].json` URLs; tolerant decoding of real-world addon JSON |
| `VStreamKit/Sources/StremioAPI` | `login`, `addonCollectionGet/Set`, `datastoreMeta/Get/Put`; `LibraryItem` following stremio-core; `WatchedBitfield` |
| `VStreamKit/Sources/TraktKit` | Authorization code + PKCE (public client, no secret), `NWListener` on `localhost:8765`, scrobble, history, watchlist, recommendations |
| `VStreamKit/Sources/DebridKit` | `DebridProvider` protocol, three providers, cache checks, episode-aware file selector |
| `VStreamKit/Sources/TorrentKit` | `TorrentStreamer` actor (one engine, one active stream), magnet inspection, BEP 3 `.torrent` parser |
| `VStreamKit/Sources/PlayerKit` | `MPVController`, `PlayerModel` (`@Observable`), `MPVVideoView`, language matching |
| `VStreamKit/Sources/VStreamCore` | Addon store and ordering, catalog/meta/stream/subtitle fetching, stream resolution, library and Continue Watching, account sync, settings |
| `VStream/` | App: navigation, pages, stream picker, Play Link, player window, settings |

### Technical notes
- **Addon protocol**
  - Manifest URLs are normalised the way Nuvio does it (`stremio://` becomes `https://`, `/manifest.json` is added, the query is kept).
  - Meta requests try addons in install order, with a 5 s timeout for each.
  - Stream requests go to every supporting addon in parallel; each addon's results appear as they arrive.
  - Subtitles come from subtitle addons (10 s timeout) merged with `stream.subtitles`.
- **Stream resolution** follows Nuvio's order:
  1. A direct `url`, with `proxyHeaders`.
  2. An `infoHash`: debrid first, then peer-to-peer, depending on the torrent mode.
  3. A YouTube or external link, which opens in the browser.

  A TorBox `DOWNLOAD_NOT_CACHED` answer counts as "not cached", so Automatic mode falls back to peer-to-peer.
- **Player**
  - libmpv renders into a `CAMetalLayer` with `vo=gpu-next`, `gpu-context=moltenvk`, `hwdec=videotoolbox` and EDR for HDR.
  - It uses [Nuvio's MPVKit fork](https://github.com/NuvioMedia/MPVKit/tree/Nuvio), whose MoltenVK context follows the layer's drawable size, so the picture keeps up with resizes and full screen.
  - mpv's built-in Lua scripts are disabled.
  - Every mpv call made from the main thread is asynchronous, and track lists are read on the mpv event queue. Synchronous calls can deadlock with the EDR display link.
  - `time-pos` updates are throttled before they reach SwiftUI.
- **Watched episodes**
  - Stremio stores them as `anchor:length:base64(zlib(bitfield))`, with videos ordered by season, episode and release date.
  - Foundation's `.zlib` is raw DEFLATE, so the RFC 1950 header and Adler-32 checksum are added by hand.
- **`.torrent` files** are parsed locally:
  - The info hash is the SHA-1 of the raw `info` dictionary.
  - Trackers and the file list come out in libtorrent's index order.
  - This lets debrid services resolve the file. Peer-to-peer then adds the file itself instead of fetching metadata from peers.
- **Window behaviour**
  - Only the player window may enter full screen. SwiftUI keeps rewriting `collectionBehavior`, so a small AppKit helper re-applies the policy.
  - The main window hides its toolbar except on Search.
- **Storage**
  - Settings, addons and the library are JSON files in `~/Library/Application Support/VStream/`.
  - Tokens and API keys are kept in the Keychain (service `com.vstream.app.secrets`).
  - Torrent data goes in `~/Library/Caches/VStream/Torrent`.
- **Logging**: `os.Logger` writes to subsystem `com.vstream.app`, categories `playback` and `trakt`. Logs never contain URLs or keys.

  ```bash
  /usr/bin/log show --last 10m --predicate 'subsystem == "com.vstream.app"' --style compact
  ```

  Use the full path: zsh has a built-in `log` command that shadows `/usr/bin/log`.

## Keyboard shortcuts

| Where | Keys |
|---|---|
| Player | Space play/pause · ←/→ seek 10 s (⌥ 3 s, ⇧ 60 s) · ↑/↓ volume · Z/X subtitle delay ∓0.1 s (⇧ ∓1 s) · F full screen · M mute · S/A cycle subtitles/audio · N next episode · Esc exit full screen |
| App | ⌘F Search · ⌘L Play Link · ⌘O Open Torrent File · ⌘R Refresh Addons · ⇧⌘R Sync Now · ⌘, Settings |

## Debugging

Debug builds can open the player or a page directly, logging player state to stderr:

```bash
VSTREAM_DEBUG_PLAY="<https url or magnet>" VSTREAM_MPV_LOG=v \
  build/DerivedData/Build/Products/Debug/VStream.app/Contents/MacOS/VStream
VSTREAM_DEBUG_OPEN="series:tt0903747" …   # open a detail page
VSTREAM_DEBUG_META="movie:tt0816692" …    # borrow a real title's addon subtitles for DEBUG_PLAY
VSTREAM_DEBUG_SUB="/path/to/file.srt" …    # attach a subtitle file to DEBUG_PLAY
```

Metal API validation is disabled in the scheme because MoltenVK trips it on HDR content.

## Trakt

VStream ships a public Trakt client ID and no secret. Connect in Settings opens the browser. The
redirect to `http://localhost:8765/trakt` is caught by a server listening only on the loopback interface, and
the code is exchanged using PKCE. To use your own Trakt app, register that redirect URI and change
`AppSettings.defaultTraktClientID`.

## License

GPL-3.0. See [LICENSE](LICENSE).

Third-party components:
- libmpv and FFmpeg (LGPL), via MPVKit
- nuvio-engine (GPL-3.0), with libtorrent (BSD)
- [Nuke](https://github.com/kean/Nuke) (MIT)
