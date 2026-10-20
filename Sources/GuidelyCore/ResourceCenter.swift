import Foundation

/// Collections nest at most this deep (a collection, its sections, and their sub-sections).
public let MAX_COLLECTION_DEPTH = 3

/// A group of help articles in display order (`RcSection` in `packages/shared/src/resource-center.ts`).
public struct ResourceCenterSection: Sendable, Hashable, Identifiable {
    /// nil for articles outside any (known) collection.
    public var collection: ResourceCenterConfig.Collection?
    /// Collection names from the top level down, e.g. `["Billing", "Invoices"]`.
    public var path: [String]
    /// 0 for a top-level collection.
    public var depth: Int
    public var articles: [ResourceCenterArticle]

    public var id: String { collection?.id ?? "" }
    /// Header text: the path joined with " › ", or "Articles" for uncategorized articles.
    public var title: String { collection == nil ? "Articles" : path.joined(separator: " › ") }
}

/// Resource center structure shared by every SDK: nested collections and audience targeting.
/// Audience targeting decides what the help views list; it is not access control.
public enum ResourceCenterLayout {
    /// True when an item targeted at `required` audiences is shown to someone in `member`
    /// (no audiences = everyone, otherwise membership of any one).
    public static func matchesAudiences(_ required: [String]?, _ member: Set<String>) -> Bool {
        guard let required, !required.isEmpty else { return true }
        return required.contains { member.contains($0) }
    }

    /// Article sections in display order: each collection (depth first, siblings by `order` then name)
    /// with the visible articles filed directly in it, then the uncategorized articles. A collection the
    /// viewer isn't targeted by hides its whole subtree; sections without visible articles are left out
    /// (their sub-collections still appear); unknown parents count as top level.
    public static func sections(_ collections: [ResourceCenterConfig.Collection], _ articles: [ResourceCenterArticle], member: Set<String> = []) -> [ResourceCenterSection] {
        let byId = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        var children: [String: [ResourceCenterConfig.Collection]] = [:]
        var roots: [ResourceCenterConfig.Collection] = []
        for c in collections {
            if let p = c.parentId, p != c.id, byId[p] != nil { children[p, default: []].append(c) } else { roots.append(c) }
        }
        func sorted(_ list: [ResourceCenterConfig.Collection]) -> [ResourceCenterConfig.Collection] {
            list.enumerated().sorted { a, b in
                if a.element.order != b.element.order { return a.element.order < b.element.order }
                let byName = a.element.name.localizedCompare(b.element.name)
                return byName == .orderedSame ? a.offset < b.offset : byName == .orderedAscending
            }.map(\.element)
        }
        var direct: [String: [ResourceCenterArticle]] = [:]
        var uncategorized: [ResourceCenterArticle] = []
        for a in articles where matchesAudiences(a.audienceIds, member) {
            if let cid = a.collectionId, byId[cid] != nil { direct[cid, default: []].append(a) } else { uncategorized.append(a) }
        }

        var out: [ResourceCenterSection] = []
        var seen = Set<String>()
        func visit(_ c: ResourceCenterConfig.Collection, _ path: [String]) {
            // A parent cycle in bad data would otherwise recurse forever; cycle members simply don't show.
            guard seen.insert(c.id).inserted, matchesAudiences(c.audienceIds, member) else { return }
            let here = path + [c.name]
            if let list = direct[c.id], !list.isEmpty { out.append(ResourceCenterSection(collection: c, path: here, depth: here.count - 1, articles: list)) }
            for child in sorted(children[c.id] ?? []) { visit(child, here) }
        }
        for root in sorted(roots) { visit(root, []) }
        if !uncategorized.isEmpty { out.append(ResourceCenterSection(collection: nil, path: [], depth: 0, articles: uncategorized)) }
        return out
    }

    /// Whether one article is listed for a viewer: its own audiences and those of every collection
    /// above it must match. For articles outside a loaded list (e.g. server search results).
    public static func isArticleListed(_ collections: [ResourceCenterConfig.Collection], _ article: ResourceCenterArticle, member: Set<String> = []) -> Bool {
        guard matchesAudiences(article.audienceIds, member) else { return false }
        let byId = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        var cur = article.collectionId.flatMap { byId[$0] }
        var guardCount = 0
        while let c = cur, guardCount <= MAX_COLLECTION_DEPTH * 4 {
            if !matchesAudiences(c.audienceIds, member) { return false }
            cur = c.parentId.flatMap { byId[$0] }
            guardCount += 1
        }
        return true
    }
}
