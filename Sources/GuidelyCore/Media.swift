import Foundation

/// Video host of an article embed.
public enum EmbedProvider: String, Sendable, Hashable {
    case youtube, vimeo, loom, wistia

    /// Label of the link shown instead of an inline player.
    public var watchLabel: String {
        switch self {
        case .youtube: return "Watch on YouTube"
        case .vimeo: return "Watch on Vimeo"
        case .loom: return "Watch on Loom"
        case .wistia: return "Watch video"
        }
    }
}

/// Canonical embed of a video page or player URL (`VideoEmbed` in `packages/shared/src/media.ts`).
public struct VideoEmbed: Sendable, Hashable {
    public var provider: EmbedProvider
    /// Canonical player URL (the only iframe `src` sanitizers keep).
    public var src: String
    /// Page a viewer can open instead (native SDKs show a link rather than a player).
    public var watchUrl: String
    public var title: String
}

/// Media in article bodies: uploaded images, videos and PDFs, and video embeds from a fixed set of hosts
/// (port of `packages/shared/src/media.ts`).
public enum GuidelyMedia {
    private static let youtubeId = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{11}$")
    private static let vimeoId = try! NSRegularExpression(pattern: "^\\d{1,12}$")
    private static let vimeoHash = try! NSRegularExpression(pattern: "^[0-9a-f]{6,20}$", options: .caseInsensitive)
    private static let loomId = try! NSRegularExpression(pattern: "^[0-9a-f]{32}$", options: .caseInsensitive)
    private static let wistiaId = try! NSRegularExpression(pattern: "^[a-z0-9]{10}$", options: .caseInsensitive)
    private static let wistiaHost = try! NSRegularExpression(pattern: "^[a-z0-9-]+\\.wistia\\.com$")
    private static let scheme = try! NSRegularExpression(pattern: "^[a-z][a-z0-9+.-]*:", options: .caseInsensitive)
    private static let duration = try! NSRegularExpression(pattern: "^(?:(\\d+)h)?(?:(\\d+)m)?(?:(\\d+)s)?$")

    private static func test(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func parseUrl(_ input: String) -> URLComponents? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URLComponents(string: test(scheme, s) ? s : "https://\(s)") else { return nil }
        guard let sc = u.scheme?.lowercased(), sc == "https" || sc == "http", let host = u.host, !host.isEmpty else { return nil }
        if u.user != nil || u.password != nil { return nil }
        if let port = u.port, port != 443 && port != 80 { return nil }
        return u
    }

    /// "1h2m3s", "90s", "90" → seconds (capped at a day).
    private static func parseStart(_ v: String?) -> Int {
        guard let v, !v.isEmpty else { return 0 }
        if v.allSatisfy(\.isASCII), v.allSatisfy(\.isNumber) { return Int(min(Double(v) ?? 0, 86400)) }
        let ns = v as NSString
        guard let m = duration.firstMatch(in: v, range: NSRange(location: 0, length: ns.length)), m.range.length > 0 else { return 0 }
        func part(_ i: Int) -> Double { m.range(at: i).location == NSNotFound ? 0 : Double(ns.substring(with: m.range(at: i))) ?? 0 }
        return Int(min(part(1) * 3600 + part(2) * 60 + part(3), 86400))
    }

    private static func youtube(_ id: String, _ start: Int) -> VideoEmbed? {
        guard test(youtubeId, id) else { return nil }
        return VideoEmbed(provider: .youtube, src: "https://www.youtube-nocookie.com/embed/\(id)\(start > 0 ? "?start=\(start)" : "")",
                          watchUrl: "https://www.youtube.com/watch?v=\(id)\(start > 0 ? "&t=\(start)s" : "")", title: "YouTube video")
    }

    private static func vimeo(_ id: String, _ hash: String?) -> VideoEmbed? {
        guard test(vimeoId, id), hash.map({ test(vimeoHash, $0) }) ?? true else { return nil }
        let h = hash?.lowercased()
        return VideoEmbed(provider: .vimeo, src: "https://player.vimeo.com/video/\(id)\(h.map { "?h=\($0)" } ?? "")", watchUrl: "https://vimeo.com/\(id)\(h.map { "/\($0)" } ?? "")", title: "Vimeo video")
    }

    /// Turns a pasted video page or player URL from YouTube, Vimeo, Loom or Wistia into its canonical
    /// embed. Returns nil for anything else, including lookalike hosts.
    public static func toEmbedUrl(_ input: String) -> VideoEmbed? {
        guard let u = parseUrl(input), let rawHost = u.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        let parts = u.percentEncodedPath.split(separator: "/").map(String.init)
        func param(_ name: String) -> String? { u.queryItems?.first { $0.name == name }.map { $0.value ?? "" } }
        switch host {
        case "youtube.com", "m.youtube.com", "youtube-nocookie.com":
            let start = parseStart(param("start") ?? param("t"))
            if parts == ["watch"] { return youtube(param("v") ?? "", start) }
            if ["embed", "shorts", "live"].contains(parts.first ?? ""), parts.count == 2 { return youtube(parts[1], start) }
            return nil
        case "youtu.be":
            return parts.count == 1 ? youtube(parts[0], parseStart(param("t") ?? param("start"))) : nil
        case "vimeo.com":
            if parts.count == 1 { return vimeo(parts[0], nil) }
            if parts.count == 2, test(vimeoId, parts[0]) { return vimeo(parts[0], parts[1]) }
            return nil
        case "player.vimeo.com":
            return parts.first == "video" && parts.count == 2 ? vimeo(parts[1], param("h")) : nil
        case "loom.com":
            guard parts.first == "share" || parts.first == "embed", parts.count == 2, test(loomId, parts[1]) else { return nil }
            let id = parts[1].lowercased()
            return VideoEmbed(provider: .loom, src: "https://www.loom.com/embed/\(id)", watchUrl: "https://www.loom.com/share/\(id)", title: "Loom video")
        default:
            var id: String?
            if host == "fast.wistia.net" || host == "fast.wistia.com" {
                id = parts.count == 3 && parts[0] == "embed" && parts[1] == "iframe" ? parts[2] : nil
            } else if host == "wi.st" || host == "wistia.com" || test(wistiaHost, host) {
                id = parts.count == 2 && parts[0] == "medias" ? parts[1] : nil
            }
            guard let id, test(wistiaId, id) else { return nil }
            let src = "https://fast.wistia.net/embed/iframe/\(id)"
            return VideoEmbed(provider: .wistia, src: src, watchUrl: src, title: "Wistia video")
        }
    }

    /// True only for a canonical embed URL (exactly what `toEmbedUrl` returns).
    public static func isAllowedEmbedSrc(_ src: String?) -> Bool {
        guard let src, !src.isEmpty else { return false }
        return toEmbedUrl(src)?.src == src
    }

    /// Plain absolute http(s) URL: no `data:`, `blob:`, relative or credentialed URLs.
    public static func isSafeMediaUrl(_ url: String?) -> Bool {
        guard let url, let u = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let sc = u.scheme?.lowercased(), sc == "https" || sc == "http", let host = u.host, !host.isEmpty else { return false }
        return u.user == nil && u.password == nil
    }

    /// Class marking a link as an attached file (an uploaded PDF), drawn as a file card.
    public static let fileLinkClass = "gd-file"

    /// True for an `<a>` with the file class and an absolute http(s) `href`: render it as a file card.
    public static func isFileLink(className: String?, href: String?) -> Bool {
        guard let className, className.split(whereSeparator: { $0.isWhitespace }).contains(where: { $0 == fileLinkClass }) else { return false }
        return isSafeMediaUrl(href)
    }
}
