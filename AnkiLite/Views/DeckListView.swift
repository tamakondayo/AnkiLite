import SwiftUI
import Combine
import GRDB

/// Loads decks and their due counts for the deck list.
@MainActor
final class DeckListViewModel: ObservableObject {
    struct Row: Identifiable {
        var deck: Deck
        var counts: DeckCounts        // own counts (this deck only)
        var aggregatedCounts: DeckCounts // including descendants
        var id: Int64 { deck.id }
        var depth: Int { deck.depth }
    }

    @Published var rows: [Row] = []
    @Published var isEmpty = false

    private let database: DatabaseManager
    private let settings: AppSettings

    init(database: DatabaseManager = .shared, settings: AppSettings) {
        self.database = database
        self.settings = settings
    }

    func reload() {
        let crt = (try? database.collectionCreationTime()) ?? 0
        let scheduler = SM2Scheduler(config: settings.schedulerConfig)
        let todayDays = scheduler.today(now: Date(), crt: crt)
        let nowCutoff = Int64(Date().timeIntervalSince1970)

        let decks = (try? database.allDecks()) ?? []
        // Hide the implicit "Default" deck when it is empty.
        let visible = decks.filter { deck in
            if deck.name == "Default" {
                let total = (try? database.counts(forDeckId: deck.id, todayCutoff: nowCutoff, todayDays: todayDays))?.total ?? 0
                let hasCards = (try? database.dbQueue.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM card WHERE did = ?", arguments: [deck.id]) ?? 0
                }) ?? 0
                return total > 0 || hasCards > 0
            }
            return true
        }

        var ownCounts: [Int64: DeckCounts] = [:]
        for deck in visible {
            ownCounts[deck.id] = (try? database.counts(forDeckId: deck.id, todayCutoff: nowCutoff, todayDays: todayDays)) ?? DeckCounts()
        }

        // Aggregate descendant counts into each deck.
        var aggregated: [Int64: DeckCounts] = ownCounts
        for parent in visible {
            let prefix = parent.name + "::"
            var sum = ownCounts[parent.id] ?? DeckCounts()
            for child in visible where child.id != parent.id && child.name.hasPrefix(prefix) {
                sum = sum + (ownCounts[child.id] ?? DeckCounts())
            }
            aggregated[parent.id] = sum
        }

        rows = visible
            .sorted { $0.name < $1.name }
            .map { Row(deck: $0, counts: ownCounts[$0.id] ?? DeckCounts(), aggregatedCounts: aggregated[$0.id] ?? DeckCounts()) }
        isEmpty = rows.isEmpty
    }

    func delete(_ deck: Deck) {
        try? database.deleteDeck(deck)
        reload()
    }
}

struct DeckListView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel: DeckListViewModel
    @State private var showImport = false
    @State private var showSettings = false

    init(settings: AppSettings) {
        _viewModel = StateObject(wrappedValue: DeckListViewModel(settings: settings))
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isEmpty {
                    emptyState
                } else {
                    deckList
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("デッキ")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImport = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .tint(Theme.accent)
                }
            }
            .sheet(isPresented: $showImport, onDismiss: { viewModel.reload() }) {
                ImportView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .onAppear { viewModel.reload() }
    }

    private var deckList: some View {
        List {
            ForEach(viewModel.rows) { row in
                NavigationLink {
                    StudyContainerView(deck: row.deck)
                } label: {
                    DeckRowView(row: row)
                }
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(Theme.separator)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        viewModel.delete(row.deck)
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text("デッキがありません")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("右上の＋から .apkg ファイルを読み込んでください。")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                showImport = true
            } label: {
                Text("ファイルを読み込む")
                    .font(.body.weight(.medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(40)
    }
}

private struct DeckRowView: View {
    let row: DeckListViewModel.Row

    var body: some View {
        HStack(spacing: 12) {
            // Indentation for hierarchy.
            if row.depth > 0 {
                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: 1)
                    .padding(.leading, CGFloat(row.depth - 1) * 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.deck.displayName)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer()
            countBadges
        }
        .padding(.vertical, 4)
    }

    private var countBadges: some View {
        let c = row.aggregatedCounts
        return HStack(spacing: 10) {
            countText(c.new, color: Theme.Count.new)
            countText(c.learning, color: Theme.Count.learning)
            countText(c.review, color: Theme.Count.review)
        }
        .font(.subheadline.monospacedDigit())
    }

    private func countText(_ value: Int, color: Color) -> some View {
        Text("\(value)")
            .foregroundStyle(value > 0 ? color : Theme.textTertiary)
    }
}
