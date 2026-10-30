import AddonKit
import Foundation

/// Stremio's per-episode watched marks (`LibraryItemState.watched`), ported from
/// `stremio-core/stremio-watched-bitfield`.
///
/// Serialized as `<anchorVideoId>:<anchorLength>:<base64(zlib(bits))>`. Bit `i` is the i-th video
/// in Stremio's order (season, episode, release date — missing values first). The anchor is the
/// last watched video and its 1-based position when encoded, which lets the bits be realigned
/// if episodes were added before it later.
public enum WatchedBitfield {
    /// Video ids in the order Stremio assigns bits.
    public static func orderedVideoIDs(_ videos: [Video]) -> [String] {
        videos.sorted { a, b in
            let lhs = (a.season ?? .min, a.episode ?? .min, a.released?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude)
            let rhs = (b.season ?? .min, b.episode ?? .min, b.released?.timeIntervalSince1970 ?? -.greatestFiniteMagnitude)
            return lhs < rhs
        }
        .map(\.id)
    }

    /// Watched video ids. Returns an empty set when the field can't be read or its anchor
    /// episode no longer exists (same as Stremio).
    public static func decode(_ serialized: String, videoIDs: [String]) -> Set<String> {
        var components = serialized.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 3,
              let encoded = components.popLast(),
              let anchorLength = components.popLast().flatMap(Int.init),
              let data = Data(base64Encoded: encoded),
              let bytes = zlibInflate(data) else { return [] }
        let anchor = components.joined(separator: ":")
        guard let anchorIndex = videoIDs.firstIndex(of: anchor) else { return [] }
        let offset = anchorLength - anchorIndex - 1
        var watched = Set<String>()
        for (index, id) in videoIDs.enumerated() {
            let previous = index + offset
            guard previous >= 0, previous / 8 < bytes.count else { continue }
            if (bytes[previous / 8] >> UInt8(previous % 8)) & 1 == 1 { watched.insert(id) }
        }
        return watched
    }

    public static func encode(watched: Set<String>, videoIDs: [String]) -> String? {
        guard !videoIDs.isEmpty else { return nil }
        var bytes = [UInt8](repeating: 0, count: (videoIDs.count + 7) / 8)
        var last = 0
        for (index, id) in videoIDs.enumerated() where watched.contains(id) {
            bytes[index / 8] |= 1 << UInt8(index % 8)
            last = index
        }
        guard let compressed = zlibDeflate(Data(bytes)) else { return nil }
        return "\(videoIDs[last]):\(last + 1):\(compressed.base64EncodedString())"
    }

    // MARK: zlib (RFC 1950) around Foundation's raw DEFLATE

    static func zlibInflate(_ data: Data) -> [UInt8]? {
        guard data.count > 6 else { return nil }
        let raw = data.subdata(in: 2..<(data.count - 4))
        guard let inflated = try? (raw as NSData).decompressed(using: .zlib) else { return nil }
        return [UInt8](inflated as Data)
    }

    static func zlibDeflate(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) else { return nil }
        var result = Data([0x78, 0x9C])
        result.append(deflated as Data)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let adler = (b << 16) | a
        result.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return result
    }
}
