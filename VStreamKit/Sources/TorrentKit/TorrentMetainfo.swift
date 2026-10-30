import CryptoKit
import Foundation

public enum TorrentMetainfoError: Error, LocalizedError, Sendable {
    case invalid

    public var errorDescription: String? {
        switch self {
        case .invalid: "This isn't a valid .torrent file"
        }
    }
}

/// Reads a `.torrent` file (BEP 3) without the engine: the v1 info hash (SHA-1 of the raw `info`
/// dictionary), trackers and the file list in libtorrent's index order, pad files included.
public enum TorrentMetainfo {
    public static func parse(_ data: Data) throws -> TorrentContents {
        let bytes = [UInt8](data)
        var parser = Bencode(bytes: bytes)
        guard case let .dictionary(root) = try parser.value(),
              let infoRange = parser.infoRange,
              case let .dictionary(info)? = root["info"] else { throw TorrentMetainfoError.invalid }

        let infoHash = Insecure.SHA1.hash(data: bytes[infoRange]).map { String(format: "%02x", $0) }.joined()
        let name = info["name.utf-8"]?.string ?? info["name"]?.string

        var trackers: [String] = []
        if case let .list(tiers)? = root["announce-list"] {
            for case let .list(tier) in tiers { trackers += tier.compactMap(\.string) }
        }
        if let announce = root["announce"]?.string, !trackers.contains(announce) { trackers.insert(announce, at: 0) }

        var files: [TorrentFileEntry] = []
        if case let .list(entries)? = info["files"] {
            for case let .dictionary(entry) in entries {
                guard case let .integer(length)? = entry["length"],
                      case let .list(parts)? = entry["path.utf-8"] ?? entry["path"] else { continue }
                let path = ([name].compactMap { $0 } + parts.compactMap(\.string)).joined(separator: "/")
                files.append(TorrentFileEntry(index: files.count, path: path, size: UInt64(max(length, 0))))
            }
        } else if case let .integer(length)? = info["length"] {
            files.append(TorrentFileEntry(index: 0, path: name ?? "file", size: UInt64(max(length, 0))))
        }
        return TorrentContents(infoHash: infoHash, name: name, trackers: trackers, files: files)
    }
}

private indirect enum BencodeValue {
    case integer(Int64)
    case bytes([UInt8])
    case list([BencodeValue])
    case dictionary([String: BencodeValue])

    var string: String? {
        guard case let .bytes(bytes) = self else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }
}

private struct Bencode {
    let bytes: [UInt8]
    var position = 0
    var depth = 0
    /// Byte range of the top-level `info` value, for the info hash.
    var infoRange: Range<Int>?

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func value() throws -> BencodeValue {
        guard position < bytes.count, depth < 64 else { throw TorrentMetainfoError.invalid }
        switch bytes[position] {
        case UInt8(ascii: "i"):
            position += 1
            return .integer(try number(until: UInt8(ascii: "e")))
        case UInt8(ascii: "l"):
            position += 1
            depth += 1
            defer { depth -= 1 }
            var items: [BencodeValue] = []
            while try peek() != UInt8(ascii: "e") { items.append(try value()) }
            position += 1
            return .list(items)
        case UInt8(ascii: "d"):
            position += 1
            depth += 1
            defer { depth -= 1 }
            var items: [String: BencodeValue] = [:]
            while try peek() != UInt8(ascii: "e") {
                guard case let .bytes(keyBytes) = try value() else { throw TorrentMetainfoError.invalid }
                let key = String(decoding: keyBytes, as: UTF8.self)
                let start = position
                items[key] = try value()
                if depth == 1, key == "info" { infoRange = start..<position }
            }
            position += 1
            return .dictionary(items)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            let length = Int(try number(until: UInt8(ascii: ":")))
            guard length >= 0, position + length <= bytes.count else { throw TorrentMetainfoError.invalid }
            defer { position += length }
            return .bytes(Array(bytes[position..<position + length]))
        default:
            throw TorrentMetainfoError.invalid
        }
    }

    private func peek() throws -> UInt8 {
        guard position < bytes.count else { throw TorrentMetainfoError.invalid }
        return bytes[position]
    }

    private mutating func number(until terminator: UInt8) throws -> Int64 {
        guard let end = bytes[position...].firstIndex(of: terminator),
              let text = String(bytes: bytes[position..<end], encoding: .ascii),
              let number = Int64(text) else { throw TorrentMetainfoError.invalid }
        position = end + 1
        return number
    }
}
