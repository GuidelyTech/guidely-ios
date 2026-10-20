import Foundation

/// Analytics event names accepted by `POST /events` (`packages/shared/src/events.ts`).
public enum SdkEventName: String, Codable, Sendable, CaseIterable {
    case guideViewed = "guide_viewed", guideStarted = "guide_started", stepViewed = "step_viewed", stepCompleted = "step_completed"
    case guideCompleted = "guide_completed", guideSkipped = "guide_skipped", guideDismissed = "guide_dismissed", guideAbandoned = "guide_abandoned"
    case checklistTaskCompleted = "checklist_task_completed", checklistCompleted = "checklist_completed", checklistDismissed = "checklist_dismissed"
    case surveyDisplayed = "survey_displayed", surveySubmitted = "survey_submitted", surveyDismissed = "survey_dismissed"
    case resourceCenterOpened = "resource_center_opened", articleViewed = "article_viewed"
    case messengerOpened = "messenger_opened", conversationStarted = "conversation_started", conversationHandedOff = "conversation_handed_off", scoutAnswered = "scout_answered"
    case custom, pageView = "page_view", identify
    /// A user was bucketed into an experiment variation (properties: experimentKey, variationId, variationName, flagKey, hashAttribute).
    case experimentViewed = "experiment_viewed"
}

/// Event as produced by the SDK and accepted by `POST /api/v1/sdk/events`.
public struct SdkEvent: Codable, Sendable, Hashable {
    public var eventId: String
    public var name: SdkEventName
    public var customName: String?
    public var occurredAt: String
    public var anonymousId: String
    public var userId: String?
    public var accountId: String?
    public var sessionId: String?
    public var guideId: String?
    public var guideVersion: Int?
    public var stepId: String?
    public var stepIndex: Int?
    public var url: String?
    public var properties: [String: JSONValue]?

    public init(eventId: String, name: SdkEventName, customName: String? = nil, occurredAt: String, anonymousId: String, userId: String? = nil, accountId: String? = nil, sessionId: String? = nil, guideId: String? = nil, guideVersion: Int? = nil, stepId: String? = nil, stepIndex: Int? = nil, url: String? = nil, properties: [String: JSONValue]? = nil) {
        self.eventId = eventId; self.name = name; self.customName = customName; self.occurredAt = occurredAt; self.anonymousId = anonymousId
        self.userId = userId; self.accountId = accountId; self.sessionId = sessionId; self.guideId = guideId; self.guideVersion = guideVersion
        self.stepId = stepId; self.stepIndex = stepIndex; self.url = url; self.properties = properties
    }
}

struct EventBatch: Encodable {
    struct SDK: Encodable { let name: String; let version: String }
    let events: [SdkEvent]
    let sentAt: String
    let sdk: SDK
}

/// Bounded, persisted event queue: batches ≤ 50 events every 2 s (or on demand), dedupes by
/// `eventId`, retries with exponential backoff (1 s → 30 s, 5 attempts), drops the oldest events
/// beyond 200. A `4xx` other than `429` drops the batch.
@MainActor
final class EventQueue {
    struct SendResult { var ok: Bool; var retry: Bool }

    private(set) var events: [SdkEvent] = []
    private let store: GuidelyKeyValueStore
    private let storageKey: String
    private let scheduler: GuidelyScheduler
    private let send: ([SdkEvent]) async throws -> SendResult
    private let enabled: () -> Bool
    private let onError: (Error) -> Void
    private let spawn: (@escaping @MainActor () async -> Void) -> Void
    let flushInterval: TimeInterval
    let maxQueue: Int
    let batchSize: Int
    let maxAttempts: Int
    private var timer: GuidelyCancellable?
    private var retryTimer: GuidelyCancellable?
    private(set) var inflight = false
    private var attempt = 0
    private var destroyed = false

    init(store: GuidelyKeyValueStore, storageKey: String, scheduler: GuidelyScheduler, flushInterval: TimeInterval = 2, maxQueue: Int = 200, batchSize: Int = 50, maxAttempts: Int = 5, enabled: @escaping () -> Bool, send: @escaping ([SdkEvent]) async throws -> SendResult, onError: @escaping (Error) -> Void, spawn: @escaping (@escaping @MainActor () async -> Void) -> Void) {
        self.spawn = spawn
        self.store = store; self.storageKey = storageKey; self.scheduler = scheduler; self.flushInterval = flushInterval
        self.maxQueue = maxQueue; self.batchSize = batchSize; self.maxAttempts = maxAttempts; self.enabled = enabled; self.send = send; self.onError = onError
        if let persisted = store.readJSON(storageKey, as: [SdkEvent].self) { events = Array(persisted.suffix(maxQueue)) }
        if !events.isEmpty { schedule() }
    }

    var size: Int { events.count }

    func enqueue(_ event: SdkEvent) {
        guard !destroyed, !events.contains(where: { $0.eventId == event.eventId }) else { return }
        events.append(event)
        if events.count > maxQueue { events.removeFirst(events.count - maxQueue) }
        persist()
        schedule()
    }

    private func persist() { store.writeJSON(storageKey, events) }

    private func schedule() {
        guard timer == nil, retryTimer == nil, !destroyed else { return }
        timer = scheduler.schedule(after: flushInterval) { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.spawn { await self.flush() }
        }
    }

    /// Sends queued events now (one batch at a time).
    func flush() async {
        guard !destroyed, !inflight, !events.isEmpty, enabled() else { return }
        timer?.cancel()
        timer = nil
        inflight = true
        let batch = Array(events.prefix(batchSize))
        var ok = false
        var retry = true
        do {
            let res = try await send(batch)
            ok = res.ok
            retry = res.retry
        } catch {
            onError(error)
        }
        inflight = false
        if destroyed { return }
        if ok || !retry {
            let ids = Set(batch.map(\.eventId))
            events.removeAll { ids.contains($0.eventId) }
            attempt = 0
            persist()
            if !events.isEmpty { schedule() }
            return
        }
        attempt += 1
        if attempt >= maxAttempts {
            // Give up for now; events stay queued until the next flush trigger.
            attempt = 0
            return
        }
        retryTimer = scheduler.schedule(after: backoffSeconds(attempt - 1)) { [weak self] in
            guard let self else { return }
            self.retryTimer = nil
            self.spawn { await self.flush() }
        }
    }

    /// Flushes everything (several batches) — used when the app moves to the background.
    func flushAll() async {
        var guardCount = 0
        while !events.isEmpty, enabled(), !destroyed, guardCount < 10 {
            let before = events.count
            retryTimer?.cancel(); retryTimer = nil
            await flush()
            guardCount += 1
            if events.count >= before { break }
        }
    }

    func clear() {
        events = []
        persist()
    }

    func destroy() {
        destroyed = true
        timer?.cancel(); retryTimer?.cancel()
        timer = nil; retryTimer = nil
        persist()
    }
}
