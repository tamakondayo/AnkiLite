import SwiftUI
import GRDB
import Combine

/// Loads and filters cards for the browser view.
@MainActor
final class CardBrowserViewModel: ObservableObject {

    struct Row: Identifiable {
        var card: Card
        var note: Note
        var noteType: NoteType
        /// Stripped sort-field text used for the preview line.
        var preview: String
        var tags: [String]
        var id: Int64 { card.id }
    }

    enum StateFilter: String, CaseIterable, Identifiable {
        case all, new, learning, review, buried, suspended
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: return String(localized: "すべて")
            case .new: return String(localized: "新規")
            case .learning: return String(localized: "学習中")
            case .review: return String(localized: "復習")
            case .buried: return String(localized: "保留中")
            case .suspended: return String(localized: "停止中")
            }
        }
    }

    @Published var rows: [Row] = []
    @Published var query: String = ""
    @Published var stateFilter: StateFilter = .all
    @Published var flagFilter: CardFlag? = nil
    @Published var isLoading = false
    /// Pre-edit snapshot of the most recently saved note edit, undoable
    /// until the banner times out or the view goes away.
    @Published var undoableEdit: Note?

    let deck: Deck
    private let database: DatabaseManager
    private let deckIds: [Int64]
    private let scopeDecks: [Deck]

    init(deck: Deck, database: DatabaseManager = .shared) {
        self.deck = deck
        self.database = database
        let all = (try? database.allDecks()) ?? []
        let prefix = deck.name + "::"
        self.scopeDecks = all.filter { $0.id == deck.id || $0.name.hasPrefix(prefix) }
        self.deckIds = scopeDecks.map(\.id)
    }

    /// Re-runs the query (debouncing should be handled by the caller).
    func reload() {
        isLoading = true
        defer { isLoading = false }
        guard !deckIds.isEmpty else { rows = []; return }

        let placeholders = databaseQuestionMarks(count: deckIds.count)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Build the WHERE clause incrementally.
        var sql = """
            SELECT card.* FROM card
            JOIN note ON note.id = card.nid
            WHERE card.did IN (\(placeholders))
            """
        var args: [(any DatabaseValueConvertible)?] = deckIds.map { $0 as (any DatabaseValueConvertible)? }

        switch stateFilter {
        case .all: break
        case .new: sql += " AND card.queue = \(CardQueue.new.rawValue)"
        case .learning: sql += " AND card.queue IN (\(CardQueue.learning.rawValue), \(CardQueue.dayLearning.rawValue))"
        case .review: sql += " AND card.queue = \(CardQueue.review.rawValue)"
        case .buried: sql += " AND card.queue = \(CardQueue.buried.rawValue)"
        case .suspended: sql += " AND card.queue = \(CardQueue.suspended.rawValue)"
        }

        if let flag = flagFilter, flag != .none {
            sql += " AND (card.flags & 7) = \(flag.rawValue)"
        }

        if !q.isEmpty {
            // Anki-style search syntax (deck:/tag:/is:/flag:, quotes,
            // -negation, * wildcards) with escaped LIKE matching.
            let crt = (try? database.collectionCreationTime()) ?? 0
            let context = BrowserSearch.Context(
                scopeDecks: scopeDecks,
                todayDays: SM2Scheduler().today(now: Date(), crt: crt),
                nowCutoff: Int64(Date().timeIntervalSince1970)
            )
            let compiled = BrowserSearch.compile(query: q, context: context)
            sql += compiled.sqlFragment
            args.append(contentsOf: compiled.arguments)
        }

        sql += " ORDER BY note.sfld ASC LIMIT 500"

        let cards: [Card] = (try? database.dbQueue.read { db in
            try Card.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }) ?? []

        // Resolve note + noteType + preview text.
        var built: [Row] = []
        built.reserveCapacity(cards.count)
        for card in cards {
            guard let note = try? database.note(id: card.nid),
                  let nt = try? database.noteType(id: note.mid) else { continue }
            let preview = Self.preview(for: note, noteType: nt)
            built.append(Row(card: card, note: note, noteType: nt, preview: preview, tags: note.tagList))
        }
        rows = built
    }

    /// Strips HTML / cloze markers from the sort field for a one-line preview.
    private static func preview(for note: Note, noteType: NoteType) -> String {
        var text = note.sfld
        if text.isBlank { text = note.fieldValues.first ?? "" }
        // Strip HTML tags.
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }
        // Strip cloze syntax to readable text.
        if let regex = try? NSRegularExpression(pattern: "\\{\\{c\\d+::([^:}]*)(?:::[^}]*)?\\}\\}") {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        }
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Mutations

    func deleteCard(_ card: Card) {
        try? database.dbQueue.write { db in
            try card.delete(db)
            // Delete orphan notes too.
            try db.execute(sql: """
                DELETE FROM \(Note.databaseTableName)
                WHERE id NOT IN (SELECT DISTINCT nid FROM \(Card.databaseTableName))
                """)
        }
        reload()
    }

    func setFlag(_ flag: CardFlag, on card: Card) {
        var updated = card
        updated.colorFlag = flag
        updated.mod = Int64(Date().timeIntervalSince1970)
        try? database.saveCard(updated)
        reload()
    }

    func setQueue(_ queue: CardQueue, on card: Card) {
        var updated = card
        updated.cardQueue = queue
        updated.mod = Int64(Date().timeIntervalSince1970)
        try? database.saveCard(updated)
        reload()
    }

    /// Reverts the last saved note edit to its pre-edit snapshot.
    func undoLastEdit() {
        guard let original = undoableEdit else { return }
        try? database.dbQueue.write { db in
            try original.update(db)
        }
        undoableEdit = nil
        reload()
    }

    /// Restore a suspended/buried card to its natural queue (derived from `type`).
    func restore(_ card: Card) {
        var updated = card
        switch card.cardType {
        case .new: updated.cardQueue = .new
        case .learning, .relearning: updated.cardQueue = .learning
        case .review: updated.cardQueue = .review
        }
        updated.mod = Int64(Date().timeIntervalSince1970)
        try? database.saveCard(updated)
        reload()
    }
}

struct CardBrowserView: View {
    @StateObject private var viewModel: CardBrowserViewModel
    @State private var debounceTask: Task<Void, Never>?
    @State private var selectedRow: CardBrowserViewModel.Row?

    init(deck: Deck) {
        _viewModel = StateObject(wrappedValue: CardBrowserViewModel(deck: deck))
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if viewModel.rows.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(viewModel.rows) { row in
                        Button {
                            selectedRow = row
                        } label: {
                            CardBrowserRowView(row: row)
                        }
                        .listRowBackground(Theme.surface)
                        .listRowSeparatorTint(Theme.separator)
                        .swipeActions(edge: .trailing) {
                            // swipeActions only honour plain Buttons (a Menu
                            // here renders but never opens) — the flag picker
                            // lives in the context menu instead.
                            Button(role: .destructive) {
                                viewModel.deleteCard(row.card)
                            } label: { Label("削除", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            if row.card.cardQueue == .suspended || row.card.cardQueue == .buried {
                                Button {
                                    viewModel.restore(row.card)
                                } label: { Label("復活", systemImage: "play.fill") }
                                .tint(Theme.Count.review)
                            } else {
                                Button {
                                    viewModel.setQueue(.suspended, on: row.card)
                                } label: { Label("停止", systemImage: "pause.fill") }
                                .tint(Theme.textTertiary)
                            }
                        }
                        .contextMenu {
                            Menu {
                                ForEach(CardFlag.allCases, id: \.rawValue) { flag in
                                    Button {
                                        viewModel.setFlag(flag, on: row.card)
                                    } label: {
                                        HStack {
                                            if flag == row.card.colorFlag {
                                                Image(systemName: "checkmark")
                                            }
                                            Image(systemName: flag == .none ? "flag.slash" : "flag.fill")
                                                .foregroundStyle(Color(hex: flag.hex))
                                            Text(flag.label)
                                        }
                                    }
                                }
                            } label: { Label("フラグ", systemImage: "flag") }
                            if row.card.cardQueue == .suspended || row.card.cardQueue == .buried {
                                Button {
                                    viewModel.restore(row.card)
                                } label: { Label("復活", systemImage: "play.fill") }
                            } else {
                                Button {
                                    viewModel.setQueue(.suspended, on: row.card)
                                } label: { Label("停止", systemImage: "pause.circle") }
                            }
                            Divider()
                            Button(role: .destructive) {
                                viewModel.deleteCard(row.card)
                            } label: { Label("削除", systemImage: "trash") }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("ブラウザ")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.query, prompt: "検索 (deck: tag: is: flag:)")
        .onChange(of: viewModel.query) { _, _ in scheduleReload() }
        .onChange(of: viewModel.stateFilter) { _, _ in viewModel.reload() }
        .onChange(of: viewModel.flagFilter) { _, _ in viewModel.reload() }
        .onAppear { viewModel.reload() }
        .sheet(item: $selectedRow) { row in
            NoteEditView(initialNote: row.note, noteType: row.noteType) {
                // Keep the pre-edit snapshot so the save can be undone.
                viewModel.undoableEdit = row.note
                viewModel.reload()
            }
        }
        .overlay(alignment: .bottom) {
            if viewModel.undoableEdit != nil {
                undoBanner
            }
        }
    }

    private var undoBanner: some View {
        HStack(spacing: 12) {
            Text("ノートを保存しました")
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                viewModel.undoLastEdit()
            } label: {
                Text("元に戻す")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .stroke(Theme.separator, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
            // Auto-dismiss the banner after a few seconds.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            viewModel.undoableEdit = nil
        }
    }

    private func scheduleReload() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            viewModel.reload()
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(CardBrowserViewModel.StateFilter.allCases) { state in
                    Button(state.label) { viewModel.stateFilter = state }
                }
            } label: {
                filterChip(text: viewModel.stateFilter.label, systemImage: "line.3.horizontal.decrease")
            }
            Menu {
                Button("すべて") { viewModel.flagFilter = nil }
                Divider()
                ForEach(CardFlag.allCases, id: \.rawValue) { flag in
                    Button {
                        viewModel.flagFilter = flag
                    } label: {
                        HStack {
                            Image(systemName: flag == .none ? "flag.slash" : "flag.fill")
                                .foregroundStyle(Color(hex: flag.hex))
                            Text(flag.label)
                        }
                    }
                }
            } label: {
                filterChip(text: viewModel.flagFilter.map { "🚩 \($0.label)" } ?? "フラグ",
                          systemImage: "flag")
            }
            Spacer()
            Text("\(viewModel.rows.count)件")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 0.5)
        }
    }

    private func filterChip(text: String, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.caption)
            Text(text).font(.caption)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surfaceRaised)
        .foregroundStyle(Theme.textPrimary)
        .clipShape(Capsule())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(viewModel.isLoading ? "読み込み中…" : "該当するカードがありません")
                .foregroundStyle(Theme.textSecondary)
                .font(.subheadline)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CardBrowserRowView: View {
    let row: CardBrowserViewModel.Row

    var body: some View {
        HStack(spacing: 10) {
            stateIndicator
            if row.card.colorFlag != .none {
                Image(systemName: "flag.fill")
                    .font(.caption)
                    .foregroundStyle(Color(hex: row.card.colorFlag.hex))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.preview.isEmpty ? "（空のカード）" : row.preview)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.noteType.name)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                    if !row.tags.isEmpty {
                        Text("·").foregroundStyle(Theme.textTertiary).font(.caption2)
                        Text(row.tags.prefix(3).joined(separator: " "))
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            if row.card.ivl > 0 {
                Text("\(row.card.ivl)d")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var stateIndicator: some View {
        let color: Color
        switch row.card.cardQueue {
        case .new: color = Theme.Count.new
        case .learning, .dayLearning: color = Theme.Count.learning
        case .review: color = Theme.Count.review
        case .suspended, .buried: color = Theme.textTertiary
        }
        return Circle().fill(color).frame(width: 7, height: 7)
    }
}
