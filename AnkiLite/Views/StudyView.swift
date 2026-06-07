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
            session = try StudySession(deck: deck,
                                       scheduler: SM2Scheduler(config: settings.schedulerConfig),
                                       newCardLimit: settings.newCardsPerDay,
                                       reviewLimit: settings.reviewsPerDay)
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
    @State private var flipAngle: Double = 0
    @State private var sessionStartedAt: Date?

    private var nightMode: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            countBar
            if session.isFinished {
                CompletionView(stats: session.stats, settings: settings) { dismiss() }
            } else if let due = session.current {
                cardArea(for: due)
                answerArea(for: due)
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

    private func countItem(value: Int, label: String, color: Color) -> some View {
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

        return CardWebView(bodyHTML: body,
                           userCSS: due.noteType.css,
                           nightMode: nightMode,
                           fontSize: settings.cardFontSize)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .id("\(due.id)-\(showingAnswer)")
            .offset(x: dragOffset.width, y: dragOffset.height * 0.2)
            .rotationEffect(.degrees(Double(dragOffset.width) / 35))
            .rotation3DEffect(.degrees(flipAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .gesture(swipeGesture(for: due))
            .onTapGesture { revealAnswer() }
            .onChange(of: due.id) { _, _ in
                showingAnswer = false
                flipAngle = 0
            }
    }

    private func revealAnswer() {
        guard !showingAnswer else { return }
        Haptics.tap(enabled: settings.haptics)
        // Subtle half-flip then settle, to communicate the "turning over".
        withAnimation(.easeIn(duration: 0.18)) {
            flipAngle = 90
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            showingAnswer = true
            flipAngle = -90
            withAnimation(.easeOut(duration: 0.18)) {
                flipAngle = 0
            }
        }
    }

    private func swipeGesture(for due: StudySession.DueCard) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard showingAnswer else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard showingAnswer else { dragOffset = .zero; return }
                let threshold: CGFloat = 100
                if value.translation.width < -threshold {
                    commit(.again, due: due)
                } else if value.translation.width > threshold {
                    commit(.good, due: due)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragOffset = .zero }
                }
            }
    }

    // MARK: - Answer area

    @ViewBuilder
    private func answerArea(for due: StudySession.DueCard) -> some View {
        if showingAnswer {
            let labels = session.intervalLabels()
            HStack(spacing: 8) {
                ForEach(ReviewEase.allCases, id: \.self) { ease in
                    AnswerButton(ease: ease, intervalText: labels[ease] ?? "") {
                        commit(ease, due: due)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            Button(action: revealAnswer) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.tap")
                        .font(.subheadline)
                    Text("答えを表示")
                        .font(.body.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Theme.surfaceRaised)
                .foregroundStyle(Theme.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func commit(_ ease: ReviewEase, due: StudySession.DueCard) {
        Haptics.answer(enabled: settings.haptics)
        // Slide the card out in the direction the user pushed (or just fade for taps).
        let slideOut: CGFloat = (ease == .again ? -1 : 1) * 600
        withAnimation(.easeIn(duration: 0.18)) {
            dragOffset = CGSize(width: slideOut, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            dragOffset = .zero
            showingAnswer = false
            flipAngle = 0
            try? session.answer(ease)
        }
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
            }

            if stats.reviewed > 0 {
                HStack(spacing: 0) {
                    statBlock(value: "\(stats.reviewed)", label: "レビュー")
                    divider
                    statBlock(value: formatTime(ms: stats.totalTimeMs), label: "学習時間")
                    if stats.reviewed > 0 {
                        divider
                        statBlock(value: "\(Int(round(Double(stats.reviewed - stats.again) / Double(stats.reviewed) * 100)))%",
                                  label: "正答率")
                    }
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

    private func statBlock(value: String, label: String) -> some View {
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
        if seconds < 60 { return "\(seconds)秒" }
        let minutes = seconds / 60
        let remSec = seconds % 60
        if minutes < 10 { return "\(minutes):\(String(format: "%02d", remSec))" }
        return "\(minutes)分"
    }
}
