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
        case all = "すべて"
        case new = "新規"
        case learning = "学習中"
        case review = "復習"
        case suspended = "停止中"
        var id: String { rawValue }
    }

    @Published var rows: [Row] = []
    @Published var query: String = ""
    @Published var stateFilter: StateFilter = .all
    @Published var flagFilter: CardFlag? = nil
    @Published var isLoading = false

    let deck: Deck
    private let database: DatabaseManager
    private let deckIds: [Int64]

    init(deck: Deck, database: DatabaseManager = .shared) {
        self.deck = deck
        self.database = database
        let all = (try? database.allDecks()) ?? []
        let prefix = deck.name + "::"
        self.deckIds = all.filter { $0.id == deck.id || $0.name.hasPrefix(prefix) }.map(\.id)
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
        case .suspended: sql += " AND card.queue = \(CardQueue.suspended.rawValue)"
        }

        if let flag = flagFilter, flag != .none {
            sql += " AND (card.flags & 7) = \(flag.rawValue)"
        }

        if !q.isEmpty {
            sql += " AND (note.flds LIKE ? OR note.sfld LIKE ? OR note.tags LIKE ?)"
            let like = "%\(q)%"
            args.append(contentsOf: [like, like, like])
        }

        sql += " ORDER BY note.sfld ASC LIMIT 500"

        let cards: [Card] = (try? database.dbQueue.read { db in
            try Card.fetchAll(db, sql: sql, arguments: StatementArguments(args) ?? StatementArguments())
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
                            Button(role: .destructive) {
                                viewModel.deleteCard(row.card)
                            } label: { Label("削除", systemImage: "trash") }
                            Menu {
                                ForEach(CardFlag.allCases, id: \.rawValue) { flag in
                                    Button {
                                        viewModel.setFlag(flag, on: row.card)
                                    } label: {
                                        Label(flag.label, systemImage: flag == .none ? "flag.slash" : "flag.fill")
                                    }
                                }
                            } label: { Label("フラグ", systemImage: "flag") }
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
        .searchable(text: $viewModel.query, prompt: "カードを検索")
        .onChange(of: viewModel.query) { _, _ in scheduleReload() }
        .onChange(of: viewModel.stateFilter) { _, _ in viewModel.reload() }
        .onChange(of: viewModel.flagFilter) { _, _ in viewModel.reload() }
        .onAppear { viewModel.reload() }
        .sheet(item: $selectedRow) { row in
            NoteEditView(initialNote: row.note, noteType: row.noteType) {
                viewModel.reload()
            }
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
                    Button(state.rawValue) { viewModel.stateFilter = state }
                }
            } label: {
                filterChip(text: viewModel.stateFilter.rawValue, systemImage: "line.3.horizontal.decrease")
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
