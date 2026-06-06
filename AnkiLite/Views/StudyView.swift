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
                result += "<span class=\"missing-media\" style=\"color:#999;border:1px dashed #999;padding:4px 8px;border-radius:6px;\">画像なし</span>"
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
                Text(errorMessage)
                    .foregroundStyle(Theme.textSecondary)
                    .padding()
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
                                       scheduler: SM2Scheduler(config: settings.schedulerConfig))
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

    private var nightMode: Bool { colorScheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            countBar
            if session.isFinished {
                CompletionView(stats: session.stats) { dismiss() }
            } else if let due = session.current {
                cardArea(for: due)
                answerArea(for: due)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(session.deck.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Count bar

    private var countBar: some View {
        HStack(spacing: 16) {
            countLabel(session.counts.new, color: Theme.Count.new)
            countLabel(session.counts.learning, color: Theme.Count.learning)
            countLabel(session.counts.review, color: Theme.Count.review)
        }
        .font(.footnote.monospacedDigit().weight(.medium))
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
    }

    private func countLabel(_ value: Int, color: Color) -> some View {
        Text("\(value)")
            .foregroundStyle(color)
    }

    // MARK: - Card

    private func cardArea(for due: StudySession.DueCard) -> some View {
        let renderer = CardRenderer(due: due)
        let body = showingAnswer ? renderer.backHTML() : renderer.frontHTML()

        return CardWebView(bodyHTML: body, userCSS: due.noteType.css, nightMode: nightMode)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            )
            .padding(16)
            .id(due.id) // recreate web view per card
            .offset(x: dragOffset.width)
            .rotationEffect(.degrees(Double(dragOffset.width) / 30))
            .gesture(swipeGesture(for: due))
            .onTapGesture {
                if !showingAnswer {
                    withAnimation(.easeInOut(duration: 0.2)) { showingAnswer = true }
                }
            }
            .onChange(of: due.id) { _, _ in showingAnswer = false }
    }

    private func swipeGesture(for due: StudySession.DueCard) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard showingAnswer else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard showingAnswer else { dragOffset = .zero; return }
                let threshold: CGFloat = 90
                if value.translation.width < -threshold {
                    commit(.again, due: due)
                } else if value.translation.width > threshold {
                    commit(.good, due: due)
                } else {
                    withAnimation(.spring) { dragOffset = .zero }
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
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showingAnswer = true }
            } label: {
                Text("答えを表示")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.surfaceRaised)
                    .foregroundStyle(Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func commit(_ ease: ReviewEase, due: StudySession.DueCard) {
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
            VStack(spacing: 2) {
                Text(ease.label)
                    .font(.subheadline.weight(.semibold))
                Text(intervalText)
                    .font(.caption2)
                    .opacity(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .background(ease.color)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Shown when the deck's due queue is exhausted.
private struct CompletionView: View {
    let stats: StudySession.SessionStats
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.Count.review)
            Text("今日の学習は完了です")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 4) {
                Text("レビュー \(stats.reviewed) 枚")
                if stats.reviewed > 0 {
                    let seconds = Double(stats.totalTimeMs) / 1000.0
                    Text("学習時間 \(Int(seconds.rounded()))秒")
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button(action: onDone) {
                Text("デッキ一覧に戻る")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.surfaceRaised)
                    .foregroundStyle(Theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}
