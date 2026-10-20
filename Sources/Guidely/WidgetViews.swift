#if canImport(UIKit)
import SwiftUI
import UIKit
#if canImport(GuidelyCore)
import GuidelyCore
#endif

// MARK: - Checklist

struct ChecklistLayer: View {
    @ObservedObject var item: ChecklistItem
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var launcherSize: CGSize = .zero
    @State private var panelSize: CGSize = .zero

    var body: some View {
        let theme = item.presentation.theme.resolve(systemDark: scheme == .dark, reduceMotion: reduceMotion)
        let palette = GuidelyPalette(theme: theme)
        let left = item.presentation.config.position == .bottomLeft
        let showLauncher = item.presentation.showLauncher
        let launcherY = model.contentBottom - 16 - launcherSize.height
        let launcherX = left ? model.safeArea.left + 16 : model.size.width - model.safeArea.right - 16 - launcherSize.width
        let panelWidth = min(380, model.size.width - 32 - model.safeArea.left - model.safeArea.right)
        let panelBottom = showLauncher ? launcherY - 12 : model.contentBottom - 16
        let panelMaxH = max(160, panelBottom - model.safeArea.top - 16)
        let panelX = left ? model.safeArea.left + 16 : model.size.width - model.safeArea.right - 16 - panelWidth
        ZStack(alignment: .topLeading) {
            if item.isOpen {
                Backdrop(size: model.size, color: Color.black.opacity(theme.isDark ? 0.25 : 0.12), onTap: { item.close() })
                    .transition(.opacity)
                CappedCard(width: panelWidth, maxHeight: panelMaxH, size: $panelSize) {
                    ChecklistPanel(item: item, palette: palette, navigate: model.navigate)
                }
                .guidelyCard(palette)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .guidelyInteractive("checklist-panel-\(item.id)")
                .offset(x: panelX, y: panelBottom - panelSize.height)
                .opacity(panelSize.height > 0 ? 1 : 0)
                .transition(.opacity)
            }
            if showLauncher {
                ChecklistLauncher(item: item, palette: palette)
                    .measureSize {
                        if launcherSize != $0 { launcherSize = $0 }
                        let pos = item.presentation.config.position
                        if model.checklistLauncherHeights[pos] != $0.height { model.checklistLauncherHeights[pos] = $0.height }
                    }
                    .onDisappear { model.checklistLauncherHeights[item.presentation.config.position] = nil }
                    .guidelyInteractive("checklist-launcher-\(item.id)")
                    .offset(x: launcherX, y: launcherY)
                    .opacity(launcherSize.height > 0 ? 1 : 0)
            }
        }
        .environment(\.colorScheme, palette.colorScheme)
    }
}

struct ProgressRing: View {
    let fraction: Double
    let color: Color
    let track: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct ChecklistLauncher: View {
    @ObservedObject var item: ChecklistItem
    let palette: GuidelyPalette

    var body: some View {
        let done = item.doneCount, total = item.total
        Button { item.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    ProgressRing(fraction: total > 0 ? Double(done) / Double(total) : 0, color: palette.onPrimary, track: palette.onPrimary.opacity(0.3))
                    Text("\(done)/\(total)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(palette.onPrimary)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: 30, height: 30)
                Text(item.presentation.config.launcherLabel)
                    .font(GuidelyFonts.font(.subheadline, theme: palette.theme, weight: .semibold))
                    .foregroundColor(palette.onPrimary)
                    .lineLimit(1)
            }
            .padding(.leading, 8)
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(palette.primary))
            .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(item.presentation.config.launcherLabel): \(done) of \(total) tasks completed"))
        .accessibilityHint(Text(item.isOpen ? "Closes the checklist" : "Opens the checklist"))
    }
}

struct ChecklistPanel: View {
    @ObservedObject var item: ChecklistItem
    let palette: GuidelyPalette
    let navigate: (URL) -> Void

    var body: some View {
        let cfg = item.presentation.config
        let done = Set(item.progress.completedTaskIds)
        let locked = ChecklistLogic.lockedTaskIds(cfg, completedTaskIds: item.progress.completedTaskIds)
        let pct = item.total > 0 ? Double(item.doneCount) / Double(item.total) : 0
        let theme = palette.theme
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cfg.launcherLabel)
                        .font(GuidelyFonts.font(.headline, theme: theme, weight: .semibold))
                        .foregroundColor(palette.text)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(item.doneCount) of \(item.total) completed")
                        .font(GuidelyFonts.font(.caption, theme: theme))
                        .foregroundColor(palette.muted)
                }
                Spacer(minLength: 8)
                GuidelyCloseButton(palette: palette, label: "Minimize checklist") { item.close() }
                    .padding(.top, -6)
                    .padding(.trailing, -6)
                    .padding(.bottom, -6)
            }
            ProgressBar(fraction: pct, palette: palette)
                .padding(.top, 10)
                .accessibilityElement()
                .accessibilityLabel(Text("Progress"))
                .accessibilityValue(Text("\(Int((pct * 100).rounded())) percent"))
            if item.isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cfg.completionTitle)
                        .font(GuidelyFonts.font(.subheadline, theme: theme, weight: .semibold))
                        .foregroundColor(palette.text)
                    GuidelyRichText(html: cfg.completionBody, theme: theme, onLink: navigate)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.primary.opacity(0.1)))
                .padding(.top, 12)
            }
            VStack(spacing: 2) {
                ForEach(Array(cfg.tasks.enumerated()), id: \.element.id) { i, task in
                    ChecklistTaskRow(index: i, task: task, done: done.contains(task.id), locked: locked.contains(task.id), palette: palette) {
                        item.presentation.onTaskTap(task)
                    }
                }
            }
            .padding(.top, 10)
            if cfg.dismissible {
                HStack {
                    Spacer()
                    Button(item.isComplete ? "Close" : "Dismiss checklist") { item.presentation.onDismiss() }
                        .buttonStyle(GuidelyButtonStyle(variant: .ghost, palette: palette))
                }
                .padding(.top, 6)
            }
        }
        .padding(16)
    }
}

struct ProgressBar: View {
    let fraction: Double
    let palette: GuidelyPalette
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.subtle)
                Capsule().fill(palette.primary).frame(width: geo.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 6)
    }
}

struct ChecklistTaskRow: View {
    let index: Int
    let task: ChecklistTask
    let done: Bool
    let locked: Bool
    let palette: GuidelyPalette
    let action: () -> Void

    var body: some View {
        let theme = palette.theme
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(done ? palette.primary : palette.border, lineWidth: 2)
                        .background(Circle().fill(done ? palette.primary : Color.clear))
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(palette.onPrimary)
                    }
                }
                .frame(width: 22, height: 22)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(task.title)")
                        .font(GuidelyFonts.font(.subheadline, theme: theme, weight: .medium))
                        .foregroundColor(done ? palette.muted : palette.text)
                        .strikethrough(done, color: palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !task.description.isEmpty {
                        Text(task.description)
                            .font(GuidelyFonts.font(.caption, theme: theme))
                            .foregroundColor(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if task.action != .none && !done {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(palette.muted)
                        .padding(.top, 4)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(done ? Color.clear : palette.subtle.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.5 : 1)
        .accessibilityLabel(Text("\(task.title)\(done ? ", completed" : "")"))
        .accessibilityHint(Text(locked ? "Complete the previous task first" : task.description))
        .accessibilityAddTraits(done ? .isSelected : [])
    }
}

// MARK: - Survey

struct SurveyLayer: View {
    @ObservedObject var item: SurveyItem
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize = .zero

    var body: some View {
        let theme = item.presentation.theme.resolve(systemDark: scheme == .dark, reduceMotion: reduceMotion)
        let palette = GuidelyPalette(theme: theme)
        let pos = item.presentation.config.position
        let width = min(400, model.size.width - 32 - model.safeArea.left - model.safeArea.right)
        let bottom = model.contentBottom - 16
        let maxH = max(160, bottom - model.safeArea.top - 16)
        let x = pos == .bottomLeft ? model.safeArea.left + 16 : (pos == .center ? (model.size.width - width) / 2 : model.size.width - model.safeArea.right - 16 - width)
        let y = pos == .center ? max(model.safeArea.top + 16, (bottom + model.safeArea.top - size.height) / 2) : bottom - size.height
        CappedCard(width: width, maxHeight: maxH, size: $size) {
            SurveyCard(item: item, palette: palette, navigate: model.navigate)
        }
        .guidelyCard(palette)
        .accessibilityElement(children: .contain)
        .guidelyInteractive("survey")
        .offset(x: x, y: y)
        .opacity(size.height > 0 ? 1 : 0)
        .environment(\.colorScheme, palette.colorScheme)
        .transition(.opacity)
        .animation(model.animation, value: model.keyboardHeight)
    }
}

struct SurveyCard: View {
    @ObservedObject var item: SurveyItem
    let palette: GuidelyPalette
    let navigate: (URL) -> Void

    var body: some View {
        let cfg = item.presentation.config
        let theme = palette.theme
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(item.thankYou ? cfg.thankYouTitle : item.presentation.title)
                    .font(GuidelyFonts.font(item.thankYou ? .headline : .caption, theme: theme, weight: .semibold))
                    .foregroundColor(item.thankYou ? palette.text : palette.muted)
                    .textCase(item.thankYou ? nil : .uppercase)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                GuidelyCloseButton(palette: palette, label: "Close survey") { item.presentation.onDismiss() }
                    .padding(.top, -6)
                    .padding(.trailing, -6)
                    .padding(.bottom, -6)
            }
            if item.thankYou {
                GuidelyRichText(html: cfg.thankYouBody, theme: theme, onLink: navigate)
                HStack {
                    Spacer()
                    Button("Done") { item.presentation.onDismiss() }
                        .buttonStyle(GuidelyButtonStyle(variant: .primary, palette: palette))
                }
            } else {
                ForEach(item.visibleQuestions) { q in
                    SurveyQuestionView(question: q, item: item, palette: palette)
                        .transition(.opacity)
                }
                if let error = item.error {
                    Text(error)
                        .font(GuidelyFonts.font(.caption, theme: theme))
                        .foregroundColor(Color(red: 0.86, green: 0.15, blue: 0.15))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { item.submit() } label: { Text("Submit").frame(maxWidth: .infinity) }
                    .buttonStyle(GuidelyButtonStyle(variant: .primary, palette: palette))
            }
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.2), value: item.visibleQuestions.map(\.id))
    }
}

struct SurveyQuestionView: View {
    let question: SurveyQuestion
    @ObservedObject var item: SurveyItem
    let palette: GuidelyPalette

    var body: some View {
        let theme = palette.theme
        VStack(alignment: .leading, spacing: 8) {
            Text(question.title + (question.required ? "" : " (optional)"))
                .font(GuidelyFonts.font(.subheadline, theme: theme, weight: .semibold))
                .foregroundColor(palette.text)
                .fixedSize(horizontal: false, vertical: true)
            if !question.description.isEmpty {
                Text(question.description)
                    .font(GuidelyFonts.font(.caption, theme: theme))
                    .foregroundColor(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            input
        }
    }

    private var answer: SurveyAnswer? { item.answers[question.id] }

    @ViewBuilder private var input: some View {
        switch question.type {
        case .nps: scale(0...10, labels: true)
        case .csat: scale(1...(question.scaleMax ?? 5), labels: true)
        case .rating: stars(question.scaleMax ?? 5)
        case .thumbs: thumbs
        case .singleChoice, .multipleChoice: choices(multi: question.type == .multipleChoice)
        case .text: textInput
        }
    }

    private func scale(_ range: ClosedRange<Int>, labels: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: range.count > 6 ? 3 : 6) {
                ForEach(Array(range), id: \.self) { i in
                    let selected = answer == .number(Double(i))
                    Button { item.set(question.id, .number(Double(i))) } label: {
                        Text("\(i)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(selected ? palette.onPrimary : palette.text)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? palette.primary : palette.subtle))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? palette.primary : palette.border, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(i)"))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if labels, question.lowLabel != nil || question.highLabel != nil {
                HStack {
                    Text(question.lowLabel ?? "")
                    Spacer()
                    Text(question.highLabel ?? "")
                }
                .font(GuidelyFonts.font(.caption2, theme: palette.theme))
                .foregroundColor(palette.muted)
            }
        }
    }

    private func stars(_ max: Int) -> some View {
        let value: Int = { if case .number(let n)? = answer { return Int(n) }; return 0 }()
        return HStack(spacing: 6) {
            ForEach(1...Swift.max(1, max), id: \.self) { i in
                Button { item.set(question.id, .number(Double(i))) } label: {
                    Image(systemName: i <= value ? "star.fill" : "star")
                        .font(.system(size: 26))
                        .foregroundColor(i <= value ? palette.primary : palette.muted)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(i) of \(max)"))
                .accessibilityAddTraits(i == value ? .isSelected : [])
            }
        }
    }

    private var thumbs: some View {
        HStack(spacing: 10) {
            ForEach([(true, "👍", "Thumbs up"), (false, "👎", "Thumbs down")], id: \.0) { value, icon, label in
                let selected = answer == .bool(value)
                Button { item.set(question.id, .bool(value)) } label: {
                    Text(icon)
                        .font(.system(size: 24))
                        .frame(width: 64, height: 48)
                        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? palette.primary.opacity(0.18) : palette.subtle))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? palette.primary : palette.border, lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(label))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func choices(multi: Bool) -> some View {
        let selected: Set<String> = {
            switch answer {
            case .string(let s)?: return [s]
            case .list(let l)?: return Set(l)
            default: return []
            }
        }()
        return VStack(spacing: 6) {
            ForEach(question.options) { opt in
                let on = selected.contains(opt.id)
                Button {
                    if multi {
                        var cur = selected
                        if on { cur.remove(opt.id) } else { cur.insert(opt.id) }
                        item.set(question.id, .list(question.options.map(\.id).filter { cur.contains($0) }))
                    } else {
                        item.set(question.id, .string(opt.id))
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: multi ? (on ? "checkmark.square.fill" : "square") : (on ? "largecircle.fill.circle" : "circle"))
                            .foregroundColor(on ? palette.primary : palette.muted)
                        Text(opt.label)
                            .font(GuidelyFonts.font(.subheadline, theme: palette.theme))
                            .foregroundColor(palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(on ? palette.primary.opacity(0.1) : palette.subtle))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? palette.primary : palette.border, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(opt.label))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var textInput: some View {
        let binding = Binding<String>(
            get: { item.text[question.id] ?? "" },
            set: { v in
                let capped = String(v.prefix(5000))
                item.text[question.id] = capped
                item.set(question.id, capped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .string(capped))
            }
        )
        Group {
            if #available(iOS 16.0, *) {
                TextField(question.placeholder ?? "", text: binding, axis: .vertical)
                    .lineLimit(3...6)
            } else {
                TextField(question.placeholder ?? "", text: binding)
            }
        }
        .font(GuidelyFonts.font(.subheadline, theme: palette.theme))
        .foregroundColor(palette.text)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(palette.subtle))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.border, lineWidth: 1))
        .accessibilityLabel(Text(question.title))
    }
}

// MARK: - Resource center

struct ResourceCenterLayer: View {
    @ObservedObject var item: ResourceCenterItem
    @ObservedObject var model: OverlayModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var launcherSize: CGSize = .zero

    var body: some View {
        let theme = item.presentation.theme.resolve(systemDark: scheme == .dark, reduceMotion: reduceMotion)
        let palette = GuidelyPalette(theme: theme)
        let cfg = item.presentation.config
        let width = min(model.size.width, 640)
        let height = min(model.size.height * 0.86, model.size.height - model.safeArea.top - 12)
        let sheetY = model.size.height - height
        let left = cfg.launcher.position == .bottomLeft
        let checklistSameSide = model.checklists.contains { $0.presentation.showLauncher && ($0.presentation.config.position == .bottomLeft) == left }
        let launcherY = model.contentBottom - 16 - launcherSize.height - (checklistSameSide ? 60 : 0)
        let launcherX = left ? model.safeArea.left + 16 : model.size.width - model.safeArea.right - 16 - launcherSize.width
        ZStack(alignment: .topLeading) {
            if item.presentation.showLauncher && !item.isOpen {
                Button { item.open() } label: {
                    HStack(spacing: 6) {
                        if cfg.launcher.showIcon { Image(systemName: "questionmark.circle.fill") }
                        Text(cfg.launcher.label.isEmpty ? cfg.title : cfg.launcher.label)
                            .font(GuidelyFonts.font(.subheadline, theme: theme, weight: .semibold))
                    }
                    .foregroundColor(palette.onPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(palette.primary))
                    .shadow(color: Color.black.opacity(0.22), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(cfg.launcher.label.isEmpty ? cfg.title : cfg.launcher.label))
                .measureSize { if launcherSize != $0 { launcherSize = $0 } }
                .guidelyInteractive("rc-launcher")
                .offset(x: launcherX, y: launcherY)
                .opacity(launcherSize.height > 0 ? 1 : 0)
            }
            if item.isOpen {
                Backdrop(size: model.size, color: palette.overlay, onTap: { item.close() })
                    .transition(.opacity)
                // Extends 24pt below the screen so only the top corners are rounded.
                ResourceCenterSheet(item: item, palette: palette, model: model)
                    .padding(.bottom, 24)
                    .frame(width: width, height: height + 24)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(palette.background)
                            .shadow(color: Color.black.opacity(0.25), radius: 20, x: 0, y: -4)
                            .padding(.bottom, -40)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
                    .guidelyInteractive("rc-sheet")
                    .offset(x: (model.size.width - width) / 2, y: sheetY)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom))
            }
        }
        .environment(\.colorScheme, palette.colorScheme)
    }
}

struct ResourceCenterSheet: View {
    @ObservedObject var item: ResourceCenterItem
    let palette: GuidelyPalette
    @ObservedObject var model: OverlayModel

    var body: some View {
        let theme = palette.theme
        let p = item.presentation
        VStack(spacing: 0) {
            Capsule().fill(palette.border).frame(width: 36, height: 5).padding(.top, 8).accessibilityHidden(true)
            HStack {
                if item.article != nil {
                    Button { withAnimation(model.animation) { item.article = nil } } label: {
                        HStack(spacing: 4) { Image(systemName: "chevron.left"); Text("Back") }
                            .font(GuidelyFonts.font(.subheadline, theme: theme, weight: .semibold))
                            .foregroundColor(palette.primary)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(p.config.title)
                        .font(GuidelyFonts.font(.title3, theme: theme, weight: .bold))
                        .foregroundColor(palette.text)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer()
                GuidelyCloseButton(palette: palette, label: "Close help") { item.close() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            if item.article == nil {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(palette.muted)
                    TextField("Search help articles…", text: Binding(get: { item.query }, set: { item.search($0) }))
                        .font(GuidelyFonts.font(.subheadline, theme: theme))
                        .foregroundColor(palette.text)
                        .disableAutocorrection(true)
                        .accessibilityLabel(Text("Search help articles"))
                    if !item.query.isEmpty {
                        Button { item.search("") } label: { Image(systemName: "xmark.circle.fill").foregroundColor(palette.muted) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Clear search"))
                    }
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.subtle))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let article = item.article {
                        ArticleView(article: article, palette: palette, navigate: model.navigate)
                    } else if !item.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        let results = item.results
                        SectionHeader(title: "Results (\(results.count))", palette: palette)
                        if results.isEmpty { EmptyRow(text: "No articles match your search.", palette: palette) }
                        ForEach(results) { a in RCRow(icon: "doc.text", title: a.title, summary: a.summary, palette: palette) { item.openArticle(a) } }
                    } else {
                        home
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .padding(.bottom, model.keyboardHeight > 0 ? model.keyboardHeight : model.safeArea.bottom)
            }
        }
    }

    @ViewBuilder private var home: some View {
        let p = item.presentation
        let recommended = p.recommended
        let checklists = p.checklists
        let sections = p.articleSections
        if !recommended.isEmpty {
            SectionHeader(title: "Recommended", palette: palette)
            ForEach(recommended) { g in RCRow(icon: "play.circle", title: g.name, summary: "Start guide", palette: palette) { p.onStartGuide(g.id) } }
        }
        if !checklists.isEmpty {
            SectionHeader(title: "Checklists", palette: palette)
            ForEach(checklists) { g in RCRow(icon: "checklist", title: g.name, summary: "Open checklist", palette: palette) { p.onOpenChecklist(g.id) } }
        }
        ForEach(sections) { section in
            SectionHeader(title: section.title, palette: palette)
            ForEach(section.articles) { a in RCRow(icon: "doc.text", title: a.title, summary: a.summary, palette: palette) { item.openArticle(a) } }
        }
        if !p.config.faqs.isEmpty {
            SectionHeader(title: "FAQ", palette: palette)
            ForEach(p.config.faqs) { f in
                let open = item.expandedFaqs.contains(f.id)
                RCRow(icon: open ? "chevron.down" : "chevron.right", title: f.question, summary: nil, palette: palette) {
                    withAnimation(model.animation) {
                        if open { item.expandedFaqs.remove(f.id) } else { item.expandedFaqs.insert(f.id) }
                    }
                }
                .accessibilityValue(Text(open ? "Expanded" : "Collapsed"))
                if open {
                    GuidelyRichText(html: f.answer, theme: palette.theme, onLink: model.navigate)
                        .padding(.leading, 40)
                        .padding(.bottom, 8)
                }
            }
        }
        if !p.config.links.isEmpty {
            SectionHeader(title: "Links", palette: palette)
            ForEach(p.config.links) { l in RCRow(icon: "arrow.up.right.square", title: l.label, summary: nil, palette: palette) { p.onOpenURL(l.url) } }
        }
        if recommended.isEmpty && checklists.isEmpty && sections.isEmpty && p.config.faqs.isEmpty && p.config.links.isEmpty {
            EmptyRow(text: "Nothing here yet.", palette: palette)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let palette: GuidelyPalette
    var body: some View {
        Text(title)
            .font(GuidelyFonts.font(.caption, theme: palette.theme, weight: .semibold))
            .foregroundColor(palette.muted)
            .textCase(.uppercase)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyRow: View {
    let text: String
    let palette: GuidelyPalette
    var body: some View {
        Text(text)
            .font(GuidelyFonts.font(.subheadline, theme: palette.theme))
            .foregroundColor(palette.muted)
            .padding(.vertical, 12)
    }
}

struct RCRow: View {
    let icon: String
    let title: String
    let summary: String?
    let palette: GuidelyPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(palette.primary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(palette.primary.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(GuidelyFonts.font(.subheadline, theme: palette.theme, weight: .medium))
                        .foregroundColor(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let summary, !summary.isEmpty {
                        Text(summary)
                            .font(GuidelyFonts.font(.caption, theme: palette.theme))
                            .foregroundColor(palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ArticleView: View {
    let article: ResourceCenterArticle
    let palette: GuidelyPalette
    let navigate: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(article.title)
                .font(GuidelyFonts.font(.title3, theme: palette.theme, weight: .bold))
                .foregroundColor(palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ArticleBodyView(html: article.body, palette: palette, navigate: navigate)
        }
        .padding(.top, 8)
    }
}

/// Article body: rich text segments, full-width images, videos as links (no inline players), inline
/// PDFs (page carousel + full-screen reader) and file cards.
struct ArticleBodyView: View {
    let html: String
    let palette: GuidelyPalette
    let navigate: (URL) -> Void

    var body: some View {
        let blocks = HTMLParser.blocks(html)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let rich):
                    GuidelyRichText(rich: rich, theme: palette.theme, base: .body, onLink: navigate)
                case let .image(url, alt, width, height):
                    ArticleImage(url: URL(string: url), alt: alt, ratio: width.flatMap { w in height.map { w / $0 } }, palette: palette)
                case let .video(url, label):
                    Button { if let u = URL(string: url) { navigate(u) } } label: {
                        HStack(spacing: 8) {
                            Text("▶").accessibilityHidden(true)
                            Text(label).font(GuidelyFonts.font(.subheadline, theme: palette.theme, weight: .semibold))
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(palette.primary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 8).fill(palette.subtle))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(label))
                    .accessibilityAddTraits(.isLink)
                case let .file(url, name):
                    ArticleFileCard(url: url, name: name, palette: palette, navigate: navigate)
                case let .pdf(url, name, pages):
                    ArticlePdfView(url: url, name: name, pages: pages, palette: palette, navigate: navigate)
                }
            }
        }
    }
}

/// Attached file (a PDF without rendered pages): a card like the video link that opens the file.
struct ArticleFileCard: View {
    let url: String
    let name: String
    let palette: GuidelyPalette
    let navigate: (URL) -> Void

    var body: some View {
        Button { if let u = URL(string: url) { navigate(u) } } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").font(.system(size: 20)).foregroundColor(palette.primary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(GuidelyFonts.font(.subheadline, theme: palette.theme, weight: .semibold))
                        .foregroundColor(palette.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("PDF").font(GuidelyFonts.font(.caption, theme: palette.theme)).foregroundColor(palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.subtle))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(name), PDF"))
        .accessibilityAddTraits(.isLink)
    }
}

/// Inline PDF: a header (name, expand) over a paging carousel of the pre-rendered pages with a
/// "3 / 12" indicator. Tapping a page or expand opens `ArticlePdfReader` full screen.
struct ArticlePdfView: View {
    let url: String
    let name: String
    let pages: [ArticlePdfPage]
    let palette: GuidelyPalette
    let navigate: (URL) -> Void
    @State private var page = 0
    @State private var reading = false

    /// Width / height of the tallest page so every page fits (A4 portrait when sizes are unknown).
    private var ratio: CGFloat { pages.map(ArticlePdfPageImage.ratio).min() ?? ArticlePdfPageImage.a4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext").foregroundColor(palette.primary).accessibilityHidden(true)
                Text(name)
                    .font(GuidelyFonts.font(.subheadline, theme: palette.theme, weight: .semibold))
                    .foregroundColor(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button { reading = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(palette.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Open \(name) full screen"))
            }
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    ArticlePdfPageImage(page: p)
                        .padding(12)
                        .contentShape(Rectangle())
                        .onTapGesture { reading = true }
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity)
            .aspectRatio(ratio, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                if pages.count > 1 {
                    Text("\(page + 1) / \(pages.count)")
                        .font(GuidelyFonts.font(.caption2, theme: palette.theme, weight: .semibold).monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(18)
                        .accessibilityHidden(true)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.subtle))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(palette.border))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(pages.indices.contains(page) && !pages[page].alt.isEmpty ? pages[page].alt : name))
            .accessibilityValue(Text("Page \(page + 1) of \(pages.count)"))
            .accessibilityHint(Text("Double-tap to read full screen"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: page = min(page + 1, pages.count - 1)
                case .decrement: page = max(page - 1, 0)
                @unknown default: break
                }
            }
            .accessibilityAction { reading = true }
        }
        .fullScreenCover(isPresented: $reading) {
            ArticlePdfReader(url: url, name: name, pages: pages, start: page, palette: palette, navigate: navigate)
        }
    }
}

/// Full-screen PDF reader: every page stacked vertically, opened at the carousel's page, with "Open
/// original" (the PDF itself, via the link-open path) and Done.
struct ArticlePdfReader: View {
    let url: String
    let name: String
    let pages: [ArticlePdfPage]
    let start: Int
    let palette: GuidelyPalette
    let navigate: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { i, p in ArticlePdfPageImage(page: p).id(i) }
                    }
                    .padding(16)
                }
                .onAppear { if start > 0 { proxy.scrollTo(start, anchor: .top) } }
            }
            .background(palette.subtle.background(palette.background).ignoresSafeArea())
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                        if let u = URL(string: url) { navigate(u) }
                    } label: { Image(systemName: "safari") }
                    .accessibilityLabel(Text("Open original"))
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .navigationViewStyle(.stack)
        .accentColor(palette.primary)
        .environment(\.colorScheme, palette.colorScheme)
    }
}

/// One rendered PDF page: a white sheet with a subtle border and shadow, aspect-fit at the page's
/// ratio (A4 portrait when unknown), labelled with its alt text.
struct ArticlePdfPageImage: View {
    static let a4: CGFloat = 1 / 1.414
    static func ratio(_ p: ArticlePdfPage) -> CGFloat { p.width.flatMap { w in p.height.map { CGFloat(w / $0) } } ?? a4 }

    let page: ArticlePdfPage

    var body: some View {
        AsyncImage(url: URL(string: page.url)) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Color.white
                    if phase.error == nil { ProgressView() }
                }
            }
        }
        .aspectRatio(Self.ratio(page), contentMode: .fit)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.1)))
        .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(Text(page.alt))
        .accessibilityAddTraits(.isImage)
    }
}

/// Full-width, aspect-fit body image (16:9 placeholder until loaded when no size is given).
struct ArticleImage: View {
    let url: URL?
    let alt: String
    let ratio: Double?
    let palette: GuidelyPalette

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(palette.subtle).aspectRatio(ratio ?? 16 / 9, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement()
        .accessibilityLabel(Text(alt))
        .accessibilityAddTraits(.isImage)
        .accessibilityHidden(alt.isEmpty)
    }
}
#endif
