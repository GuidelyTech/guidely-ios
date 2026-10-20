import Foundation

// MARK: - Storage

/// Persistent key/value storage (identity, cached config, guide state, event queue).
public protocol GuidelyKeyValueStore: AnyObject {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
    func remove(_ key: String)
}

/// `UserDefaults`-backed store (default). Keys are prefixed with `guidely:`.
public final class UserDefaultsStore: GuidelyKeyValueStore {
    private let defaults: UserDefaults
    public init(suiteName: String? = "tech.guidely.sdk") {
        defaults = suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
    public func get(_ key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
    public func remove(_ key: String) { defaults.removeObject(forKey: key) }
}

/// In-memory store (tests, or `storage: .memory`).
public final class InMemoryStore: GuidelyKeyValueStore {
    public private(set) var values: [String: String] = [:]
    private let lock = NSLock()
    public init(_ initial: [String: String] = [:]) { values = initial }
    public func get(_ key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ key: String, _ value: String) { lock.lock(); values[key] = value; lock.unlock() }
    public func remove(_ key: String) { lock.lock(); values[key] = nil; lock.unlock() }
}

enum StoreKeys {
    static let anon = "guidely:anon"
    static let seen = "guidely:seen"
    static func config(_ k: String) -> String { "guidely:config:\(k)" }
    static func configFetchedAt(_ k: String) -> String { "guidely:configFetchedAt:\(k)" }
    static func etag(_ k: String) -> String { "guidely:etag:\(k)" }
    static func state(_ k: String) -> String { "guidely:state:\(k)" }
    static func user(_ k: String) -> String { "guidely:user:\(k)" }
    static func queue(_ k: String) -> String { "guidely:queue:\(k)" }
}

extension GuidelyKeyValueStore {
    func readJSON<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let s = get(key), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func writeJSON<T: Encodable>(_ key: String, _ value: T) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) else { return }
        set(key, s)
    }
}

// MARK: - Scheduling

/// Cancellation handle for scheduled work.
public final class GuidelyCancellable {
    private var onCancel: (() -> Void)?
    public private(set) var isCancelled = false
    public init(_ onCancel: (() -> Void)? = nil) { self.onCancel = onCancel }
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel?()
        onCancel = nil
    }
}

/// Clock + timers. Injected so tests can control time.
@MainActor
public protocol GuidelyScheduler: AnyObject {
    var now: Date { get }
    @discardableResult
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> GuidelyCancellable
    /// Waits (used for retry backoff).
    func sleep(_ seconds: TimeInterval) async
}

/// Real-time scheduler on the main actor.
@MainActor
public final class MainScheduler: GuidelyScheduler {
    public init() {}
    public var now: Date { Date() }

    @discardableResult
    public func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> GuidelyCancellable {
        let task = Task { @MainActor in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } else { await Task.yield() }
            if Task.isCancelled { return }
            work()
        }
        return GuidelyCancellable { task.cancel() }
    }

    public func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Deterministic scheduler for tests: time only moves on `advance(by:)`.
@MainActor
public final class ManualScheduler: GuidelyScheduler {
    private struct Item { let id: Int; let due: Date; let work: @MainActor () -> Void; let handle: GuidelyCancellable }
    public private(set) var now: Date
    private var items: [Item] = []
    private var nextId = 0

    public init(now: Date = Date(timeIntervalSince1970: 1_781_519_400)) { self.now = now }

    @discardableResult
    public func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> GuidelyCancellable {
        nextId += 1
        let id = nextId
        let handle = GuidelyCancellable { [weak self] in self?.items.removeAll { $0.id == id } }
        items.append(Item(id: id, due: now.addingTimeInterval(max(0, seconds)), work: work, handle: handle))
        return handle
    }

    public func sleep(_ seconds: TimeInterval) async {}

    /// Number of pending timers.
    public var pendingCount: Int { items.count }

    /// Moves time forward, running due timers in order (including ones scheduled while advancing).
    public func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while true {
            let due = items.filter { $0.due <= target }.sorted { ($0.due, $0.id) < ($1.due, $1.id) }
            guard let next = due.first else { break }
            items.removeAll { $0.id == next.id }
            if next.due > now { now = next.due }
            if !next.handle.isCancelled { next.work() }
        }
        now = target
    }

    /// Runs timers that are due now (zero-delay work).
    public func runDue() { advance(by: 0) }
}

// MARK: - Transport

public struct HTTPResponse: Sendable {
    public var status: Int
    public var data: Data
    public var headers: [String: String]
    public init(status: Int, data: Data = Data(), headers: [String: String] = [:]) { self.status = status; self.data = data; self.headers = headers }
    public var ok: Bool { (200..<300).contains(status) }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Sends HTTP requests. Inject a fake in tests.
public protocol GuidelyTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
    /// Like `send`, but a `text/event-stream` body is delivered line by line to `onLine` as it
    /// arrives (the returned response then has an empty body). Other bodies are returned whole.
    func stream(_ request: URLRequest, onLine: @escaping @Sendable (String) async -> Void) async throws -> HTTPResponse
}

extension HTTPResponse {
    public var isEventStream: Bool { (header("Content-Type") ?? "").lowercased().contains("text/event-stream") }
}

/// Splits a body into lines (`\n` or `\r\n`), keeping empty lines (they end SSE events).
public func sseLines(_ data: Data) -> [String] {
    let text = String(decoding: data, as: UTF8.self)
    var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    if lines.last == "" { lines.removeLast() }
    return lines
}

extension GuidelyTransport {
    /// Fallback for transports that cannot stream: read the whole body, then replay its lines.
    public func stream(_ request: URLRequest, onLine: @escaping @Sendable (String) async -> Void) async throws -> HTTPResponse {
        let res = try await send(request)
        guard res.isEventStream else { return res }
        for line in sseLines(res.data) { await onLine(line) }
        return HTTPResponse(status: res.status, data: Data(), headers: res.headers)
    }
}

/// `URLSession` transport (default).
public final class URLSessionTransport: GuidelyTransport, @unchecked Sendable {
    private let session: URLSession
    /// Long-lived session for streamed Scout replies (keepalives arrive every 15 s; no short timeout).
    private let streamSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()
    public init(session: URLSession? = nil) {
        if let session { self.session = session } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 10
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.httpCookieStorage = nil
            cfg.httpShouldSetCookies = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return HTTPResponse(status: http?.statusCode ?? 0, data: data, headers: Self.headers(http))
    }

    private static func headers(_ http: HTTPURLResponse?) -> [String: String] {
        var headers: [String: String] = [:]
        http?.allHeaderFields.forEach { k, v in headers[String(describing: k)] = String(describing: v) }
        return headers
    }

    /// Streams `text/event-stream` responses with `URLSession.bytes`, line by line.
    public func stream(_ request: URLRequest, onLine: @escaping @Sendable (String) async -> Void) async throws -> HTTPResponse {
        var req = request
        req.timeoutInterval = 600
        let (bytes, response) = try await streamSession.bytes(for: req)
        let http = response as? HTTPURLResponse
        let head = HTTPResponse(status: http?.statusCode ?? 0, headers: Self.headers(http))
        var buffer = Data()
        if head.isEventStream {
            for try await byte in bytes {
                if byte == 0x0A {
                    var line = String(decoding: buffer, as: UTF8.self)
                    if line.hasSuffix("\r") { line.removeLast() }
                    buffer.removeAll(keepingCapacity: true)
                    await onLine(line)
                } else {
                    buffer.append(byte)
                }
            }
            if !buffer.isEmpty { await onLine(String(decoding: buffer, as: UTF8.self)) }
            return head
        }
        for try await byte in bytes { buffer.append(byte) }
        return HTTPResponse(status: head.status, data: buffer, headers: head.headers)
    }
}

/// Thin client for `<apiURL>/api/v1/sdk`. Adds the public key as `?key=` and `X-Guidely-Key`.
public struct GuidelyAPI: Sendable {
    public let baseURL: URL
    public let key: String
    public let transport: GuidelyTransport

    public init(baseURL: URL, key: String, transport: GuidelyTransport) {
        self.baseURL = baseURL; self.key = key; self.transport = transport
    }

    public func url(_ path: String, params: [String: String?] = [:]) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var comps = URLComponents(string: base + "/api/v1/sdk" + path) ?? URLComponents()
        var items = [URLQueryItem(name: "key", value: key)]
        for (k, v) in params.sorted(by: { $0.key < $1.key }) { if let v { items.append(URLQueryItem(name: k, value: v)) } }
        comps.queryItems = items
        return comps.url ?? baseURL
    }

    public func makeRequest(_ method: String, _ path: String, body: Data? = nil, etag: String? = nil, params: [String: String?] = [:], headers: [String: String] = [:]) -> URLRequest {
        var req = URLRequest(url: url(path, params: params))
        req.httpMethod = method
        req.timeoutInterval = 10
        req.setValue(key, forHTTPHeaderField: "X-Guidely-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    public func request(_ method: String, _ path: String, body: Data? = nil, etag: String? = nil, params: [String: String?] = [:], headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await transport.send(makeRequest(method, path, body: body, etag: etag, params: params, headers: headers))
    }

    /// POST that accepts either JSON or a server-sent event stream (Scout replies).
    public func postStream<T: Encodable & Sendable>(_ path: String, _ body: T, headers: [String: String] = [:], onLine: @escaping @Sendable (String) async -> Void) async throws -> HTTPResponse {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var req = makeRequest("POST", path, body: try enc.encode(body), headers: headers)
        req.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 600
        return try await transport.stream(req, onLine: onLine)
    }

    public func get(_ path: String, etag: String? = nil, params: [String: String?] = [:], headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await request("GET", path, etag: etag, params: params, headers: headers)
    }

    public func post<T: Encodable & Sendable>(_ path: String, _ body: T, headers: [String: String] = [:]) async throws -> HTTPResponse {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try await request("POST", path, body: try enc.encode(body), headers: headers)
    }
}

/// Exponential backoff: 1 s → 2 s → 4 s … capped at 30 s.
public func backoffSeconds(_ attempt: Int, base: Double = 1, max cap: Double = 30) -> Double {
    min(cap, base * pow(2, Double(Swift.max(0, attempt))))
}
