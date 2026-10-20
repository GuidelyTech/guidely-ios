#if canImport(UIKit)
import SwiftUI
import UIKit
#if canImport(GuidelyCore)
import GuidelyCore
#endif

// Scout messenger UI: chat-bubble launcher with unread badge and a full-height sheet with Home,
// Messages and Help tabs plus the conversation thread. State lives in `MessengerController`.

struct MessengerLayer: View {
    @ObservedObject var item: MessengerItem
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var m: MessengerController { item.controller }

    var body: some View {
        let theme = item.presentation.theme.resolve(systemDark: scheme == .dark, reduceMotion: reduceMotion)
        let palette = GuidelyPalette(theme: theme)
        let left = m.config.launcherPosition == .bottomLeft
        let size: CGFloat = 56
        let checklistHeight = model.checklistLauncherHeights[m.config.launcherPosition] ?? 0
        let launcherY = model.contentBottom - 16 - size - (checklistHeight > 0 ? checklistHeight + 12 : 0)
        let launcherX = left ? model.safeArea.left + 16 : model.size.width - model.safeArea.right - 16 - size
        let width = min(model.size.width, 640)
        let top = model.safeArea.top + 8
        let height = model.size.height - top + 24
        ZStack(alignment: .topLeading) {
            if item.showLauncher && !m.isOpen {
                MessengerLauncher(name: m.config.name, unread: m.unreadCount, palette: palette, size: size) { m.open() }
                    .guidelyInteractive("messenger-launcher")
                    .offset(x: launcherX, y: launcherY)
                    .transition(.opacity)
            }
            if m.isOpen {
                Backdrop(size: model.size, color: palette.overlay, onTap: { m.close() })
                    .transition(.opacity)
                MessengerSheet(item: item, model: model, palette: palette)
                    .padding(.bottom, 24)
                    .frame(width: width, height: height)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(palette.background)
                            .shadow(color: Color.black.opacity(0.25), radius: 20, x: 0, y: -4)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    .guidelyInteractive("messenger-sheet")
                    .offset(x: (model.size.width - width) / 2, y: top)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
            }
        }
        .environment(\.colorScheme, palette.colorScheme)
        .animation(model.animation, value: m.isOpen)
    }
}

struct MessengerLauncher: View {
    let name: String
    let unread: Int
    let palette: GuidelyPalette
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(palette.primary)
                    .frame(width: size, height: size)
                    .overlay(Image(systemName: "bubble.left.fill").font(.system(size: 24, weight: .semibold)).foregroundColor(palette.onPrimary))
                    .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 4)
                if unread > 0 {
                    Text(unread > 9 ? "9+" : "\(unread)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 22)
                        .background(Capsule().fill(Color(red: 0.86, green: 0.15, blue: 0.15)))
                        .overlay(Capsule().stroke(Color.white, lineWidth: 2))
                        .offset(x: 4, y: -4)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(unread > 0 ? "Open \(name), \(unread) unread" : "Open \(name)"))
    }
}

struct MessengerSheet: View {
    @ObservedObject var item: MessengerItem
    @ObservedObject var model: OverlayModel
    let palette: GuidelyPalette

    private var m: MessengerController { item.controller }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(palette.border).frame(width: 36, height: 5).padding(.top, 8).accessibilityHidden(true)
            header
            Divider().opacity(0.5)
            Group {
                switch m.view {
                case .tab(.home): MessengerHome(item: item, palette: palette)
                case .tab(.messages): MessengerConversations(item: item, palette: palette)
                case .tab(.help): MessengerHelp(item: item, palette: palette, navigate: model.navigate)
                case .thread: MessengerThread(item: item, model: model, palette: palette)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if case .tab(let tab) = m.view {
                Divider().opacity(0.5)
                MessengerTabBar(selected: tab, palette: palette) { m.go(.tab($0)) }
                    .padding(.bottom, model.safeArea.bottom)
            }
        }
    }

    private var title: String {
        switch m.view {
        case .tab(.home): return m.config.name
        case .tab(.messages): return "Messages"
        case .tab(.help): return m.helpArticle != nil || m.helpArticleLoading ? "" : "Help"
        case .thread: return m.current.map { $0.subject.isEmpty ? "Conversation" : $0.subject } ?? "New conversation"
        }
    }

    @ViewBuilder private var backButton: some View {
        let isThread: Bool = { if case .thread = m.view { return true }; return false }()
        let inArticle = m.view == .tab(.help) && (m.helpArticle != nil || m.helpArticleLoading)
        if isThread || inArticle {
            Button {
                if inArticle { m.closeArticle() } else { m.go(.tab(.messages)) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(palette.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Back"))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            backButton
            Text(title)
                .font(GuidelyFonts.font(.headline, theme: palette.theme, weight: .bold))
                .foregroundColor(palette.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            GuidelyCloseButton(palette: palette, label: "Close \(m.config.name)") { m.close() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

struct MessengerTabBar: View {
    let selected: MessengerTab
    let palette: GuidelyPalette
    let onSelect: (MessengerTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MessengerTab.allCases, id: \.self) { tab in
                let on = tab == selected
                Button { onSelect(tab) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: icon(tab)).font(.system(size: 18, weight: .semibold)).frame(height: 24)
                        Text(label(tab)).font(GuidelyFonts.font(.caption2, theme: palette.theme, weight: .medium))
                    }
                    .foregroundColor(on ? palette.primary : palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(label(tab)))
                .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            }
        }
    }

    private func icon(_ t: MessengerTab) -> String {
        switch t {
        case .home: return "house.fill"
        case .messages: return "bubble.left.and.bubble.right.fill"
        case .help: return "questionmark.circle.fill"
        }
    }

    private func label(_ t: MessengerTab) -> String {
        switch t {
        case .home: return "Home"
        case .messages: return "Messages"
        case .help: return "Help"
        }
    }
}

// MARK: - Home & Messages

struct MessengerCard<Content: View>: View {
    let palette: GuidelyPalette
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.subtle))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ConversationRow: View {
    let conversation: MessengerConversation
    let palette: GuidelyPalette
    let action: () -> Void

    var body: some View {
        let unread = conversation.unread > 0
        MessengerCard(palette: palette, action: action) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(unread ? palette.primary : Color.clear).frame(width: 8, height: 8).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.subject.isEmpty ? "Conversation" : conversation.subject)
                        .font(GuidelyFonts.font(.subheadline, theme: palette.theme, weight: unread ? .bold : .semibold))
                        .foregroundColor(palette.text)
                        .lineLimit(1)
                    Text(conversation.lastMessagePreview)
                        .font(GuidelyFonts.font(.caption, theme: palette.theme))
                        .foregroundColor(palette.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(messengerRelativeTime(conversation.lastMessageAt))
                    .font(GuidelyFonts.font(.caption2, theme: palette.theme))
                    .foregroundColor(palette.muted)
            }
        }
        .accessibilityLabel(Text("\(conversation.subject.isEmpty ? "Conversation" : conversation.subject)\(unread ? ", unread" : ""). \(conversation.lastMessagePreview)"))
    }
}

struct MessengerHome: View {
    @ObservedObject var item: MessengerItem
    let palette: GuidelyPalette
    private var m: MessengerController { item.controller }

    var body: some View {
        let theme = palette.theme
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hi there 👋")
                        .font(GuidelyFonts.font(.title2, theme: theme, weight: .bold))
                        .foregroundColor(palette.text)
                    Text(m.config.greeting)
                        .font(GuidelyFonts.font(.body, theme: theme))
                        .foregroundColor(palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                MessengerCard(palette: palette, action: { m.go(.thread(nil)) }) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Send us a message")
                                .font(GuidelyFonts.font(.subheadline, theme: theme, weight: .semibold))
                                .foregroundColor(palette.text)
                            Text(m.config.aiAvailable ? "\(m.config.name) answers right away, and the team can help too" : "The team will reply here")
                                .font(GuidelyFonts.font(.caption, theme: theme))
                                .foregroundColor(palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "paperplane.fill").foregroundColor(palette.primary)
                    }
                }
                if let recent = m.conversations.first {
                    SectionHeader(title: "Recent conversation", palette: palette)
                    ConversationRow(conversation: recent, palette: palette) { m.go(.thread(recent.id)) }
                }
                SectionHeader(title: "Help", palette: palette)
                Button { m.go(.tab(.help)) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundColor(palette.muted)
                        Text("Search for help").font(GuidelyFonts.font(.subheadline, theme: theme)).foregroundColor(palette.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 10).fill(palette.subtle))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Search for help"))
            }
            .padding(16)
        }
    }
}

struct MessengerConversations: View {
    @ObservedObject var item: MessengerItem
    let palette: GuidelyPalette
    private var m: MessengerController { item.controller }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    if m.conversations.isEmpty { EmptyRow(text: "No conversations yet.", palette: palette) }
                    ForEach(m.conversations) { c in
                        ConversationRow(conversation: c, palette: palette) { m.go(.thread(c.id)) }
                    }
                }
                .padding(16)
            }
            Button { m.go(.thread(nil)) } label: {
                Label("New conversation", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(GuidelyButtonStyle(variant: .primary, palette: palette))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Help

struct MessengerHelp: View {
    @ObservedObject var item: MessengerItem
    let palette: GuidelyPalette
    let navigate: (URL) -> Void
    @State private var expanded: Set<String> = []
    private var m: MessengerController { item.controller }

    var body: some View {
        let theme = palette.theme
        VStack(spacing: 0) {
            if m.helpArticle == nil && !m.helpArticleLoading {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(palette.muted)
                    TextField("Search help articles…", text: Binding(get: { m.helpQuery }, set: { m.searchHelp($0) }))
                        .font(GuidelyFonts.font(.subheadline, theme: theme))
                        .foregroundColor(palette.text)
                        .disableAutocorrection(true)
                        .accessibilityLabel(Text("Search help articles"))
                    if !m.helpQuery.isEmpty {
                        Button { m.searchHelp("") } label: { Image(systemName: "xmark.circle.fill").foregroundColor(palette.muted) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear search"))
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.subtle))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let a = m.helpArticle {
                        ArticleView(article: a, palette: palette, navigate: navigate)
                    } else if m.helpArticleLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    } else if !m.helpQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        SectionHeader(title: "Results (\(m.helpResults.count))", palette: palette)
                        if m.helpResults.isEmpty { EmptyRow(text: "No articles match your search.", palette: palette) }
                        ForEach(m.helpResults) { a in RCRow(icon: "doc.text", title: a.title, summary: a.summary, palette: palette) { m.openArticle(a.id) } }
                    } else {
                        home
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder private var home: some View {
        let sections = m.articleSections
        if !m.recommended.isEmpty {
            SectionHeader(title: "Recommended", palette: palette)
            ForEach(m.recommended) { g in RCRow(icon: "play.circle", title: g.name, summary: "Start guide", palette: palette) { m.startGuide(g.key) } }
        }
        if !m.checklists.isEmpty {
            SectionHeader(title: "Checklists", palette: palette)
            ForEach(m.checklists) { g in RCRow(icon: "checklist", title: g.name, summary: "Open checklist", palette: palette) { m.openChecklist(g.id) } }
        }
        ForEach(sections) { section in
            SectionHeader(title: section.title, palette: palette)
            ForEach(section.articles) { a in RCRow(icon: "doc.text", title: a.title, summary: a.summary, palette: palette) { m.openArticle(a.id) } }
        }
        if !m.faqs.isEmpty {
            SectionHeader(title: "FAQ", palette: palette)
            ForEach(m.faqs) { f in
                let open = expanded.contains(f.id)
                RCRow(icon: open ? "chevron.down" : "chevron.right", title: f.question, summary: nil, palette: palette) {
                    if open { expanded.remove(f.id) } else { expanded.insert(f.id) }
                }
                .accessibilityValue(Text(open ? "Expanded" : "Collapsed"))
                if open {
                    GuidelyRichText(html: f.answer, theme: palette.theme, onLink: navigate)
                        .padding(.leading, 40)
                        .padding(.bottom, 8)
                }
            }
        }
        if !m.links.isEmpty {
            SectionHeader(title: "Links", palette: palette)
            ForEach(m.links) { l in RCRow(icon: "arrow.up.right.square", title: l.label, summary: nil, palette: palette) { m.onOpenURL(l.url) } }
        }
        if sections.isEmpty && m.recommended.isEmpty && m.checklists.isEmpty && m.faqs.isEmpty && m.links.isEmpty {
            EmptyRow(text: "Nothing here yet.", palette: palette)
        }
    }
}

// MARK: - Thread

struct MessengerThread: View {
    @ObservedObject var item: MessengerItem
    @ObservedObject var model: OverlayModel
    let palette: GuidelyPalette
    @FocusState private var composerFocused: Bool
    private var m: MessengerController { item.controller }

    private var intro: MessengerMessage {
        MessengerMessage(id: "intro", author: m.config.aiAvailable ? .scout : .agent, authorName: "Support team", body: m.config.greeting, createdAt: "")
    }

    var body: some View {
        let shown = m.messages.isEmpty ? [intro] : m.messages
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(shown) { msg in
                            MessageRow(message: msg, live: m.streaming[msg.id], name: m.config.name, palette: palette, navigate: model.navigate,
                                       onGuide: { m.startGuide($0) }, onArticle: { m.openArticle($0) })
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: scrollKey) { _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: model.keyboardHeight) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider().opacity(0.5)
            footer
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, max(8, model.keyboardHeight > 0 ? model.keyboardHeight + 8 : model.safeArea.bottom))
        }
    }

    /// Changes when the log grows or a streamed reply gets longer.
    private var scrollKey: String {
        "\(m.messages.count)|\(m.messages.last?.id ?? "")|\(m.messages.last?.status.rawValue ?? "")|\(m.streaming.values.map(\.count).reduce(0, +))"
    }

    @ViewBuilder private var footer: some View {
        let theme = palette.theme
        VStack(spacing: 8) {
            if m.needsRating {
                HStack(spacing: 12) {
                    Text("How was this conversation?")
                        .font(GuidelyFonts.font(.subheadline, theme: theme, weight: .medium))
                        .foregroundColor(palette.text)
                    Spacer(minLength: 0)
                    ForEach([(1, "😞", "Bad"), (3, "😐", "OK"), (5, "😀", "Great")], id: \.0) { score, face, label in
                        Button { m.rate(score) } label: { Text(face).font(.system(size: 26)) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(label))
                    }
                }
            } else if m.rated {
                Text("Thanks for the feedback!")
                    .font(GuidelyFonts.font(.footnote, theme: theme))
                    .foregroundColor(palette.muted)
            }
            if m.canHandoff {
                Button("Talk to a person") { m.handoff() }
                    .buttonStyle(GuidelyButtonStyle(variant: .secondary, palette: palette))
                    .disabled(m.handoffInFlight)
            }
            HStack(alignment: .bottom, spacing: 8) {
                composer
                    .font(GuidelyFonts.font(.body, theme: theme))
                    .foregroundColor(palette.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(palette.subtle))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(palette.border, lineWidth: 1))
                    .focused($composerFocused)
                    .disabled(m.sending)
                    .accessibilityLabel(Text("Message"))
                Button { m.send() } label: {
                    Image(systemName: m.sending ? "ellipsis" : "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(palette.onPrimary)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(palette.primary.opacity(m.canSend ? 1 : 0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!m.canSend)
                .accessibilityLabel(Text("Send"))
            }
        }
    }

    @ViewBuilder private var composer: some View {
        let placeholder = m.current?.status == .open ? "Reply to the team…" : "Ask a question…"
        let binding = Binding(get: { m.draft }, set: { m.draft = $0 })
        if #available(iOS 16.0, *) {
            TextField(placeholder, text: binding, axis: .vertical)
                .lineLimit(1...5)
                .onSubmit { m.send() }
        } else {
            TextField(placeholder, text: binding)
                .onSubmit { m.send() }
        }
    }
}

struct MessageRow: View {
    let message: MessengerMessage
    let live: String?
    let name: String
    let palette: GuidelyPalette
    let navigate: (URL) -> Void
    let onGuide: (String) -> Void
    let onArticle: (String) -> Void

    var body: some View {
        let theme = palette.theme
        switch message.author {
        case .system:
            Text(message.body)
                .font(GuidelyFonts.font(.footnote, theme: theme))
                .foregroundColor(palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
        case .user:
            HStack {
                Spacer(minLength: 48)
                chat(message.body, color: palette.onPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(BubbleShape(mine: true).fill(palette.primary))
            }
        case .scout, .agent:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(message.author == .scout ? name : (message.authorName ?? "Support team"))
                        .font(GuidelyFonts.font(.caption, theme: theme, weight: .semibold))
                        .foregroundColor(palette.muted)
                    if message.author == .scout {
                        Text("AI")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(palette.primary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.primary.opacity(0.12)))
                    }
                }
                HStack {
                    bubbleContent
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(BubbleShape(mine: false).fill(palette.subtle.opacity(1.6)))
                        .overlay(BubbleShape(mine: false).stroke(palette.border, lineWidth: 1))
                    Spacer(minLength: 48)
                }
                if !message.suggestedGuides.isEmpty || !message.citations.isEmpty {
                    FlowChips(guides: message.suggestedGuides, citations: message.citations, palette: palette, onGuide: onGuide, onArticle: onArticle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var bubbleContent: some View {
        if message.status == .pending && (live ?? "").isEmpty {
            TypingIndicator(color: palette.muted)
                .accessibilityLabel(Text("\(name) is typing"))
        } else if message.status == .failed {
            Text("This reply couldn't be completed.")
                .font(GuidelyFonts.font(.subheadline, theme: palette.theme))
                .foregroundColor(palette.muted)
        } else {
            chat(live ?? message.body, color: palette.text)
        }
    }

    private func chat(_ text: String, color: Color) -> some View {
        Text(RichTextRenderer.attributed(ChatText.parse(text), theme: palette.theme, base: .body, color: color, linkColor: color))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                navigate(url)
                return .handled
            })
    }
}

/// Wrapping row of "Show me" and citation chips.
struct FlowChips: View {
    let guides: [MessengerSuggestedGuide]
    let citations: [MessengerCitation]
    let palette: GuidelyPalette
    let onGuide: (String) -> Void
    let onArticle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(guides, id: \.key) { g in
                chip(icon: "play.fill", text: "Show me: \(g.name)", strong: true) { onGuide(g.key) }
            }
            ForEach(citations, id: \.articleId) { c in
                chip(icon: "doc.text", text: c.title, strong: false) { onArticle(c.articleId) }
            }
        }
    }

    private func chip(icon: String, text: String, strong: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(text).font(GuidelyFonts.font(.footnote, theme: palette.theme, weight: .semibold)).lineLimit(1)
            }
            .foregroundColor(strong ? palette.onPrimary : palette.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(strong ? palette.primary : palette.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct BubbleShape: Shape {
    let mine: Bool
    func path(in r: CGRect) -> Path {
        let radius: CGFloat = 16
        let small: CGFloat = 4
        var p = Path()
        let tl = mine ? radius : small, tr = radius, bl = radius, br = mine ? small : radius
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

struct TypingIndicator: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let step = reduceMotion ? -1 : Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(color).frame(width: 7, height: 7).opacity(step == i ? 1 : 0.35)
                }
            }
            .frame(height: 20)
        }
    }
}
#endif
