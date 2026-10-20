import Foundation

// Scout messenger: SSE parsing, transport (port of `packages/sdk-core/src/messenger-api.ts`) and
// the headless messenger state machine (behaviour of `packages/guide-runtime/src/messenger.ts`).

// MARK: - Server-sent events

/// Incremental `text/event-stream` parser. Feed it lines (without the newline); it returns an
/// `(event, data)` pair when a blank line ends an event. Lines starting with `:` are comments.
public struct SSEParser {
    private var event = ""
    private var data: [String] = []

    public init() {}

    public mutating func feed(_ line: String) -> (event: String, data: String)? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    /// Dispatches a final event that was not followed by a blank line.
    public mutating func finish() -> (event: String, data: String)? { dispatch() }

    private mutating func dispatch() -> (event: String, data: String)? {
        defer { event = ""; data = [] }
        guard !data.isEmpty else { return nil }
        return (event.isEmpty ? "message" : event, data.joined(separator: "\n"))
    }
}

// MARK: - Transport

/// Callbacks while a message is sent and Scout replies.
public struct MessengerStreamHandlers {
    public var onConversation: @MainActor (MessengerConversation) -> Void = { _ in }
    public var onMessage: @MainActor (MessengerMessage) -> Void = { _ in }
    public var onDelta: @MainActor (_ messageId: String, _ text: String) -> Void = { _, _ in }
    public var onDone: @MainActor (MessengerMessage?, MessengerConversation) -> Void = { _, _ in }
    public var onError: @MainActor (String) -> Void = { _ in }
    public init() {}
}

public struct MessengerHTTPError: Error, LocalizedError {
    public let status: Int
    public var errorDescription: String? { "Request failed (\(status))" }
}

struct StoredConversation: Codable, Equatable {
    var id: String
    var token: String
}

/// The messenger's server access over the public SDK API. Conversation tokens are stored newest
/// first (max 50) under `guidely:conversations:<projectId>`.
@MainActor
public final class MessengerTransport {
    static let maxStored = 50
    static let tokenHeader = "X-Guidely-Conversation"

    let api: GuidelyAPI
    let store: GuidelyKeyValueStore
    let projectId: String
    let anonymousId: () -> String
    let userId: () -> String?
    let pageUrl: () -> String?

    public init(api: GuidelyAPI, store: GuidelyKeyValueStore, projectId: String, anonymousId: @escaping () -> String, userId: @escaping () -> String?, pageUrl: @escaping () -> String?) {
        self.api = api; self.store = store; self.projectId = projectId
        self.anonymousId = anonymousId; self.userId = userId; self.pageUrl = pageUrl
    }

    static func storageKey(_ projectId: String) -> String { "guidely:conversations:\(projectId)" }

    var stored: [StoredConversation] {
        store.readJSON(Self.storageKey(projectId), as: [StoredConversation].self) ?? []
    }

    func token(for id: String) -> String { stored.first { $0.id == id }?.token ?? "" }

    func remember(_ id: String, token: String) {
        let list = [StoredConversation(id: id, token: token)] + stored.filter { $0.id != id }
        store.writeJSON(Self.storageKey(projectId), Array(list.prefix(Self.maxStored)))
    }

    func forget(_ id: String) {
        store.writeJSON(Self.storageKey(projectId), stored.filter { $0.id != id })
    }

    /// Forgets every conversation token (`reset()`).
    public static func forgetAll(store: GuidelyKeyValueStore, projectId: String) {
        store.remove(storageKey(projectId))
    }

    private func headers(_ id: String) -> [String: String] { [Self.tokenHeader: token(for: id)] }

    private func path(_ id: String, _ suffix: String) -> String {
        "/conversations/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)\(suffix)"
    }

    private func decode<T: Decodable>(_ type: T.Type, _ res: HTTPResponse) throws -> T {
        guard res.ok else { throw MessengerHTTPError(status: res.status) }
        do { return try JSONDecoder().decode(T.self, from: res.data) } catch { throw MessengerHTTPError(status: res.status) }
    }

    private struct Tokens: Encodable { let tokens: [String] }

    /// Conversations this device holds tokens for; drops tokens the server no longer returns.
    public func listConversations() async throws -> [MessengerConversation] {
        let tokens = stored.map(\.token)
        if tokens.isEmpty { return [] }
        let res = try await api.post("/conversations/lookup", Tokens(tokens: tokens))
        let list = try decode(ConversationLookupResponse.self, res).conversations
        let known = Set(list.map(\.id))
        for c in stored where !known.contains(c.id) { forget(c.id) }
        return list
    }

    public func loadMessages(_ id: String, since: String? = nil) async throws -> ConversationMessagesResponse {
        let res = try await api.get(path(id, "/messages"), params: ["since": since], headers: headers(id))
        return try decode(ConversationMessagesResponse.self, res)
    }

    private struct StartBody: Encodable { let anonymousId: String; let userId: String?; let message: String; let pageUrl: String? }
    private struct MessageBody: Encodable { let message: String }
    private struct Empty: Encodable {}
    private struct Rating: Encodable { let rating: Int }

    /// Starts a conversation (stores its token).
    public func start(_ text: String, _ h: MessengerStreamHandlers) async throws {
        let body = StartBody(anonymousId: anonymousId(), userId: userId(), message: String(text.prefix(MESSENGER_MAX_MESSAGE_LENGTH)), pageUrl: pageUrl())
        try await exchange("/conversations", body, headers: [:], h) { [weak self] id, token in self?.remember(id, token: token) }
    }

    public func send(_ id: String, _ text: String, _ h: MessengerStreamHandlers) async throws {
        try await exchange(path(id, "/messages"), MessageBody(message: String(text.prefix(MESSENGER_MAX_MESSAGE_LENGTH))), headers: headers(id), h, onStarted: nil)
    }

    public func handoff(_ id: String) async throws -> ConversationMessagesResponse {
        try decode(ConversationMessagesResponse.self, try await api.post(path(id, "/handoff"), Empty(), headers: headers(id)))
    }

    public func rate(_ id: String, _ rating: Int) async throws {
        let res = try await api.post(path(id, "/rating"), Rating(rating: rating), headers: headers(id))
        if !res.ok { throw MessengerHTTPError(status: res.status) }
    }

    public func listArticles() async throws -> SdkArticlesResponse {
        try decode(SdkArticlesResponse.self, try await api.get("/articles"))
    }

    private struct ArticleResponse: Decodable { let article: ResourceCenterArticle }
    private struct SearchResponse: Decodable {
        let articles: [ResourceCenterArticle]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: GKey.self)
            articles = c.lossy("articles")
        }
    }

    public func getArticle(_ id: String) async -> ResourceCenterArticle? {
        guard let res = try? await api.get("/articles/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"), res.ok else { return nil }
        return (try? JSONDecoder().decode(ArticleResponse.self, from: res.data))?.article
    }

    public func searchArticles(_ q: String) async -> [ResourceCenterArticle] {
        guard let res = try? await api.get("/resource-center/search", params: ["q": q]), res.ok else { return [] }
        return (try? JSONDecoder().decode(SearchResponse.self, from: res.data))?.articles ?? []
    }

    /// Dispatches either SSE events or a JSON answer to the handlers.
    private func exchange<B: Encodable & Sendable>(_ path: String, _ body: B, headers: [String: String], _ h: MessengerStreamHandlers, onStarted: ((String, String) -> Void)?) async throws {
        let sink = StreamSink(handlers: h, onStarted: onStarted)
        let res = try await api.postStream(path, body, headers: headers) { line in await sink.feed(line) }
        guard res.ok else { throw MessengerHTTPError(status: res.status) }
        if res.isEventStream {
            sink.finish()
            if !sink.finished { h.onError("The reply was interrupted") }
            return
        }
        // JSON answer (no Scout reply): the stored messages and the conversation.
        let d = try decode(ConversationMessagesResponse.self, res)
        if let token = d.token {
            onStarted?(d.conversation.id, token)
            h.onConversation(d.conversation)
        }
        d.messages.forEach(h.onMessage)
        h.onDone(d.messages.last, d.conversation)
    }
}

/// Parses streamed lines and forwards events to the handlers on the main actor.
@MainActor
final class StreamSink {
    private var parser = SSEParser()
    let handlers: MessengerStreamHandlers
    let onStarted: ((String, String) -> Void)?
    private(set) var finished = false

    init(handlers: MessengerStreamHandlers, onStarted: ((String, String) -> Void)?) {
        self.handlers = handlers
        self.onStarted = onStarted
    }

    func feed(_ line: String) {
        if let e = parser.feed(line) { handle(e.event, e.data) }
    }

    func finish() {
        if let e = parser.finish() { handle(e.event, e.data) }
    }

    private struct Delta: Decodable { let messageId: String; let text: String }
    private struct Done: Decodable {
        let message: MessengerMessage?
        let conversation: MessengerConversation
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: GKey.self)
            message = c.optional("message")
            conversation = try c.required("conversation")
        }
    }
    private struct ErrorData: Decodable { let message: String? }

    func handle(_ event: String, _ data: String) {
        let json = Data(data.utf8)
        let dec = JSONDecoder()
        switch event {
        case "conversation":
            guard let d = try? dec.decode(StartConversationResponse.self, from: json) else { return }
            onStarted?(d.conversation.id, d.token)
            handlers.onConversation(d.conversation)
            d.messages.forEach(handlers.onMessage)
        case "message":
            if let m = try? dec.decode(MessengerMessage.self, from: json) { handlers.onMessage(m) }
        case "delta":
            if let d = try? dec.decode(Delta.self, from: json) { handlers.onDelta(d.messageId, d.text) }
        case "done":
            guard let d = try? dec.decode(Done.self, from: json) else { return }
            finished = true
            handlers.onDone(d.message, d.conversation)
        case "error":
            handlers.onError((try? dec.decode(ErrorData.self, from: json))?.message ?? "Something went wrong")
        default:
            break
        }
    }
}

// MARK: - Messenger state

public enum MessengerTab: String, Sendable, CaseIterable {
    case home, messages, help
}

public enum MessengerView: Equatable, Sendable {
    case tab(MessengerTab)
    /// A conversation (nil = new conversation).
    case thread(String?)
}

/// Headless messenger: conversations, the open thread, streaming replies, polling and the Help tab.
/// The UI observes it through `onChange`.
@MainActor
public final class MessengerController {
    public let config: MessengerConfig
    public let transport: MessengerTransport
    let scheduler: GuidelyScheduler
    /// Resource center extras (recommended guides, checklists, FAQs, links) shown in Help.
    public let resourceCenter: ResourceCenterConfig?
    public let guideRefs: [ResourceCenterGuideRef]
    public var threadPollInterval: TimeInterval = 5
    public var backgroundPollInterval: TimeInterval = 60

    public private(set) var isOpen = false
    public private(set) var view: MessengerView = .tab(.home)
    public private(set) var conversations: [MessengerConversation] = []
    public private(set) var messages: [MessengerMessage] = []
    public private(set) var current: MessengerConversation?
    /// Live text of Scout replies being streamed (message id → text so far).
    public private(set) var streaming: [String: String] = [:]
    public private(set) var sending = false
    /// Composer text.
    public var draft = "" {
        didSet {
            if draft.count > MESSENGER_MAX_MESSAGE_LENGTH { draft = String(draft.prefix(MESSENGER_MAX_MESSAGE_LENGTH)) }
            if draft != oldValue { changed() }
        }
    }
    public private(set) var articles: SdkArticlesResponse?
    public private(set) var helpQuery = ""
    public private(set) var helpResults: [ResourceCenterArticle] = []
    public private(set) var helpArticle: ResourceCenterArticle?
    public private(set) var helpArticleLoading = false
    public private(set) var handoffInFlight = false

    public var onChange: () -> Void = {}
    public var onOpen: () -> Void = {}
    public var onClose: () -> Void = {}
    /// Every Scout or agent message received (`conversation:message`).
    public var onMessage: (MessengerMessage, MessengerConversation) -> Void = { _, _ in }
    public var onStartGuide: (String) -> Void = { _ in }
    public var onOpenChecklist: (String) -> Void = { _ in }
    public var onArticleView: (ResourceCenterArticle) -> Void = { _ in }
    public var onOpenURL: (String) -> Void = { _ in }
    /// The end user's audiences (from the last identify), for audience-targeted collections and articles.
    public var audienceIds: () -> Set<String> = { [] }

    private var threadSeq = 0
    private var threadTimer: GuidelyCancellable?
    private var backgroundTimer: GuidelyCancellable?
    private var helpSeq = 0
    private var articlesLoading = false
    private var foreground = true
    private var destroyed = false
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(config: MessengerConfig, transport: MessengerTransport, scheduler: GuidelyScheduler, resourceCenter: ResourceCenterConfig? = nil, guideRefs: [ResourceCenterGuideRef] = []) {
        self.config = config
        self.transport = transport
        self.scheduler = scheduler
        self.resourceCenter = resourceCenter
        self.guideRefs = guideRefs
    }

    // MARK: Derived state

    /// Conversations with unread messages (launcher badge).
    public var unreadCount: Int { conversations.filter { $0.unread > 0 }.count }

    public var canHandoff: Bool { config.handoffEnabled && config.aiAvailable && current?.status == .bot && !sending }
    public var needsRating: Bool { current?.status == .closed && current?.rating == nil }
    public var rated: Bool { current?.status == .closed && current?.rating != nil }
    public var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var recommended: [ResourceCenterGuideRef] { (resourceCenter?.recommendedGuideIds ?? []).compactMap { id in guideRefs.first { $0.id == id || $0.key == id } } }
    public var checklists: [ResourceCenterGuideRef] { (resourceCenter?.checklistGuideIds ?? []).compactMap { id in guideRefs.first { $0.id == id || $0.key == id } } }
    public var faqs: [ResourceCenterConfig.FAQ] { resourceCenter?.faqs ?? [] }
    public var links: [ResourceCenterConfig.Link] { resourceCenter?.links ?? [] }

    private var helpCollections: [ResourceCenterConfig.Collection] { articles?.collections ?? resourceCenter?.collections ?? [] }

    /// Help sections: nested collections depth first ("Billing › Invoices"), then uncollected
    /// articles ("Articles"), filtered by the end user's audiences.
    public var articleSections: [ResourceCenterSection] {
        ResourceCenterLayout.sections(helpCollections, articles?.articles ?? resourceCenter?.articles ?? [], member: audienceIds())
    }

    // MARK: Lifecycle

    /// Loads conversations (badge) and starts background polling.
    public func start() {
        spawn { [weak self] in await self?.refreshConversations() }
        scheduleBackgroundPoll()
    }

    public func destroy() {
        destroyed = true
        threadTimer?.cancel(); backgroundTimer?.cancel()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// Polling only runs while the app is in the foreground.
    public func setForeground(_ value: Bool) {
        foreground = value
        if value {
            scheduleBackgroundPoll()
            scheduleThreadPoll()
            if isOpen { spawn { [weak self] in await self?.refreshConversations() } }
        } else {
            threadTimer?.cancel(); threadTimer = nil
            backgroundTimer?.cancel(); backgroundTimer = nil
        }
    }

    func spawn(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        tasks[id] = Task { @MainActor [weak self] in
            await work()
            self?.tasks[id] = nil
        }
    }

    /// Waits for background work (tests).
    public func settle() async {
        var rounds = 0
        while let (id, t) = tasks.first, rounds < 1000 {
            await t.value
            tasks[id] = nil
            rounds += 1
        }
    }

    private func changed() { if !destroyed { onChange() } }

    // MARK: Open / close / navigation

    public func open(_ tab: MessengerTab? = nil) {
        if let tab { go(.tab(tab)) }
        guard !isOpen else { changed(); return }
        isOpen = true
        changed()
        spawn { [weak self] in await self?.refreshConversations() }
        // Reopening on a thread fetches what arrived while the sheet was closed right away.
        if case .thread(let id?) = view, current?.id == id { spawn { [weak self] in await self?.pollThread() } } else { scheduleThreadPoll() }
        onOpen()
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        threadTimer?.cancel(); threadTimer = nil
        changed()
        onClose()
    }

    /// Opens a new conversation with the composer pre-filled.
    public func showNewMessage(_ text: String? = nil) {
        go(.thread(nil))
        if let text { draft = text }
        open()
    }

    public func go(_ next: MessengerView) {
        threadSeq += 1
        threadTimer?.cancel(); threadTimer = nil
        if case .tab(.help) = view, next != .tab(.help) { resetHelp() }
        view = next
        switch next {
        case .thread(let id):
            messages = []
            streaming = [:]
            sending = false
            current = id.flatMap { cid in conversations.first { $0.id == cid } }
            changed()
            if let id {
                let seq = threadSeq
                spawn { [weak self] in
                    guard let self else { return }
                    if let res = try? await self.transport.loadMessages(id), seq == self.threadSeq {
                        res.messages.forEach(self.upsertMessage)
                        self.current = self.markRead(res.conversation)
                        self.upsertConversation(self.current!)
                        self.changed()
                    }
                    self.scheduleThreadPoll()
                }
            }
        case .tab(let tab):
            draft = ""
            if tab == .help { loadArticles() }
            changed()
        }
    }

    private func markRead(_ c: MessengerConversation) -> MessengerConversation {
        var c = c
        c.unread = 0
        return c
    }

    func upsertConversation(_ c: MessengerConversation) {
        conversations = ([c] + conversations.filter { $0.id != c.id }).sorted { $0.lastMessageAt > $1.lastMessageAt }
        if current?.id == c.id { current = c }
    }

    func upsertMessage(_ m: MessengerMessage) {
        if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i] = m } else { messages.append(m) }
        messages.sort { $0.createdAt < $1.createdAt }
        if m.status != .pending { streaming[m.id] = nil }
    }

    // MARK: Server

    public func refreshConversations() async {
        guard let list = try? await transport.listConversations() else { return }
        conversations = list.sorted { $0.lastMessageAt > $1.lastMessageAt }
        if let cur = current, let fresh = conversations.first(where: { $0.id == cur.id }), case .thread = view, isOpen {
            current = markRead(fresh)
            upsertConversation(current!)
        }
        changed()
    }

    private func handlers(_ seq: Int) -> MessengerStreamHandlers {
        var h = MessengerStreamHandlers()
        h.onConversation = { [weak self] c in
            guard let self, seq == self.threadSeq else { return }
            self.current = c
            self.view = .thread(c.id)
            self.upsertConversation(c)
            self.changed()
        }
        h.onMessage = { [weak self] m in
            guard let self, seq == self.threadSeq else { return }
            self.upsertMessage(m)
            self.changed()
        }
        h.onDelta = { [weak self] id, text in
            guard let self, seq == self.threadSeq else { return }
            self.streaming[id, default: ""] += text
            self.changed()
        }
        h.onDone = { [weak self] m, c in
            guard let self, seq == self.threadSeq else { return }
            if let m {
                self.upsertMessage(m)
                if m.author != .user { self.onMessage(m, c) }
            }
            let read = self.markRead(c)
            self.upsertConversation(read)
            self.current = read
            self.changed()
        }
        h.onError = { _ in /* the server also stores a system message explaining what happened */ }
        return h
    }

    /// Sends the composer text (starts a conversation when none is open).
    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sending, !text.isEmpty else { return }
        sending = true
        draft = ""
        changed()
        let seq = threadSeq
        let h = handlers(seq)
        let currentId = current?.id
        spawn { [weak self] in
            guard let self else { return }
            do {
                if let id = currentId { try await self.transport.send(id, text, h) } else { try await self.transport.start(text, h) }
            } catch {
                if seq == self.threadSeq {
                    self.draft = text
                    self.upsertMessage(MessengerMessage(id: "local_\(GuidelyUtils.randomId(8))", author: .system, body: "Your message couldn't be sent. Please try again.", createdAt: ISODate.format(self.scheduler.now)))
                }
            }
            guard seq == self.threadSeq else { return }
            self.sending = false
            self.streaming = [:]
            self.changed()
            self.scheduleThreadPoll()
        }
    }

    public func handoff() {
        guard let id = current?.id, !handoffInFlight else { return }
        handoffInFlight = true
        changed()
        spawn { [weak self] in
            guard let self else { return }
            if let res = try? await self.transport.handoff(id), self.current?.id == id {
                self.upsertConversation(res.conversation)
                res.messages.forEach(self.upsertMessage)
            }
            self.handoffInFlight = false
            self.changed()
        }
    }

    public func rate(_ score: Int) {
        guard var c = current else { return }
        c.rating = max(1, min(5, score))
        current = c
        upsertConversation(c)
        changed()
        let id = c.id
        spawn { [weak self] in try? await self?.transport.rate(id, c.rating ?? score) }
    }

    // MARK: Polling

    private func scheduleThreadPoll() {
        threadTimer?.cancel(); threadTimer = nil
        guard isOpen, foreground, !destroyed, case .thread = view, current != nil else { return }
        threadTimer = scheduler.schedule(after: threadPollInterval) { [weak self] in
            self?.spawn { [weak self] in await self?.pollThread() }
        }
    }

    func pollThread() async {
        guard let cur = current, !sending else { return scheduleThreadPoll() }
        let seq = threadSeq
        let pending = messages.first { $0.status == .pending }
        let last = messages.filter { !$0.id.hasPrefix("local_") }.last
        // Re-fetch from a pending reply (its body changes in place); otherwise only newer messages.
        var since: String? = last?.createdAt
        if let p = pending, let ms = ISODate.parseMs(p.createdAt) { since = ISODate.format(Date(timeIntervalSince1970: (ms - 1) / 1000)) }
        if let res = try? await transport.loadMessages(cur.id, since: since), seq == threadSeq {
            let before = messages
            res.messages.forEach(upsertMessage)
            let read = markRead(res.conversation)
            upsertConversation(read)
            current = read
            let fresh = res.messages.filter { m in !before.contains { $0.id == m.id && $0.status == m.status && $0.body == m.body } }
            for m in fresh where m.author != .user { onMessage(m, res.conversation) }
            changed()
        }
        scheduleThreadPoll()
    }

    private func scheduleBackgroundPoll() {
        backgroundTimer?.cancel(); backgroundTimer = nil
        guard foreground, !destroyed else { return }
        backgroundTimer = scheduler.schedule(after: backgroundPollInterval) { [weak self] in
            guard let self else { return }
            if !self.isOpen, !self.transport.stored.isEmpty { self.spawn { [weak self] in await self?.refreshConversations() } }
            self.scheduleBackgroundPoll()
        }
    }

    // MARK: Help

    public func loadArticles() {
        guard articles == nil, !articlesLoading else { return }
        articlesLoading = true
        spawn { [weak self] in
            guard let self else { return }
            if let res = try? await self.transport.listArticles() { self.articles = res }
            self.articlesLoading = false
            self.changed()
        }
    }

    public func searchHelp(_ q: String) {
        helpQuery = q
        helpArticle = nil
        helpSeq += 1
        let seq = helpSeq
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        changed()
        guard !trimmed.isEmpty else { helpResults = []; return }
        spawn { [weak self] in
            guard let self else { return }
            await self.scheduler.sleep(0.25)
            guard seq == self.helpSeq else { return }
            let server = await self.transport.searchArticles(trimmed)
            guard seq == self.helpSeq else { return }
            let lower = trimmed.lowercased()
            let local = (self.articles?.articles ?? self.resourceCenter?.articles ?? []).filter { $0.title.lowercased().contains(lower) || $0.summary.lowercased().contains(lower) }
            let member = self.audienceIds()
            self.helpResults = ResourceCenterPresentation.merge(local: local, server: server).filter { ResourceCenterLayout.isArticleListed(self.helpCollections, $0, member: member) }
            self.changed()
        }
    }

    /// Opens an article (Help tab); bodies are fetched on demand.
    public func openArticle(_ id: String) {
        if view != .tab(.help) { go(.tab(.help)) }
        let known = (articles?.articles ?? []) + (resourceCenter?.articles ?? []) + helpResults
        if let a = known.first(where: { $0.id == id }), let ext = a.externalUrl, !ext.isEmpty {
            onArticleView(a)
            onOpenURL(ext)
            return
        }
        helpSeq += 1
        let seq = helpSeq
        helpArticle = known.first { $0.id == id && !$0.body.isEmpty }
        helpArticleLoading = helpArticle == nil
        changed()
        spawn { [weak self] in
            guard let self else { return }
            let full = await self.transport.getArticle(id)
            guard seq == self.helpSeq else { return }
            if let full { self.helpArticle = full }
            self.helpArticleLoading = false
            if let a = self.helpArticle ?? known.first(where: { $0.id == id }) {
                if self.helpArticle == nil { self.helpArticle = a }
                self.onArticleView(a)
            }
            self.changed()
        }
    }

    public func closeArticle() {
        helpArticle = nil
        helpArticleLoading = false
        changed()
    }

    private func resetHelp() {
        helpQuery = ""
        helpResults = []
        helpArticle = nil
        helpArticleLoading = false
    }

    /// "Show me" (suggested guide) or a recommended guide: closes the messenger and starts it.
    public func startGuide(_ keyOrId: String) {
        close()
        onStartGuide(keyOrId)
    }

    public func openChecklist(_ id: String) {
        close()
        onOpenChecklist(id)
    }
}
