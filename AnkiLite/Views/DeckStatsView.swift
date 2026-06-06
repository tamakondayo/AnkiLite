import SwiftUI
import Combine
import GRDB

/// Simple per-deck statistics: review counts over the last days and a
/// breakdown of the deck's card states.
@MainActor
final class DeckStatsViewModel: ObservableObject {
    struct DayBar: Identifiable {
        var dayOffset: Int       // 0 = today, -1 = yesterday…
        var count: Int
        var id: Int { dayOffset }
    }

    @Published var dailyReviews: [DayBar] = []
    @Published var totalCards = 0
    @Published var matureCards = 0     // ivl >= 21 days
    @Published var youngCards = 0      // review, ivl < 21
    @Published var newCards = 0

    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    func load(for deck: Deck) {
        let deckIds = collectDeckIds(for: deck)
        guard !deckIds.isEmpty else { return }
        let placeholders = databaseQuestionMarks(count: deckIds.count)
        let args = StatementArguments(deckIds)

        try? database.dbQueue.read { db in
            totalCards = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM card WHERE did IN (\(placeholders))", arguments: args) ?? 0
            newCards = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM card WHERE did IN (\(placeholders)) AND type = 0", arguments: args) ?? 0
            matureCards = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM card WHERE did IN (\(placeholders)) AND type = 2 AND ivl >= 21", arguments: args) ?? 0
            youngCards = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM card WHERE did IN (\(placeholders)) AND type IN (1,2,3) AND ivl < 21", arguments: args) ?? 0

            // Daily review counts for the last 14 days from the review log.
            var bars: [DayBar] = []
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let dayMs: Int64 = 86_400_000
            for offset in stride(from: -13, through: 0, by: 1) {
                let start = nowMs + Int64(offset) * dayMs - dayMs // approximate window
                let end = start + dayMs
                let cidPlaceholders = placeholders
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM reviewLog
                    WHERE id >= ? AND id < ?
                      AND cid IN (SELECT id FROM card WHERE did IN (\(cidPlaceholders)))
                    """, arguments: StatementArguments([start, end]) + args) ?? 0
                bars.append(DayBar(dayOffset: offset, count: count))
            }
            dailyReviews = bars
        }
    }

    private func collectDeckIds(for deck: Deck) -> [Int64] {
        let all = (try? database.allDecks()) ?? []
        let prefix = deck.name + "::"
        return all.filter { $0.id == deck.id || $0.name.hasPrefix(prefix) }.map(\.id)
    }
}

struct DeckStatsView: View {
    let deck: Deck
    @StateObject private var viewModel = DeckStatsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                stateBreakdown
                reviewChart
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("統計")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.load(for: deck) }
    }

    private var stateBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("カードの状態")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            statRow("合計", viewModel.totalCards, color: Theme.textSecondary)
            statRow("新規", viewModel.newCards, color: Theme.Count.new)
            statRow("学習中 (若い)", viewModel.youngCards, color: Theme.Count.learning)
            statRow("習得済み", viewModel.matureCards, color: Theme.Count.review)
        }
        .padding(16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private func statRow(_ title: String, _ value: Int, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(value)").foregroundStyle(Theme.textPrimary).monospacedDigit()
        }
        .font(.subheadline)
    }

    private var reviewChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("直近14日のレビュー数")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            let maxCount = max(viewModel.dailyReviews.map(\.count).max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(viewModel.dailyReviews) { bar in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bar.count > 0 ? Theme.accent : Theme.separator)
                        .frame(height: max(2, CGFloat(bar.count) / CGFloat(maxCount) * 120))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 120)
        }
        .padding(16)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}
