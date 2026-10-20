import Foundation

// Scout messenger types (`packages/shared/src/messenger.ts`). Decoding is tolerant like the rest
// of the config: missing fields take defaults, unknown values fall back.

public let MESSENGER_MAX_MESSAGE_LENGTH = 4000

/// `config.messenger`: present only when the project enabled Scout for this platform.
public struct MessengerConfig: Decodable, Sendable, Hashable {
    public var enabled: Bool
    /// Display name of the AI agent ("Scout").
    public var name: String
    public var greeting: String
    /// Scout answers with AI; when false every conversation goes to the team inbox.
    public var aiAvailable: Bool
    public var handoffEnabled: Bool
    public var launcherPosition: LauncherPosition

    public init(enabled: Bool = true, name: String = "Scout", greeting: String = "Hi! How can we help?", aiAvailable: Bool = false, handoffEnabled: Bool = true, launcherPosition: LauncherPosition = .bottomRight) {
        self.enabled = enabled; self.name = name; self.greeting = greeting; self.aiAvailable = aiAvailable
        self.handoffEnabled = handoffEnabled; self.launcherPosition = launcherPosition
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        enabled = c.lenient("enabled", false)
        name = c.lenient("name", "Scout")
        greeting = c.lenient("greeting", "Hi! How can we help?")
        aiAvailable = c.lenient("aiAvailable", false)
        handoffEnabled = c.lenient("handoffEnabled", true)
        let launcher: [String: JSONValue] = c.lenient("launcher", [:])
        launcherPosition = launcher["position"]?.stringValue.flatMap { LauncherPosition(rawValue: $0) } ?? .bottomRight
    }
}

public enum MessageAuthor: String, LenientStringEnum, CaseIterable {
    case user, scout, agent, system
    public static var fallbackCase: MessageAuthor { .system }
}

public enum ConversationStatus: String, LenientStringEnum, CaseIterable {
    case bot, open, closed
    public static var fallbackCase: ConversationStatus { .open }
}

public enum MessageStatus: String, LenientStringEnum, CaseIterable {
    case pending, complete, failed
    public static var fallbackCase: MessageStatus { .complete }
}

public struct MessengerCitation: Codable, Sendable, Hashable {
    public var articleId: String
    public var title: String
    public init(articleId: String, title: String) { self.articleId = articleId; self.title = title }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        articleId = try c.required("articleId")
        title = c.lenient("title", "Article")
    }
}

public struct MessengerSuggestedGuide: Codable, Sendable, Hashable {
    public var key: String
    public var name: String
    public init(key: String, name: String) { self.key = key; self.name = name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        key = try c.required("key")
        name = c.lenient("name", key)
    }
}

public struct MessengerMessage: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var author: MessageAuthor
    /// Team member name for `agent` messages.
    public var authorName: String?
    public var body: String
    public var citations: [MessengerCitation]
    public var suggestedGuides: [MessengerSuggestedGuide]
    public var status: MessageStatus
    public var createdAt: String

    public init(id: String, author: MessageAuthor, authorName: String? = nil, body: String, citations: [MessengerCitation] = [], suggestedGuides: [MessengerSuggestedGuide] = [], status: MessageStatus = .complete, createdAt: String) {
        self.id = id; self.author = author; self.authorName = authorName; self.body = body; self.citations = citations
        self.suggestedGuides = suggestedGuides; self.status = status; self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = try c.required("id")
        author = c.lenient("author", .system)
        authorName = c.optional("authorName")
        body = c.lenient("body", "")
        citations = c.lossy("citations")
        suggestedGuides = c.lossy("suggestedGuides")
        status = c.lenient("status", .complete)
        createdAt = c.lenient("createdAt", "")
    }
}

public struct MessengerConversation: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var status: ConversationStatus
    public var subject: String
    public var lastMessageAt: String
    public var lastMessagePreview: String
    public var unread: Int
    public var rating: Int?

    public init(id: String, status: ConversationStatus = .open, subject: String = "", lastMessageAt: String = "", lastMessagePreview: String = "", unread: Int = 0, rating: Int? = nil) {
        self.id = id; self.status = status; self.subject = subject; self.lastMessageAt = lastMessageAt
        self.lastMessagePreview = lastMessagePreview; self.unread = unread; self.rating = rating
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        id = try c.required("id")
        status = c.lenient("status", .open)
        subject = c.lenient("subject", "")
        lastMessageAt = c.lenient("lastMessageAt", "")
        lastMessagePreview = c.lenient("lastMessagePreview", "")
        unread = c.lenient("unread", 0)
        rating = c.optional("rating")
    }
}

public struct StartConversationResponse: Decodable, Sendable {
    public var conversation: MessengerConversation
    /// Secret that authorises this device to read and post in the conversation.
    public var token: String
    public var messages: [MessengerMessage]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        conversation = try c.required("conversation")
        token = try c.required("token")
        messages = c.lossy("messages")
    }
}

public struct ConversationMessagesResponse: Decodable, Sendable {
    public var conversation: MessengerConversation
    public var messages: [MessengerMessage]
    /// Present on start responses.
    public var token: String?

    public init(conversation: MessengerConversation, messages: [MessengerMessage]) { self.conversation = conversation; self.messages = messages }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        conversation = try c.required("conversation")
        messages = c.lossy("messages")
        token = c.optional("token")
    }
}

struct ConversationLookupResponse: Decodable {
    var conversations: [MessengerConversation]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        conversations = c.lossy("conversations")
    }
}

/// `GET /articles`: collections and article summaries (bodies are fetched on demand).
public struct SdkArticlesResponse: Decodable, Sendable, Hashable {
    public var collections: [ResourceCenterConfig.Collection]
    public var articles: [ResourceCenterArticle]

    public init(collections: [ResourceCenterConfig.Collection] = [], articles: [ResourceCenterArticle] = []) {
        self.collections = collections; self.articles = articles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GKey.self)
        collections = c.lossy("collections")
        articles = c.lossy("articles")
    }
}

/// Short relative time (`now`, `5m`, `3h`, `2d`), like the web messenger.
public func messengerRelativeTime(_ iso: String, now: Date = Date()) -> String {
    guard let ms = ISODate.parseMs(iso) else { return "now" }
    let s = max(0, Int(((now.timeIntervalSince1970 * 1000 - ms) / 1000).rounded()))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h" }
    return "\(s / 86400)d"
}
