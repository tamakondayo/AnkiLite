import SwiftUI

/// Builds the front/back HTML for a card and substitutes media placeholders.
struct CardRenderer {
    let due: StudySession.DueCard

    private var renderer: AnkiTemplateRenderer {
        AnkiTemplateRenderer(noteType: due.noteType)
    }

    func frontHTML() -> String {
        let html = renderer.render(note: due.note, ord: due.card.ord, side: .question)
        return substituteMissingMedia(html)
    }

    func backHTML() -> String {
        let front = renderer.render(note: due.note, ord: due.card.ord, side: .question)
        let html = renderer.render(note: due.note, ord: due.card.ord, side: .answer, frontSide: front)
        return substituteMissingMedia(html)
    }

    /// Replaces `<img>` references to missing files with a simple placeholder.
    private func substituteMissingMedia(_ html: String) -> String {
        let pattern = "<img[^>]*src=\"([^\"]+)\"[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let ns = html as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            lastEnd = match.range.location + match.range.length
            let tag = ns.substring(with: match.range)
            let name = ns.substring(with: match.range(at: 1))
            if name.hasPrefix("data:") || MediaManager.shared.mediaExists(named: name) {
                result += tag
            } else {
                result += "<span class=\"missing-media\">画像なし</span>"
            }
        }
        result += ns.substring(from: lastEnd)
        return result
    }
}

/// Creates a `StudySession` for the deck and surfaces any errors.
struct StudyContainerView: View {
    let deck: Deck
    @EnvironmentObject private var settings: AppSettings
    @State private var session: StudySession?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let session {
                StudyView(session: session)
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.Answer.again)
                    Text(errorMessage)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
            } else {
                ProgressView()
                    .tint(Theme.accent)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear(perform: start)
    }

    private func start() {
        guard session == nil else { return }
        do {
            // Refetch so per-deck limit edits apply even if the list row
            // that pushed us was rendered before the edit.
            let fresh = (try? DatabaseManager.shared.deck(id: deck.id)) ?? deck
            session = try StudySession(deck: fresh,
                                       scheduler: settings.makeScheduler(),
                                       newCardLimit: fresh.newPerDay ?? settings.newCardsPerDay,
                                       reviewLimit: fresh.reviewsPerDay ?? settings.reviewsPerDay)
        } catch {
            errorMessage = "学習を開始できませんでした: \(error.localizedDescription)"
        }
    }
}

struct StudyView: View {
    @ObservedObject var session: StudySession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var showingAnswer = false
    @State private var dragOffset: CGSize = .zero
    @State private var sessionStartedAt: Date?

    private var nightMode: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            countBar
            if session.isFinished {
                CompletionView(stats: session.stats,
                               settings: settings,
                               nextLearningDue: session.nextLearningDue) { dismiss() }
            } else if let due = session.current {
                ZStack(alignment: .bottom) {
                    cardArea(for: due)
                    if showingAnswer {
                        answerArea(for: due)
                    } else {
                        tapHint
                    }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(session.deck.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                cardActionsMenu
            }
        }
        .onAppear {
            if sessionStartedAt == nil { sessionStartedAt = Date() }
        }
        .onChange(of: session.isFinished) { _, finished in
            if finished { Haptics.success(enabled: settings.haptics) }
        }
    }

    /// Subtle floating hint shown over the front of the card.
    private var tapHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.tap")
                .font(.caption)
            Text("タップまたは上にスワイプで答え")
                .font(.caption)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 18)
        .allowsHitTesting(false)
    }

    // MARK: - Card actions menu (Undo / Bury / Suspend / Flag)

    private var cardActionsMenu: some View {
        Menu {
            Button {
                Haptics.tap(enabled: settings.haptics)
                try? session.undo()
            } label: {
                Label("元に戻す", systemImage: "arrow.uturn.backward")
            }
            .disabled(!session.canUndo)

            if session.current != nil {
                Divider()
                Menu {
                    ForEach(CardFlag.allCases, id: \.rawValue) { flag in
                        Button {
                            Haptics.tap(enabled: settings.haptics)
                            try? session.setFlag(flag)
                        } label: {
                            HStack {
                                if flag == session.currentFlag {
                                    Image(systemName: "checkmark")
                                }
                                Image(systemName: flag == .none ? "flag.slash" : "flag.fill")
                                    .foregroundStyle(Color(hex: flag.hex))
                                Text(flag.label)
                            }
                        }
                    }
                } label: {
                    Label("フラグ", systemImage: "flag")
                }

                Button {
                    Haptics.tap(enabled: settings.haptics)
                    try? session.buryCurrent()
                } label: {
                    Label("保留する（今日は表示しない）", systemImage: "moon.zzz")
                }

                Button(role: .destructive) {
                    Haptics.tap(enabled: settings.haptics)
                    try? session.suspendCurrent()
                } label: {
                    Label("停止する（学習対象外）", systemImage: "pause.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .tint(Theme.textSecondary)
        }
    }

    // MARK: - Count bar

    private var countBar: some View {
        HStack(spacing: 18) {
            countItem(value: session.counts.new, label: "新規", color: Theme.Count.new)
            divider
            countItem(value: session.counts.learning, label: "学習", color: Theme.Count.learning)
            divider
            countItem(value: session.counts.review, label: "復習", color: Theme.Count.review)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 0.5)
        }
    }

    private func countItem(value: Int, label: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(value)")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(value > 0 ? Theme.textPrimary : Theme.textTertiary)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(width: 0.5, height: 14)
    }

    // MARK: - Card

    private func cardArea(for due: StudySession.DueCard) -> some View {
        let renderer = CardRenderer(due: due)
        let body = showingAnswer ? renderer.backHTML() : renderer.frontHTML()

        return ZStack {
            CardWebView(bodyHTML: body,
                        userCSS: due.noteType.css,
                        nightMode: nightMode,
                        fontSize: settings.cardFontSize)
                // WebView would otherwise swallow taps before SwiftUI sees them.
                // Only enable hit-testing on the back so <audio> controls work.
                .allowsHitTesting(showingAnswer)

            // Transparent layer that always receives the tap/drag — keeps the
            // reveal gesture working regardless of what the HTML body contains.
            Color.clear
                .contentShape(Rectangle())
                .allowsHitTesting(!showingAnswer)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
        .overlay(alignment: .topLeading) {
            if due.card.colorFlag != .none {
                Image(systemName: "flag.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: due.card.colorFlag.hex))
                    .padding(10)
            }
        }
        .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 6)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        // Reserve space at the bottom that fits the (taller) answer bar.
        .padding(.bottom, 96)
        .id("\(due.id)-\(showingAnswer)")
        .offset(x: dragOffset.width)
        .contentShape(Rectangle())
        .onTapGesture { revealAnswer() }
        .gesture(cardGesture(for: due))
        .onChange(of: due.id) { _, _ in
            showingAnswer = false
        }
    }

    private func revealAnswer() {
        guard !showingAnswer else { return }
        Haptics.tap(enabled: settings.haptics)
        showingAnswer = true
    }

    /// Unified gesture:
    ///   - Front: tap or any drag past the threshold flips to the answer
    ///     (drags don't commit, since the answer hasn't been read yet).
    ///   - Back: horizontal commits Again/Good. Vertical is deliberately
    ///     ignored to keep accidental Hard/Easy off — those are explicit
    ///     button taps, since they materially affect the schedule.
    private func cardGesture(for due: StudySession.DueCard) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                // Only follow the finger horizontally on the back side
                // (mirrors the only commit gestures we support there).
                if showingAnswer {
                    dragOffset = CGSize(width: value.translation.width,
                                        height: value.translation.height * 0.15)
                } else {
                    // Front: just hint at the swipe but stay close to home.
                    let dampened = value.translation.width * 0.3
                    dragOffset = CGSize(width: dampened,
                                        height: value.translation.height * 0.1)
                }
            }
            .onEnded { value in
                let h = value.translation.width
                let v = value.translation.height
                let threshold: CGFloat = 100

                if !showingAnswer {
                    let revealed = abs(h) > threshold || v < -threshold
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dragOffset = .zero }
                    if revealed { revealAnswer() }
                    return
                }

                // Back: only horizontal swipes commit.
                if abs(h) > abs(v) {
                    if h < -threshold { commit(.again, due: due); return }
                    if h > threshold { commit(.good, due: due); return }
                }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dragOffset = .zero }
            }
    }

    // MARK: - Answer area

    private func answerArea(for due: StudySession.DueCard) -> some View {
        let labels = session.intervalLabels()
        return HStack(spacing: 8) {
            ForEach(ReviewEase.allCases, id: \.self) { ease in
                AnswerButton(ease: ease, intervalText: labels[ease] ?? "") {
                    commit(ease, due: due)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    private func commit(_ ease: ReviewEase, due: StudySession.DueCard) {
        Haptics.answer(enabled: settings.haptics)
        dragOffset = .zero
        showingAnswer = false
        try? session.answer(ease)
    }
}

private struct AnswerButton: View {
    let ease: ReviewEase
    let intervalText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(intervalText)
                    .font(.caption2.weight(.medium))
                    .opacity(0.9)
                Text(ease.label)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [ease.color, ease.color.opacity(0.85)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: ease.color.opacity(0.3), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

/// Slight scale-down when pressed — feels more tactile than the default.
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Shown when the deck's due queue is exhausted.
private struct CompletionView: View {
    let stats: StudySession.SessionStats
    let settings: AppSettings
    var nextLearningDue: Date?
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.seal")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.Count.review)

            VStack(spacing: 8) {
                Text("お疲れさまでした")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("このデッキの今日の分は終わりです")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                if let nextLearningDue {
                    let minutes = max(1, Int((nextLearningDue.timeIntervalSinceNow / 60).rounded()))
                    Text("次の学習カードは約\(minutes)分後です")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if stats.reviewed > 0 {
                HStack(spacing: 0) {
                    statBlock(value: "\(stats.reviewed)", label: "レビュー")
                    divider
                    statBlock(value: formatTime(ms: stats.totalTimeMs), label: "学習時間")
                    divider
                    statBlock(value: "\(Int(round(Double(stats.reviewed - stats.again) / Double(stats.reviewed) * 100)))%",
                              label: "正答率")
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .padding(.horizontal, 20)
            }

            Spacer()

            Button(action: onDone) {
                Text("デッキ一覧に戻る")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
            .buttonStyle(ScaleButtonStyle())
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(width: 0.5)
    }

    private func statBlock(value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatTime(ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return String(localized: "\(seconds)秒") }
        let minutes = seconds / 60
        let remSec = seconds % 60
        if minutes < 10 { return "\(minutes):\(String(format: "%02d", remSec))" }
        return String(localized: "\(minutes)分")
    }
}
