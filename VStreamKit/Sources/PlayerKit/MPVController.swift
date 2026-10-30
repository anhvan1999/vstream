import AppKit
import Foundation
import Libmpv

/// Workarounds from MPVKit's demo for MoltenVK presenting into a CAMetalLayer.
final class MPVMetalLayer: CAMetalLayer {
    /// MoltenVK sets 1x1 to force-complete presentation, which flickers; ignore it.
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    /// EDR only activates when toggled on the main thread.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                nonisolated(unsafe) let layer = self
                DispatchQueue.main.sync { layer.setSuperEDR(newValue) }
            }
        }
    }

    private func setSuperEDR(_ value: Bool) {
        super.wantsExtendedDynamicRangeContent = value
    }
}

/// libmpv handles are thread-safe; this lets them cross into dispatch closures.
private struct MPVHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}

enum MPVPropertyValue: Sendable {
    case flag(Bool)
    case double(Double)
    case int(Int64)
    case string(String)
    case none
}

enum MPVEvent: Sendable {
    case property(name: String, value: MPVPropertyValue)
    case fileLoaded
    case playbackRestart
    case endFile(error: String?)
    case log(String)
    case tracks([MediaTrack])
    case chapters([Chapter])
}

/// Owns the mpv handle. The libmpv client API is thread-safe; events are drained on a private queue
/// and delivered in batches.
final class MPVController: @unchecked Sendable {
    let layer = MPVMetalLayer()
    private(set) var handle: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "vstream.mpv.events", qos: .userInitiated)
    private let onEvents: @Sendable ([MPVEvent]) -> Void

    static let observed: [(String, mpv_format)] = [
        ("pause", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("core-idle", MPV_FORMAT_FLAG),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("seeking", MPV_FORMAT_FLAG),
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("demuxer-cache-time", MPV_FORMAT_DOUBLE),
        ("cache-buffering-state", MPV_FORMAT_INT64),
        ("speed", MPV_FORMAT_DOUBLE),
        ("volume", MPV_FORMAT_DOUBLE),
        ("mute", MPV_FORMAT_FLAG),
        ("aid", MPV_FORMAT_INT64),
        ("sid", MPV_FORMAT_INT64),
        ("sub-delay", MPV_FORMAT_DOUBLE),
        ("track-list/count", MPV_FORMAT_INT64),
        ("chapter-list/count", MPV_FORMAT_INT64),
        ("hwdec-current", MPV_FORMAT_STRING),
        ("video-params/sig-peak", MPV_FORMAT_DOUBLE),
    ]

    init(onEvents: @escaping @Sendable ([MPVEvent]) -> Void) {
        self.onEvents = onEvents
        layer.framebufferOnly = true
        layer.backgroundColor = NSColor.black.cgColor
        layer.pixelFormat = .bgra8Unorm
    }

    deinit {
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv_terminate_destroy(handle)
        }
    }

    func start(hardwareDecoding: Bool, bufferMB: Int) {
        guard handle == nil, let mpv = mpv_create() else { return }
        handle = mpv

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)

        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", hardwareDecoding ? "videotoolbox" : "no"),
            ("hwdec-software-fallback", "300"),
            ("vulkan-swap-mode", "fifo"),
            ("vulkan-queue-count", "1"),
            ("vulkan-async-compute", "no"),
            ("vulkan-async-transfer", "no"),
            ("target-colorspace-hint", "yes"),
            ("tone-mapping", "auto"),
            ("hdr-compute-peak", "yes"),
            ("video-sync", "display-resample"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("ytdl", "no"),
            // Built-in Lua scripts (OSC, stats, console, select, …) are unused; they also query the
            // audio device list, whose CoreAudio hotplug callback crashed libmpv after teardown.
            ("osc", "no"),
            ("load-scripts", "no"),
            ("load-stats-overlay", "no"),
            ("load-console", "no"),
            ("load-select", "no"),
            ("load-positioning", "no"),
            ("load-commands", "no"),
            ("load-context-menu", "no"),
            ("load-auto-profiles", "no"),
            ("load-osd-console", "no"),
            ("input-default-bindings", "no"),
            ("input-media-keys", "no"),
            ("audio-channels", "auto"),
            ("audio-fallback-to-null", "yes"),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("sub-auto", "no"),
            ("cache", "yes"),
            // In-memory read-ahead for streams; a quarter of it is kept for seeking back.
            ("demuxer-max-bytes", "\(max(bufferMB, 32))MiB"),
            ("demuxer-max-back-bytes", "\(max(bufferMB / 4, 16))MiB"),
            ("demuxer-readahead-secs", "120"),
            ("network-timeout", "60"),
            ("screenshot-directory", "~/Pictures"),
        ]
        for (name, value) in options {
            mpv_set_option_string(mpv, name, value)
        }
        mpv_request_log_messages(mpv, ProcessInfo.processInfo.environment["VSTREAM_MPV_LOG"] ?? "error")

        guard mpv_initialize(mpv) >= 0 else {
            mpv_terminate_destroy(mpv)
            handle = nil
            return
        }
        #if DEBUG
        // Safe to read synchronously here: no VO thread exists yet.
        if ProcessInfo.processInfo.environment["VSTREAM_MPV_LOG"] != nil {
            for name in ["demuxer-max-bytes", "demuxer-max-back-bytes"] {
                if let value = mpv_get_property_string(mpv, name) {
                    FileHandle.standardError.write(Data("[mpv/config] \(name)=\(String(cString: value))\n".utf8))
                    mpv_free(value)
                }
            }
        }
        #endif
        for (name, format) in Self.observed {
            mpv_observe_property(mpv, 0, name, format)
        }
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            Unmanaged<MPVController>.fromOpaque(context).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func shutdown() {
        guard let handle else { return }
        mpv_set_wakeup_callback(handle, nil, nil)
        self.handle = nil
        let box = MPVHandle(pointer: handle)
        eventQueue.async {
            mpv_terminate_destroy(box.pointer)
        }
    }

    // MARK: Commands & properties

    func command(_ args: [String]) {
        guard let handle else { return }
        var cStrings: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cStrings.append(nil)
        defer { cStrings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        _ = cStrings.withUnsafeMutableBufferPointer { buffer in
            mpv_command_async(handle, 0, buffer.baseAddress)
        }
    }

    // Setters are asynchronous: a synchronous mpv call from the main thread can deadlock
    // against the VO thread, which hops to the main thread to toggle EDR on the layer.

    func set(_ name: String, _ value: String) {
        guard let handle else { return }
        value.withCString { pointer in
            var string: UnsafePointer<CChar>? = pointer
            _ = mpv_set_property_async(handle, 0, name, MPV_FORMAT_STRING, &string)
        }
    }

    func set(_ name: String, flag: Bool) {
        guard let handle else { return }
        var value: Int32 = flag ? 1 : 0
        mpv_set_property_async(handle, 0, name, MPV_FORMAT_FLAG, &value)
    }

    func set(_ name: String, double: Double) {
        guard let handle else { return }
        var value = double
        mpv_set_property_async(handle, 0, name, MPV_FORMAT_DOUBLE, &value)
    }

    /// Sets a string-list property without relying on comma escaping.
    func set(_ name: String, list: [String]) {
        guard let handle else { return }
        let cStrings = list.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var nodes = cStrings.map { string -> mpv_node in
            var node = mpv_node()
            node.format = MPV_FORMAT_STRING
            node.u.string = string
            return node
        }
        nodes.withUnsafeMutableBufferPointer { buffer in
            var nodeList = mpv_node_list(num: Int32(buffer.count), values: buffer.baseAddress, keys: nil)
            withUnsafeMutablePointer(to: &nodeList) { listPointer in
                var node = mpv_node()
                node.format = MPV_FORMAT_NODE_ARRAY
                node.u.list = listPointer
                mpv_set_property_async(handle, 0, name, MPV_FORMAT_NODE, &node)
            }
        }
    }

    /// Synchronous read; only call from `eventQueue`, never the main thread.
    private func json(_ handle: OpaquePointer, _ name: String) -> Any? {
        guard let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return try? JSONSerialization.jsonObject(with: Data(String(cString: value).utf8))
    }

    private func readTracks(_ handle: OpaquePointer) -> [MediaTrack] {
        (json(handle, "track-list") as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["id"] as? Int, let type = entry["type"] as? String, let kind = MediaTrack.Kind(rawValue: type) else { return nil }
            return MediaTrack(
                id: id,
                kind: kind,
                title: entry["title"] as? String,
                language: entry["lang"] as? String,
                codec: entry["codec"] as? String,
                channels: entry["demux-channel-count"] as? Int,
                isExternal: entry["external"] as? Bool ?? false,
                isDefault: entry["default"] as? Bool ?? false
            )
        }
    }

    private func readChapters(_ handle: OpaquePointer) -> [Chapter] {
        (json(handle, "chapter-list") as? [[String: Any]] ?? []).compactMap { entry in
            guard let time = entry["time"] as? Double else { return nil }
            return Chapter(title: entry["title"] as? String ?? "", time: time)
        }
    }

    // MARK: Events

    private func drainEvents() {
        eventQueue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            var events: [MPVEvent] = []
            while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
                switch event.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    if let property = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self).pointee {
                        events.append(.property(name: String(cString: property.name), value: Self.value(of: property)))
                    }
                case MPV_EVENT_FILE_LOADED:
                    events.append(.fileLoaded)
                case MPV_EVENT_PLAYBACK_RESTART:
                    events.append(.playbackRestart)
                case MPV_EVENT_END_FILE:
                    if let endFile = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                        let error = endFile.reason == MPV_END_FILE_REASON_ERROR ? String(cString: mpv_error_string(endFile.error)) : nil
                        events.append(.endFile(error: error))
                    }
                case MPV_EVENT_LOG_MESSAGE:
                    if let message = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                       let text = message.text {
                        let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
                        if ProcessInfo.processInfo.environment["VSTREAM_MPV_LOG"] != nil, let prefix = message.prefix {
                            FileHandle.standardError.write(Data("[mpv/\(String(cString: prefix))] \(line)\n".utf8))
                        }
                        events.append(.log(line))
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                default:
                    break
                }
            }
            let names = Set(events.compactMap { event -> String? in
                switch event {
                case .fileLoaded: "loaded"
                case let .property(name, _): name
                default: nil
                }
            })
            if !names.isDisjoint(with: ["loaded", "track-list/count"]) { events.append(.tracks(self.readTracks(handle))) }
            if !names.isDisjoint(with: ["loaded", "chapter-list/count"]) { events.append(.chapters(self.readChapters(handle))) }
            if !events.isEmpty { self.onEvents(events) }
        }
    }

    private static func value(of property: mpv_event_property) -> MPVPropertyValue {
        guard let data = property.data else { return .none }
        switch property.format {
        case MPV_FORMAT_FLAG: return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_DOUBLE: return .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_INT64: return .int(data.assumingMemoryBound(to: Int64.self).pointee)
        case MPV_FORMAT_STRING:
            guard let pointer = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return .none }
            return .string(String(cString: pointer))
        default: return .none
        }
    }
}
