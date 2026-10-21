import Foundation

// Session replay (mobile/SPEC.md "Session replay"): masked screenshots + touches recorded as rrweb
// events and uploaded to `POST /replay`, so the web pipeline and player work unchanged. This file is
// UI-free; `Guidely` supplies the UIKit screen capturer.

/// Session replay options. Recording also needs session replay switched on in the project settings.
public struct SessionReplayOptions: Sendable, Hashable {
    /// Record sessions (default false: native screenshots are opt-in per app).
    public var enabled: Bool
    /// Mask all text, not only text inputs (also forced on by the project's "mask all text" setting).
    public var maskAllText: Bool
    /// Mask all images.
    public var maskAllImages: Bool
    /// Seconds between screenshots (minimum 0.5). Unchanged screens are not re-sent.
    public var captureInterval: TimeInterval

    public init(enabled: Bool = false, maskAllText: Bool = false, maskAllImages: Bool = false, captureInterval: TimeInterval = 1) {
        self.enabled = enabled; self.maskAllText = maskAllText; self.maskAllImages = maskAllImages; self.captureInterval = captureInterval
    }
}

/// `config.settings.replay` (the parts the mobile SDKs use).
public struct ReplayProjectSettings: Decodable, Sendable, Hashable {
    public var enabled: Bool
    /// Percentage of sessions recorded (0–100).
    public var sampleRate: Int
    public var maskAllText: Bool
    public var blockSelectors: [String]

    public init(enabled: Bool = false, sampleRate: Int = 100, maskAllText: Bool = false, blockSelectors: [String] = []) {
        self.enabled = enabled; self.sampleRate = sampleRate; self.maskAllText = maskAllText; self.blockSelectors = blockSelectors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        enabled = c.lenient("enabled", false)
        sampleRate = c.lenient("sampleRate", 100)
        maskAllText = c.lenient("maskAllText", false)
        blockSelectors = c.strings("blockSelectors") ?? []
    }
}

/// What a screenshot must hide, resolved from the options and project settings.
public struct ReplayMaskRules: Sendable, Hashable {
    public var maskAllText: Bool
    public var maskAllImages: Bool
    /// Guidely target ids whose views are masked (from block selectors).
    public var blockedIds: Set<String>

    public init(maskAllText: Bool = false, maskAllImages: Bool = false, blockedIds: Set<String> = []) {
        self.maskAllText = maskAllText; self.maskAllImages = maskAllImages; self.blockedIds = blockedIds
    }
}

/// One masked screenshot. `width`/`height` are the viewport size in points (= image pixels).
public struct ReplayFrame: Sendable, Equatable {
    public var jpeg: Data
    public var width: Int
    public var height: Int
    public init(jpeg: Data, width: Int, height: Int) { self.jpeg = jpeg; self.width = width; self.height = height }
}

public enum ReplayTouchPhase: Sendable { case began, moved, ended }

/// Captures the app's windows. Implemented with UIKit by the `Guidely` module; tests fake it.
@MainActor
public protocol GuidelyScreenCapturer: AnyObject {
    /// A masked screenshot of the visible windows (nil when there is nothing to capture), delivered on
    /// the main actor. Drawing happens synchronously; encoding may finish later off the main thread.
    func captureFrame(_ rules: ReplayMaskRules, completion: @escaping @MainActor @Sendable (ReplayFrame?) -> Void)
    /// Starts reporting touches (window coordinates in points); nil stops.
    func observeTouches(_ handler: (@MainActor (ReplayTouchPhase, Double, Double) -> Void)?)
}

// MARK: - rrweb events

/// Builders for the rrweb events a mobile recording consists of (one JSON object string each).
public enum ReplayEvents {
    /// Fixed node id of the `<img>` showing the screen.
    public static let screenNodeId = 8
    static let css = "html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:#000}img{display:block;width:100%;height:100%;object-fit:contain}"

    static func dataURL(_ jpeg: Data) -> String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// Rounds to 0.1 so touch coordinates stay short in JSON.
    static func coord(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    /// Meta + FullSnapshot: the player rebuilds the page from here.
    public static func keyframe(_ frame: ReplayFrame, href: String, at date: Date) -> [String] {
        let ts = ms(date)
        let img: [String: Any] = ["type": 2, "id": screenNodeId, "tagName": "img", "attributes": ["src": dataURL(frame.jpeg), "width": "\(frame.width)", "height": "\(frame.height)", "alt": ""], "childNodes": [Any]()]
        let style: [String: Any] = ["type": 2, "id": 5, "tagName": "style", "attributes": [String: Any](), "childNodes": [["type": 3, "id": 6, "textContent": css, "isStyle": true]]]
        let html: [String: Any] = [
            "type": 2, "id": 3, "tagName": "html", "attributes": [String: Any](),
            "childNodes": [
                ["type": 2, "id": 4, "tagName": "head", "attributes": [String: Any](), "childNodes": [style]],
                ["type": 2, "id": 7, "tagName": "body", "attributes": [String: Any](), "childNodes": [img]],
            ],
        ]
        let document: [String: Any] = ["type": 0, "id": 1, "childNodes": [["type": 1, "id": 2, "name": "html", "publicId": "", "systemId": ""], html]]
        return [
            json(["type": 4, "timestamp": ts, "data": ["href": href, "width": frame.width, "height": frame.height]]),
            json(["type": 2, "timestamp": ts, "data": ["node": document, "initialOffset": ["left": 0, "top": 0]]]),
        ]
    }

    /// Replaces the screen image.
    public static func frame(_ frame: ReplayFrame, at date: Date) -> String {
        json(["type": 3, "timestamp": ms(date), "data": ["source": 0, "texts": [Any](), "attributes": [["id": screenNodeId, "attributes": ["src": dataURL(frame.jpeg)]]], "removes": [Any](), "adds": [Any]()]])
    }

    /// MouseInteraction: 2 = Click, 7 = TouchStart, 9 = TouchEnd.
    public static func interaction(_ type: Int, x: Double, y: Double, at date: Date) -> String {
        json(["type": 3, "timestamp": ms(date), "data": ["source": 2, "type": type, "id": screenNodeId, "x": coord(x), "y": coord(y)]])
    }

    public static func touchMove(x: Double, y: Double, at date: Date) -> String {
        json(["type": 3, "timestamp": ms(date), "data": ["source": 6, "positions": [["x": coord(x), "y": coord(y), "id": screenNodeId, "timeOffset": 0]]]])
    }

    /// Custom event (Guidely analytics markers: tag `guidely`, payload `{ name, customName?, guideId? }`).
    public static func custom(tag: String, payload: [String: Any], at date: Date) -> String {
        json(["type": 5, "timestamp": ms(date), "data": ["tag": tag, "payload": payload]])
    }
}

// MARK: - Gzip

enum Gzip {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for byte in buf { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// RFC 1952 gzip: Foundation's `.zlib` is raw DEFLATE, wrapped here with the gzip header and trailer.
    static func compress(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    /// Inverse of `compress` (tests).
    static func decompress(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else { return nil }
        let body = data.subdata(in: (data.startIndex + 10)..<(data.endIndex - 8))
        return try? (body as NSData).decompressed(using: .zlib) as Data
    }
}

// MARK: - Upload

/// Per-upload metadata (`ReplayChunkSchema` minus sessionId/windowId/seq/events).
public struct ReplayChunkMeta: Sendable {
    public var anonymousId: String
    public var userId: String?
    public var url: String?
    public var deviceType: String
    public var os: String
    public var viewportWidth: Int?
    public var viewportHeight: Int?
    public var sdkName: String
    public var sdkVersion: String

    func json() -> [String: Any] {
        var o: [String: Any] = ["anonymousId": anonymousId, "device": ["type": deviceType, "os": os], "sdk": ["name": sdkName, "version": sdkVersion]]
        if let userId { o["userId"] = userId }
        if let url { o["url"] = url }
        if let w = viewportWidth, let h = viewportHeight { o["viewport"] = ["width": w, "height": h] }
        return o
    }
}

/// Buffers recorded events and uploads them (port of `ReplayController` in `packages/sdk-core/src/replay.ts`):
/// one chunk at a time, gzip, `seq` per session assigned on the first attempt and kept for retries,
/// backoff on failure, oldest chunks dropped above the backlog cap.
@MainActor
final class ReplayUploader {
    final class Chunk {
        let sessionId: String
        let meta: ReplayChunkMeta
        var events: [String] = []
        var bytes = 0
        var seq: Int?
        init(sessionId: String, meta: ReplayChunkMeta) { self.sessionId = sessionId; self.meta = meta }
    }

    enum Result { case ok, drop, retry, disabled }

    let windowId = GuidelyUtils.randomId(16)
    private let api: GuidelyAPI
    private let scheduler: GuidelyScheduler
    private let spawn: (@escaping @MainActor () async -> Void) -> Void
    private let onDisabled: (String) -> Void
    private let log: (String) -> Void
    let maxBufferBytes: Int
    let maxQueuedBytes: Int
    let maxAttempts = 5
    private(set) var buffer: Chunk?
    private(set) var queue: [Chunk] = []
    private(set) var queuedBytes = 0
    private var seqs: [String: Int] = [:]
    private var uploading = false
    private var attempt = 0
    private var retryTimer: GuidelyCancellable?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var destroyed = false

    init(api: GuidelyAPI, scheduler: GuidelyScheduler, maxBufferBytes: Int = 1_000_000, maxQueuedBytes: Int = 5_000_000, spawn: @escaping (@escaping @MainActor () async -> Void) -> Void, onDisabled: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        self.api = api; self.scheduler = scheduler; self.maxBufferBytes = maxBufferBytes; self.maxQueuedBytes = maxQueuedBytes
        self.spawn = spawn; self.onDisabled = onDisabled; self.log = log
    }

    /// Adds an event to the buffer of `sessionId` (a new chunk when the session changed).
    func push(_ event: String, sessionId: String, meta: () -> ReplayChunkMeta) {
        if let b = buffer, b.sessionId != sessionId { seal() }
        let chunk = buffer ?? Chunk(sessionId: sessionId, meta: meta())
        buffer = chunk
        chunk.events.append(event)
        chunk.bytes += event.utf8.count
        if chunk.bytes > maxBufferBytes { flush() }
    }

    /// Drops everything not yet uploaded (consent withdrawn).
    func discard(sessionId: String? = nil) {
        if sessionId == nil || buffer?.sessionId == sessionId { buffer = nil }
        let keepFirst = uploading ? queue.first : nil
        for c in queue where c !== keepFirst && (sessionId == nil || c.sessionId == sessionId) { remove(c) }
    }

    private func seal() {
        guard let chunk = buffer else { return }
        buffer = nil
        guard !chunk.events.isEmpty else { return }
        queue.append(chunk)
        queuedBytes += chunk.bytes
        while queuedBytes > maxQueuedBytes, queue.count > 1 {
            let dropped = queue.remove(at: uploading ? 1 : 0)
            queuedBytes -= dropped.bytes
            log("replay backlog full; dropped a chunk")
        }
    }

    private func remove(_ chunk: Chunk) {
        guard let i = queue.firstIndex(where: { $0 === chunk }) else { return }
        queue.remove(at: i)
        queuedBytes -= chunk.bytes
    }

    var isIdle: Bool { buffer == nil && queue.isEmpty && !uploading }

    /// Seals the buffer and uploads the backlog (fire and forget).
    func flush() {
        seal()
        guard retryTimer == nil, !uploading, !queue.isEmpty else { return }
        uploading = true
        spawn { [weak self] in await self?.drain() }
    }

    /// Seals and uploads, returning when the upload loop has finished (background flush, tests).
    func flushAndWait() async {
        flush()
        guard uploading else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func drain() async {
        defer {
            uploading = false
            let w = waiters
            waiters = []
            w.forEach { $0.resume() }
        }
        while let chunk = queue.first {
            let result = await send(chunk)
            if result == .retry {
                attempt += 1
                if !destroyed, attempt < maxAttempts {
                    let delay = backoffSeconds(attempt - 1)
                    retryTimer = scheduler.schedule(after: delay) { [weak self] in
                        self?.retryTimer = nil
                        self?.flush()
                    }
                } else {
                    attempt = 0
                    remove(chunk)
                    log("replay chunk dropped after \(maxAttempts) attempts")
                    continue
                }
                return
            }
            attempt = 0
            remove(chunk)
            if result == .disabled {
                for c in queue where c.sessionId == chunk.sessionId { remove(c) }
                if buffer?.sessionId == chunk.sessionId { buffer = nil }
                onDisabled(chunk.sessionId)
            }
        }
    }

    func body(_ chunk: Chunk) -> Data {
        if chunk.seq == nil {
            let seq = seqs[chunk.sessionId] ?? 0
            seqs[chunk.sessionId] = seq + 1
            chunk.seq = seq
        }
        var head = chunk.meta.json()
        head["sessionId"] = chunk.sessionId
        head["windowId"] = windowId
        head["seq"] = chunk.seq ?? 0
        var text = ReplayEvents.json(head)
        text.removeLast()
        text += #","events":["# + chunk.events.joined(separator: ",") + "]}"
        return Data(text.utf8)
    }

    private func send(_ chunk: Chunk) async -> Result {
        let json = body(chunk)
        let gz = Gzip.compress(json)
        let req = api.makeRequest("POST", "/replay", body: gz ?? json, params: ["enc": gz != nil ? "gzip" : nil])
        do {
            let res = try await api.transport.send(req)
            log("replay → \(res.status) (\(chunk.events.count) events, \(gz?.count ?? json.count) bytes)")
            if res.ok {
                let disabled = (try? JSONDecoder().decode(JSONValue.self, from: res.data))?.objectValue?["disabled"]?.boolValue ?? false
                return disabled ? .disabled : .ok
            }
            return res.status >= 400 && res.status < 500 && res.status != 429 ? .drop : .retry
        } catch {
            log("replay upload failed: \(error.localizedDescription)")
            return .retry
        }
    }

    func destroy() {
        destroyed = true
        retryTimer?.cancel()
        retryTimer = nil
    }
}

// MARK: - Recorder

/// Records one session at a time: a capture timer turns screenshots into keyframes / image mutations,
/// touches into rrweb touch events, and hands everything to the uploader.
@MainActor
public final class SessionRecorder {
    private let capturer: GuidelyScreenCapturer
    private let scheduler: GuidelyScheduler
    private let uploader: ReplayUploader
    private let meta: () -> ReplayChunkMeta
    private(set) var sessionId: String?
    private var rules = ReplayMaskRules()
    private var interval: TimeInterval = 1
    private var href = "/"
    private var captureTimer: GuidelyCancellable?
    private var flushTimer: GuidelyCancellable?
    private var lastJPEG: Data?
    private var lastSize: (Int, Int)?
    private var needsKeyframe = true
    private var foreground = true
    private var touchStart: (x: Double, y: Double, at: Date)?
    private var touchMoved = false
    private var lastMoveAt: Date?
    private var capturing = false
    /// Consecutive captures that found the screen unchanged; slows the cadence of an idle screen.
    private(set) var idleCaptures = 0
    /// Guidely markers that arrived before the recording's first keyframe (emitted right after it).
    private var earlyCustom: [(tag: String, payload: [String: Any])] = []
    private var hasKeyframe = false
    let flushInterval: TimeInterval

    init(capturer: GuidelyScreenCapturer, api: GuidelyAPI, scheduler: GuidelyScheduler, flushInterval: TimeInterval = 10, maxBufferBytes: Int = 1_000_000, maxQueuedBytes: Int = 5_000_000, spawn: @escaping (@escaping @MainActor () async -> Void) -> Void, meta: @escaping () -> ReplayChunkMeta, onDisabled: @escaping (String) -> Void, log: @escaping (String) -> Void) {
        self.capturer = capturer
        self.scheduler = scheduler
        self.meta = meta
        self.flushInterval = flushInterval
        uploader = ReplayUploader(api: api, scheduler: scheduler, maxBufferBytes: maxBufferBytes, maxQueuedBytes: maxQueuedBytes, spawn: spawn, onDisabled: onDisabled, log: log)
    }

    public var isRecording: Bool { sessionId != nil }
    var viewport: (width: Int, height: Int)? { lastSize.map { (width: $0.0, height: $0.1) } }
    var windowId: String { uploader.windowId }
    var pendingUploads: Bool { !uploader.isIdle }

    /// Starts (or keeps) recording `sessionId`; restarts when the session changed.
    func start(sessionId: String, rules: ReplayMaskRules, interval: TimeInterval, href: String) {
        if self.sessionId == sessionId {
            self.rules = rules
            self.interval = max(0.5, interval)
            return
        }
        stop()
        self.sessionId = sessionId
        self.rules = rules
        self.interval = max(0.5, interval)
        self.href = href
        needsKeyframe = true
        lastJPEG = nil
        idleCaptures = 0
        hasKeyframe = false
        earlyCustom = []
        capturer.observeTouches { [weak self] phase, x, y in self?.touch(phase, x: x, y: y) }
        scheduleFlush()
        if foreground { captureSoon(0) }
    }

    /// Stops recording; buffered events are uploaded unless `discard`.
    func stop(discard: Bool = false) {
        guard let id = sessionId else {
            if discard { uploader.discard() }
            return
        }
        sessionId = nil
        captureTimer?.cancel()
        captureTimer = nil
        flushTimer?.cancel()
        flushTimer = nil
        capturer.observeTouches(nil)
        touchStart = nil
        if discard { uploader.discard(sessionId: id) } else { uploader.flush() }
    }

    /// The app moved to the background (pause, upload) or returned (resume with a keyframe).
    func setForeground(_ value: Bool) {
        guard value != foreground else { return }
        foreground = value
        if value {
            needsKeyframe = true
            if isRecording { captureSoon(0) }
        } else {
            captureTimer?.cancel()
            captureTimer = nil
            touchStart = nil
            uploader.flush()
        }
    }

    /// A new screen: the next frame is a keyframe with its path, captured shortly (after layout).
    func screenChanged(_ href: String) {
        guard href != self.href || !isRecording else { return }
        self.href = href
        needsKeyframe = true
        idleCaptures = 0
        if isRecording, foreground { captureSoon(0.3) }
    }

    func addCustomEvent(tag: String, payload: [String: Any]) {
        guard let id = sessionId else { return }
        idleCaptures = 0
        guard hasKeyframe else {
            if earlyCustom.count < 50 { earlyCustom.append((tag, payload)) }
            return
        }
        push(ReplayEvents.custom(tag: tag, payload: payload, at: scheduler.now), id)
    }

    func flush() async { await uploader.flushAndWait() }

    func destroy() {
        stop()
        uploader.destroy()
    }

    private func push(_ event: String, _ sessionId: String) {
        uploader.push(event, sessionId: sessionId, meta: meta)
    }

    private func captureSoon(_ delay: TimeInterval) {
        captureTimer?.cancel()
        captureTimer = scheduler.schedule(after: delay) { [weak self] in self?.tick() }
    }

    private func scheduleFlush() {
        flushTimer = scheduler.schedule(after: flushInterval) { [weak self] in
            guard let self, self.isRecording else { return }
            self.uploader.flush()
            self.scheduleFlush()
        }
    }

    private func tick() {
        guard isRecording, foreground else { return }
        // Never draw while a finger is down (it would compete with the app's drag or scroll);
        // the touch's end captures instead.
        if touchStart == nil { captureNow() }
        captureSoon(nextDelay)
    }

    /// The capture interval, or up to 4× it (≤ 5 s) once the screen has been unchanged for 3 captures.
    var nextDelay: TimeInterval {
        idleCaptures < 3 ? interval : max(interval, min(interval * 4, 5))
    }

    /// Captures one frame: a keyframe when needed (start, resize, foreground, new screen), an image
    /// mutation when the screen changed, nothing when it did not.
    func captureNow() {
        guard let id = sessionId, !capturing else { return }
        capturing = true
        capturer.captureFrame(rules) { [weak self] frame in
            guard let self else { return }
            self.capturing = false
            guard let frame, self.sessionId == id, self.foreground else { return }
            self.record(frame, id)
        }
    }

    private func record(_ frame: ReplayFrame, _ id: String) {
        let size = (frame.width, frame.height)
        if lastSize.map({ $0 != size }) ?? true { needsKeyframe = true }
        let now = scheduler.now
        if needsKeyframe {
            needsKeyframe = false
            idleCaptures = 0
            lastSize = size
            lastJPEG = frame.jpeg
            for e in ReplayEvents.keyframe(frame, href: href, at: now) { push(e, id) }
            if !hasKeyframe {
                hasKeyframe = true
                for c in earlyCustom { push(ReplayEvents.custom(tag: c.tag, payload: c.payload, at: now), id) }
                earlyCustom = []
            }
        } else if frame.jpeg != lastJPEG {
            lastJPEG = frame.jpeg
            idleCaptures = 0
            push(ReplayEvents.frame(frame, at: now), id)
        } else {
            idleCaptures += 1
        }
    }

    func touch(_ phase: ReplayTouchPhase, x: Double, y: Double) {
        guard let id = sessionId, foreground, hasKeyframe else { return }
        let now = scheduler.now
        switch phase {
        case .began:
            idleCaptures = 0
            touchStart = (x, y, now)
            touchMoved = false
            lastMoveAt = nil
            push(ReplayEvents.interaction(7, x: x, y: y, at: now), id)
        case .moved:
            guard let start = touchStart else { return }
            if hypot(x - start.x, y - start.y) > 10 { touchMoved = true }
            if let last = lastMoveAt, now.timeIntervalSince(last) < 0.05 { return }
            lastMoveAt = now
            push(ReplayEvents.touchMove(x: x, y: y, at: now), id)
        case .ended:
            guard let start = touchStart else { return }
            touchStart = nil
            push(ReplayEvents.interaction(9, x: x, y: y, at: now), id)
            if !touchMoved, hypot(x - start.x, y - start.y) <= 10, now.timeIntervalSince(start.at) < 1 {
                push(ReplayEvents.interaction(2, x: x, y: y, at: now), id)
            }
            captureSoon(0.2)
        }
    }
}
