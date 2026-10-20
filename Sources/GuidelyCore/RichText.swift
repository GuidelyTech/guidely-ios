import Foundation

/// Styled run of text produced by `HTMLParser`.
public struct RichRun: Sendable, Hashable {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false
    public var code = false
    /// 1–3 for `h1`–`h3` (h4+ render as h3), 0 otherwise.
    public var heading = 0
    public var link: String?

    public init(text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, code: Bool = false, heading: Int = 0, link: String? = nil) {
        self.text = text; self.bold = bold; self.italic = italic; self.underline = underline; self.code = code; self.heading = heading; self.link = link
    }

    func sameStyle(_ o: RichRun) -> Bool {
        bold == o.bold && italic == o.italic && underline == o.underline && code == o.code && heading == o.heading && link == o.link
    }
}

/// Native rich text: a flat list of runs with `\n` separating blocks.
public struct RichText: Sendable, Hashable {
    public var runs: [RichRun]
    public init(runs: [RichRun]) { self.runs = runs }
    public var plainText: String { runs.map(\.text).joined() }
    public var isEmpty: Bool { plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Links in document order.
    public var links: [String] { runs.compactMap(\.link) }
}

/// Pre-rendered page image of an inline PDF, with its alt text and intrinsic size, when present.
public struct ArticlePdfPage: Sendable, Hashable {
    public var url: String
    public var alt: String
    public var width: Double?
    public var height: Double?

    public init(url: String, alt: String, width: Double? = nil, height: Double? = nil) {
        self.url = url; self.alt = alt; self.width = width; self.height = height
    }
}

/// One block of an article body (`HTMLParser.blocks`), in document order.
public enum ArticleBlock: Sendable, Hashable {
    case text(RichText)
    /// http(s) image with its alt text and intrinsic size (`width`/`height` attributes), when present.
    case image(url: String, alt: String, width: Double?, height: Double?)
    /// A video shown as a link (no inline players): the provider's watch page or the video file.
    case video(url: String, label: String)
    /// An attached file (an uploaded PDF), shown as a card that opens it; `name` is the link text.
    /// Bodies use this for a bare `a.gd-file`, e.g. a PDF whose pages couldn't be rendered.
    case file(url: String, name: String)
    /// A PDF read inline (`div.gd-pdf`): its pre-rendered page images, with the file to open in full.
    case pdf(url: String, name: String, pages: [ArticlePdfPage])

    /// Text for accessibility and previews: the text, the image's alt, the video's label or the file's name.
    public var plainText: String {
        switch self {
        case .text(let t): return t.plainText
        case .image(_, let alt, _, _): return alt
        case .video(_, let label): return label
        case .file(_, let name), .pdf(_, let name, _): return name
        }
    }
}

/// Small, tolerant HTML → `RichText` converter for sanitized guide content. Supports `p`, `br`,
/// `strong`/`b`, `em`/`i`, `u`, `a`, `ul`/`ol`/`li`, `h1`–`h6`, `code`/`pre`, `blockquote`, `div`;
/// everything else is reduced to its text. `script`/`style`-like elements are dropped entirely.
/// Unsafe link schemes (`javascript:`, `data:` …) are removed. `blocks` additionally splits article
/// bodies around media: http(s) `img`s, `video`s, canonical video embed `iframe`s, inline PDFs
/// (`div.gd-pdf`) and file links (`a.gd-file`).
public enum HTMLParser {
    private static let dropTags: Set<String> = ["script", "style", "iframe", "object", "embed", "template", "svg", "math", "noscript", "head", "title", "select", "textarea"]
    private static let voidTags: Set<String> = ["br", "img", "hr", "input", "meta", "link", "source", "wbr", "area", "base", "col", "embed", "param", "track"]
    private static let paragraphTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "blockquote", "pre", "table", "section", "article", "header", "footer", "figure"]
    private static let lineTags: Set<String> = ["div", "li", "tr", "dt", "dd", "hr"]

    static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–",
        "hellip": "…", "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓", "copy": "©", "reg": "®", "trade": "™",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·", "times": "×", "divide": "÷",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "plusmn": "±", "frac12": "½", "laquo": "«", "raquo": "»",
        "check": "✓", "hearts": "♥", "star": "☆", "shy": "\u{00AD}", "zwj": "\u{200D}", "zwnj": "\u{200C}", "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}",
    ]

    /// Decodes `&amp;`, `&lt;`, `&#39;`, `&#x1F44B;` … Unknown entities are left untouched.
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    if let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
                } else if name.hasPrefix("#") {
                    if let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
                } else if let e = entities[name] ?? entities[name.lowercased()] {
                    replacement = e
                }
                if let replacement {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    /// Is `href` safe to open (http(s), mailto, tel, relative paths and custom app schemes)?
    public static func isSafeLink(_ href: String) -> Bool {
        let v = href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().filter { !$0.isWhitespace && ($0.asciiValue.map { $0 >= 0x20 } ?? true) }
        if v.isEmpty { return false }
        guard let colon = v.firstIndex(of: ":") else { return true }
        let scheme = String(v[..<colon])
        guard let first = scheme.first, first.isLetter, scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return true }
        return !["javascript", "vbscript", "data", "file", "blob", "about"].contains(scheme)
    }

    private struct Tag {
        var name: String
        var closing: Bool
        var selfClosing: Bool
        var attrs: [String: String]
    }

    private struct ListState { var ordered: Bool; var counter: Int }
    private struct PdfState { var depth = 1; var url: String?; var name = ""; var pages: [ArticlePdfPage] = [] }

    public static func parse(_ html: String?) -> RichText {
        if case .text(let t)? = convert(html, media: false).first { return t }
        return RichText(runs: [])
    }

    /// Article body → text, image, video, PDF and file blocks in order. Images need an http(s) `src` (otherwise
    /// their alt text stays inline); videos need an http(s) `src` and iframes a canonical embed `src`
    /// (`GuidelyMedia.isAllowedEmbedSrc`), anything else is dropped. File links need the `gd-file` class
    /// and an http(s) `href` (`GuidelyMedia.isFileLink`), otherwise they stay ordinary links. A
    /// `div.gd-pdf` (its file link plus the http(s) page `img`s inside) becomes one `.pdf` block, or a
    /// `.file` without pages; other content inside it is ignored.
    public static func blocks(_ html: String?) -> [ArticleBlock] {
        convert(html, media: true)
    }

    /// Plain text of an article body, with image alt texts, video labels and file names.
    public static func articlePlainText(_ html: String?) -> String {
        blocks(html).map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func convert(_ html: String?, media: Bool) -> [ArticleBlock] {
        let html = html ?? ""
        var blocks: [ArticleBlock] = []
        var runs: [RichRun] = []
        var bold = 0, italic = 0, underline = 0, code = 0, pre = 0
        var headings: [Int] = []
        var links: [String?] = []
        var lists: [ListState] = []
        var pendingBreak = 0 // newlines to emit before the next text (max of requested)
        var atLineStart = true
        var hasContent = false
        var needsBullet = false
        var orphanList = false
        var pdf: PdfState? // inside a `div.gd-pdf` (media mode)

        func style() -> RichRun {
            RichRun(text: "", bold: bold > 0 || !headings.isEmpty, italic: italic > 0, underline: underline > 0, code: code > 0 || pre > 0, heading: headings.last ?? 0, link: links.last.flatMap { $0 })
        }

        func append(_ text: String, _ st: RichRun) {
            guard !text.isEmpty else { return }
            if var last = runs.last, last.sameStyle(st) {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                var r = st
                r.text = text
                runs.append(r)
            }
        }

        func requestBreak(_ n: Int) {
            if hasContent { pendingBreak = max(pendingBreak, n) }
        }

        func emitText(_ raw: String) {
            if pdf != nil { return }
            var text = raw
            if pre == 0 {
                // Collapse whitespace like HTML.
                var collapsed = ""
                var lastSpace = false
                for ch in text {
                    if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" || ch == "\u{0C}" {
                        if !lastSpace { collapsed.append(" ") }
                        lastSpace = true
                    } else {
                        collapsed.append(ch)
                        lastSpace = false
                    }
                }
                text = collapsed
                if atLineStart || pendingBreak > 0 { text = String(text.drop(while: { $0 == " " })) }
                if text.isEmpty { return }
            }
            if pendingBreak > 0 {
                // Breaks are plain (unstyled) newlines.
                append(String(repeating: "\n", count: pendingBreak), RichRun(text: ""))
                pendingBreak = 0
                atLineStart = true
            }
            if atLineStart, let list = lists.last, needsBullet {
                let indent = String(repeating: "    ", count: max(0, lists.count - 1))
                let bullet = list.ordered ? "\(list.counter). " : "• "
                append(indent + bullet, RichRun(text: ""))
                needsBullet = false
            }
            append(decodeEntities(text), style())
            hasContent = true
            atLineStart = text.hasSuffix("\n")
        }

        func finishText() {
            // Trim trailing whitespace/newlines.
            while let last = runs.last {
                let trimmed = String(last.text.reversed().drop(while: { $0 == "\n" || $0 == " " }).reversed())
                if trimmed.isEmpty { runs.removeLast(); continue }
                runs[runs.count - 1].text = trimmed
                break
            }
            let text = RichText(runs: runs)
            if !media || !text.isEmpty { blocks.append(.text(text)) }
            runs = []
            pendingBreak = 0
            hasContent = false
            atLineStart = true
        }

        func cut(_ block: ArticleBlock) {
            finishText()
            blocks.append(block)
        }

        func lineBreak() {
            if pendingBreak > 0 {
                append(String(repeating: "\n", count: pendingBreak), RichRun(text: ""))
                pendingBreak = 0
            }
            append("\n", RichRun(text: ""))
            hasContent = true
            atLineStart = true
        }

        func handle(_ tag: Tag) {
            let n = tag.name
            if !tag.closing {
                if paragraphTags.contains(n) { requestBreak(2) } else if lineTags.contains(n) { requestBreak(1) }
                switch n {
                case "br": lineBreak()
                case "strong", "b": bold += 1
                case "em", "i", "cite": italic += 1
                case "u", "ins": underline += 1
                case "code", "kbd", "samp": code += 1
                case "pre": pre += 1
                case "h1": headings.append(1)
                case "h2": headings.append(2)
                case "h3", "h4", "h5", "h6": headings.append(3)
                case "a":
                    let href = tag.attrs["href"].map(decodeEntities)
                    links.append(href.flatMap { isSafeLink($0) ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : nil })
                case "ul": lists.append(ListState(ordered: false, counter: 0))
                case "ol": lists.append(ListState(ordered: true, counter: Int(tag.attrs["start"] ?? "") .map { $0 - 1 } ?? 0))
                case "li":
                    if !lists.isEmpty { lists[lists.count - 1].counter += 1 } else { lists.append(ListState(ordered: false, counter: 1)); orphanList = true }
                    needsBullet = true
                    if !hasContent { atLineStart = true }
                case "img":
                    let src = tag.attrs["src"].map(decodeEntities)
                    if media, let src, GuidelyMedia.isSafeMediaUrl(src) {
                        let (w, h) = size(tag.attrs)
                        cut(.image(url: src.trimmingCharacters(in: .whitespacesAndNewlines), alt: decodeEntities(tag.attrs["alt"] ?? ""), width: w, height: h))
                    } else if let alt = tag.attrs["alt"], !alt.isEmpty { emitText(alt) }
                default: break
                }
                if tag.selfClosing && !voidTags.contains(n) { handle(Tag(name: n, closing: true, selfClosing: false, attrs: [:])) }
            } else {
                switch n {
                case "strong", "b": bold = max(0, bold - 1)
                case "em", "i", "cite": italic = max(0, italic - 1)
                case "u", "ins": underline = max(0, underline - 1)
                case "code", "kbd", "samp": code = max(0, code - 1)
                case "pre": pre = max(0, pre - 1)
                case "h1", "h2", "h3", "h4", "h5", "h6": if !headings.isEmpty { headings.removeLast() }
                case "a": if !links.isEmpty { links.removeLast() }
                case "ul", "ol": if !lists.isEmpty { lists.removeLast() }
                case "li":
                    needsBullet = false
                    if orphanList { lists.removeAll(); orphanList = false }
                default: break
                }
                if paragraphTags.contains(n) { requestBreak(2) } else if lineTags.contains(n) { requestBreak(1) }
            }
        }

        func size(_ attrs: [String: String]) -> (Double?, Double?) {
            let w = Double(attrs["width"] ?? "") ?? 0, h = Double(attrs["height"] ?? "") ?? 0
            return w > 0 && h > 0 ? (w, h) : (nil, nil)
        }

        func hasClass(_ cls: String?, _ name: String) -> Bool {
            cls.map(decodeEntities)?.split(whereSeparator: { $0.isWhitespace }).contains { $0 == name } ?? false
        }

        /// Emits the closed `div.gd-pdf`: a `.pdf` with pages, a `.file` without; pages with no file link
        /// stay plain images.
        func finishPdf() {
            guard let p = pdf else { return }
            pdf = nil
            if let url = p.url {
                cut(p.pages.isEmpty ? .file(url: url, name: p.name.isEmpty ? "Open PDF" : p.name) : .pdf(url: url, name: p.name.isEmpty ? "PDF" : p.name, pages: p.pages))
            } else {
                for page in p.pages { cut(.image(url: page.url, alt: page.alt, width: page.width, height: page.height)) }
            }
        }

        // Tokenizer
        let chars = Array(html.unicodeScalars)
        var i = 0
        var textStart = 0
        func flushText(_ end: Int) {
            if end > textStart {
                var s = String.UnicodeScalarView()
                s.append(contentsOf: chars[textStart..<end])
                emitText(String(s))
            }
        }
        func isNameChar(_ c: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_" || c == ":" }
        func lower(_ s: [Unicode.Scalar]) -> String { var v = String.UnicodeScalarView(); v.append(contentsOf: s); return String(v).lowercased() }
        /// Moves past the close tag of the dropped element `name` that starts at `i`.
        func skip(_ name: String) {
            let closeTag = Array("</\(name)".unicodeScalars)
            let closeText = "</\(name)"
            var k = i
            while k + closeTag.count <= chars.count {
                if lower(Array(chars[k..<(k + closeTag.count)])) == closeText {
                    var e = k + closeTag.count
                    while e < chars.count, chars[e] != ">" { e += 1 }
                    i = min(chars.count, e + 1)
                    return
                }
                k += 1
            }
            i = chars.count
        }
        /// Text of the link that opens at `i` (nested inline tags reduced to text, whitespace collapsed),
        /// moving past its `</a>`.
        func linkText() -> String {
            var k = i
            var end = chars.count
            while k + 3 <= chars.count {
                if chars[k] == "<", chars[k + 1] == "/", chars[k + 2] == "a" || chars[k + 2] == "A", k + 3 == chars.count || !isNameChar(chars[k + 3]) {
                    end = k
                    break
                }
                k += 1
            }
            var inner = String.UnicodeScalarView(); inner.append(contentsOf: chars[i..<end])
            if end < chars.count {
                var e = end + 3
                while e < chars.count, chars[e] != ">" { e += 1 }
                i = min(chars.count, e + 1)
            } else { i = chars.count }
            textStart = i
            return plainText(String(inner)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }

        while i < chars.count {
            guard chars[i] == "<" else { i += 1; continue }
            // Comment
            if i + 3 < chars.count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                flushText(i)
                var j = i + 4
                while j + 2 < chars.count, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                i = min(chars.count, j + 3)
                textStart = i
                continue
            }
            // Doctype / processing instruction
            if i + 1 < chars.count, chars[i + 1] == "!" || chars[i + 1] == "?" {
                flushText(i)
                var j = i + 2
                while j < chars.count, chars[j] != ">" { j += 1 }
                i = min(chars.count, j + 1)
                textStart = i
                continue
            }
            var j = i + 1
            var closing = false
            if j < chars.count, chars[j] == "/" { closing = true; j += 1 }
            guard j < chars.count, CharacterSet.letters.contains(chars[j]) else { i += 1; continue } // literal "<"
            let nameStart = j
            while j < chars.count, isNameChar(chars[j]) { j += 1 }
            let name = lower(Array(chars[nameStart..<j]))
            // Attributes
            var attrs: [String: String] = [:]
            var selfClosing = false
            var closed = false
            while j < chars.count {
                let c = chars[j]
                if c == ">" { closed = true; j += 1; break }
                if c == "/" { selfClosing = true; j += 1; continue }
                if CharacterSet.whitespacesAndNewlines.contains(c) { j += 1; continue }
                selfClosing = false
                let aStart = j
                while j < chars.count, !CharacterSet.whitespacesAndNewlines.contains(chars[j]), chars[j] != "=", chars[j] != ">", chars[j] != "/" { j += 1 }
                let aName = lower(Array(chars[aStart..<j]))
                while j < chars.count, CharacterSet.whitespacesAndNewlines.contains(chars[j]) { j += 1 }
                var value = ""
                if j < chars.count, chars[j] == "=" {
                    j += 1
                    while j < chars.count, CharacterSet.whitespacesAndNewlines.contains(chars[j]) { j += 1 }
                    if j < chars.count, chars[j] == "\"" || chars[j] == "'" {
                        let q = chars[j]
                        j += 1
                        let vStart = j
                        while j < chars.count, chars[j] != q { j += 1 }
                        var v = String.UnicodeScalarView(); v.append(contentsOf: chars[vStart..<min(j, chars.count)]); value = String(v)
                        j += 1
                    } else {
                        let vStart = j
                        while j < chars.count, !CharacterSet.whitespacesAndNewlines.contains(chars[j]), chars[j] != ">" { j += 1 }
                        var v = String.UnicodeScalarView(); v.append(contentsOf: chars[vStart..<j]); value = String(v)
                    }
                }
                if !aName.isEmpty { attrs[aName] = value }
            }
            guard closed else { i += 1; continue } // unterminated tag → literal text
            flushText(i)
            i = j
            textStart = i
            if pdf != nil {
                // Inside `div.gd-pdf`: collect the file link and page images; text and other tags are ignored.
                if name == "div" {
                    if closing { pdf!.depth -= 1; if pdf!.depth == 0 { finishPdf() } } else if !selfClosing { pdf!.depth += 1 }
                } else if !closing && name == "a" {
                    let href = attrs["href"].map(decodeEntities)
                    if GuidelyMedia.isFileLink(className: attrs["class"].map(decodeEntities), href: href), pdf!.url == nil, let href {
                        pdf!.url = href.trimmingCharacters(in: .whitespacesAndNewlines)
                        pdf!.name = linkText()
                    }
                } else if !closing && name == "img", let src = attrs["src"].map(decodeEntities), GuidelyMedia.isSafeMediaUrl(src) {
                    let (w, h) = size(attrs)
                    pdf!.pages.append(ArticlePdfPage(url: src.trimmingCharacters(in: .whitespacesAndNewlines), alt: decodeEntities(attrs["alt"] ?? ""), width: w, height: h))
                } else if !closing && !selfClosing && (dropTags.contains(name) || name == "video") {
                    skip(name)
                }
                textStart = i
                continue
            }
            if media && !closing && name == "div" && hasClass(attrs["class"], "gd-pdf") {
                if !selfClosing { pdf = PdfState() }
                continue
            }
            if media && !closing && name == "a", let href = attrs["href"].map(decodeEntities),
               GuidelyMedia.isFileLink(className: attrs["class"].map(decodeEntities), href: href) {
                let label = linkText()
                cut(.file(url: href.trimmingCharacters(in: .whitespacesAndNewlines), name: label.isEmpty ? "Open PDF" : label))
                continue
            }
            if media && !closing && (name == "iframe" || name == "video") {
                let src = attrs["src"].map(decodeEntities)
                if name == "iframe" {
                    if GuidelyMedia.isAllowedEmbedSrc(src), let embed = src.flatMap(GuidelyMedia.toEmbedUrl) { cut(.video(url: embed.watchUrl, label: embed.provider.watchLabel)) }
                } else if let src, GuidelyMedia.isSafeMediaUrl(src) {
                    cut(.video(url: src.trimmingCharacters(in: .whitespacesAndNewlines), label: "Play video"))
                }
            }
            if !closing && (dropTags.contains(name) || (media && name == "video")) {
                if selfClosing { continue }
                skip(name)
                textStart = i
                continue
            }
            handle(Tag(name: name, closing: closing, selfClosing: selfClosing, attrs: attrs))
        }
        flushText(chars.count)
        if pdf != nil { finishPdf() }
        finishText()
        return blocks
    }

    /// Plain text of an HTML snippet (for accessibility labels and announcements).
    public static func plainText(_ html: String?) -> String {
        parse(html).plainText
    }
}

/// Untrusted chat text (Scout replies, user and teammate messages) → `RichText`. Supports
/// paragraphs, line breaks, `- ` / `1. ` lists, **bold**, `code` and http(s) links (markdown or bare);
/// `[[article:ID]]` citation markers are removed and images are reduced to their alt text
/// (`renderSafeText` in guide-runtime).
public enum ChatText {
    private static let citation = try! NSRegularExpression(pattern: #"\s*\[\[article:[^\]]*\]\]"#)
    private static let inline = try! NSRegularExpression(pattern: #"\*\*([^*\n]+)\*\*|`([^`\n]+)`|(!?)\[([^\]\n]{1,200})\]\((https?://[^\s)]+)\)|(https?://[^\s<>()"']+[^\s<>().,;:!?'"])"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^\s*[-*•]\s+"#)
    private static let numbered = try! NSRegularExpression(pattern: #"^\s*\d{1,3}[.)]\s+"#)

    public static func stripCitationMarkers(_ text: String) -> String {
        citation.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func strip(_ re: NSRegularExpression, _ s: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    static func safeHttp(_ raw: String) -> String? {
        guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return raw
    }

    private static func appendInline(_ text: String, into runs: inout [RichRun]) {
        let ns = text as NSString
        var last = 0
        for m in inline.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > last { runs.append(RichRun(text: ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            if let b = group(1) {
                runs.append(RichRun(text: b, bold: true))
            } else if let c = group(2) {
                runs.append(RichRun(text: c, code: true))
            } else if let label = group(4), let href = group(5) {
                let image = group(3) == "!"
                runs.append(RichRun(text: label, link: image ? nil : safeHttp(href)))
            } else if let url = group(6) {
                runs.append(RichRun(text: url, link: safeHttp(url)))
            }
            last = m.range.location + m.range.length
        }
        if last < ns.length { runs.append(RichRun(text: ns.substring(from: last))) }
    }

    public static func parse(_ text: String) -> RichText {
        let normalized = stripCitationMarkers(text).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = normalized.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\n")) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var runs: [RichRun] = []
        for (bi, block) in blocks.enumerated() {
            if bi > 0 { runs.append(RichRun(text: "\n\n")) }
            let lines = block.components(separatedBy: "\n")
            let isBullets = lines.allSatisfy { matches(bullet, $0) }
            let isNumbered = lines.allSatisfy { matches(numbered, $0) }
            for (i, line) in lines.enumerated() {
                if i > 0 { runs.append(RichRun(text: "\n")) }
                if isBullets {
                    runs.append(RichRun(text: "• "))
                    appendInline(strip(bullet, line), into: &runs)
                } else if isNumbered {
                    runs.append(RichRun(text: "\(i + 1). "))
                    appendInline(strip(numbered, line), into: &runs)
                } else {
                    appendInline(line, into: &runs)
                }
            }
        }
        // Merge adjacent plain runs.
        var merged: [RichRun] = []
        for r in runs where !r.text.isEmpty {
            if var lastRun = merged.last, lastRun.sameStyle(r) { lastRun.text += r.text; merged[merged.count - 1] = lastRun } else { merged.append(r) }
        }
        return RichText(runs: merged)
    }
}
