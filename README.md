# VStream

Native macOS media player for Stremio addons, built with SwiftUI.

- Stremio addon protocol (catalog, meta, stream, subtitles)
- HTTP and torrent streaming (libmpv via MPVKit, libtorrent via nuvio-engine)
- Debrid: Real-Debrid, Torbox, Premiumize
- Stremio account and Trakt sync

## Build

Requires Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and sibling checkouts of
`MPVKit` and `nuvio-engine` next to this repository.

```bash
./scripts/bootstrap.sh
open VStream.xcodeproj
```

## License

GPL-3.0. See [LICENSE](LICENSE).
