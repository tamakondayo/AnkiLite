import SwiftUI
import GRDB
import Combine
import Charts

/// Statistics for one deck (and its descendants).
@MainActor
final class DeckStatsViewModel: ObservableObject {

    struct DailyReview: Identifiable {
        var dayOffset: Int       // 0 = today, -1 = yesterday…
        var reviews: Int
        var pass: Int            // ease >= 2
        var fail: Int            // ease == 1
        var id: Int { dayOffset }
    }

    struct IntervalBucket: Identifiable {
        var label: String
        var rangeStart: Int
        var count: Int
        var id: String { label }
    }

    @Published var dailyReviews: [DailyReview] = []
    @Published var intervalBuckets: [IntervalBucket] = []
    @Published var dueForecast: [DailyReview] = []
    @Published var totalCards = 0
    @Published var newCards = 0
    @Published var youngCards = 0
    @Published var matureCards = 0
    @Published var suspendedCards = 0
    @Published var retention30: Double = 0
    @Published var averageInterval: Double = 0
    @Published var totalReviews = 0

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
                sql: "SELECT COUNT(*) FROM card WHERE did IN (\(placeholders)) AND queue = 0", arguments: args) ?? 0
            matureCards = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM card WHERE did IN (\(placeholders)) AND queue = 2 AND ivl >= 21", arguments: args) ?? 0
            youngCards = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM card WHERE did IN (\(placeholders)) AND queue IN (1,2,3) AND ivl < 21", arguments: args) ?? 0
            suspendedCards = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM card WHERE did IN (\(placeholders)) AND queue = -1", arguments: args) ?? 0
            averageInterval = try Double.fetchOne(db,
                sql: "SELECT AVG(ivl) FROM card WHERE did IN (\(placeholders)) AND ivl > 0", arguments: args) ?? 0

            // 30-day pass rate over the last 30 days of review log entries
            let cutoffMs = Int64(Date().timeIntervalSince1970 * 1000) - Int64(30 * 86400 * 1000)
            let passes = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM reviewLog
                WHERE id >= ? AND ease >= 2 AND type = 1
                  AND cid IN (SELECT id FROM card WHERE did IN (\(placeholders)))
                """, arguments: StatementArguments([cutoffMs]) + args) ?? 0
            let total = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM reviewLog
                WHERE id >= ? AND type = 1
                  AND cid IN (SELECT id FROM card WHERE did IN (\(placeholders)))
                """, arguments: StatementArguments([cutoffMs]) + args) ?? 0
            totalReviews = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM reviewLog
                WHERE cid IN (SELECT id FROM card WHERE did IN (\(placeholders)))
                """, arguments: args) ?? 0
            retention30 = total > 0 ? Double(passes) / Double(total) : 0

            // Daily reviews for the last 30 days, bucketed on local calendar
            // days so a bar always means "that date" (the previous half-day
            // offset straddled two dates).
            var bars: [DailyReview] = []
            let startOfToday = Calendar.current.startOfDay(for: Date())
            let dayMs: Int64 = 86_400_000
            for offset in stride(from: -29, through: 0, by: 1) {
                let start = Int64(startOfToday.timeIntervalSince1970 * 1000) + Int64(offset) * dayMs
                let end = start + dayMs
                let pass = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM reviewLog
                    WHERE id >= ? AND id < ? AND ease >= 2
                      AND cid IN (SELECT id FROM card WHERE did IN (\(placeholders)))
                    """, arguments: StatementArguments([start, end]) + args) ?? 0
                let fail = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM reviewLog
                    WHERE id >= ? AND id < ? AND ease = 1
                      AND cid IN (SELECT id FROM card WHERE did IN (\(placeholders)))
                    """, arguments: StatementArguments([start, end]) + args) ?? 0
                bars.append(DailyReview(dayOffset: offset, reviews: pass + fail, pass: pass, fail: fail))
            }
            dailyReviews = bars

            // Interval distribution buckets (review cards)
            let bucketDefs: [(label: String, lower: Int, upper: Int)] = [
                (String(localized: "1日"), 1, 1),
                (String(localized: "2-7日"), 2, 7),
                (String(localized: "8-30日"), 8, 30),
                (String(localized: "1-3月"), 31, 90),
                (String(localized: "3-6月"), 91, 180),
                (String(localized: "6月-1年"), 181, 365),
                (String(localized: "1年+"), 366, Int.max)
            ]
            var buckets: [IntervalBucket] = []
            for def in bucketDefs {
                let count: Int
                if def.upper == Int.max {
                    count = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM card
                        WHERE did IN (\(placeholders)) AND queue = 2 AND ivl >= ?
                        """, arguments: args + StatementArguments([def.lower])) ?? 0
                } else {
                    count = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM card
                        WHERE did IN (\(placeholders)) AND queue = 2 AND ivl >= ? AND ivl <= ?
                        """, arguments: args + StatementArguments([def.lower, def.upper])) ?? 0
                }
                buckets.append(IntervalBucket(label: def.label, rangeStart: def.lower, count: count))
            }
            intervalBuckets = buckets

            // Due forecast for the next 30 days (rollover-aware "today",
            // matching the scheduler so the bar at 0 equals what's due now).
            let crt = try Int64.fetchOne(db, sql: "SELECT crt FROM collectionMeta WHERE id = 1") ?? 0
            let todayDays = SM2Scheduler().today(now: Date(), crt: crt)
            var forecast: [DailyReview] = []
            for offset in 0..<30 {
                let day = todayDays + offset
                let count = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM card
                    WHERE did IN (\(placeholders)) AND queue = 2 AND due = ?
                    """, arguments: args + StatementArguments([day])) ?? 0
                forecast.append(DailyReview(dayOffset: offset, reviews: count, pass: count, fail: 0))
            }
            dueForecast = forecast
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
            VStack(alignment: .leading, spacing: 16) {
                summaryCards
                statesCard
                reviewsChart
                forecastChart
                intervalDistributionChart
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("統計")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.load(for: deck) }
    }

    // MARK: - Summary

    private var summaryCards: some View {
        HStack(spacing: 10) {
            summaryTile(label: "保持率(30日)",
                        value: String(format: "%.0f%%", viewModel.retention30 * 100),
                        accent: Theme.Count.review)
            summaryTile(label: "平均interval",
                        value: viewModel.averageInterval > 0
                            ? String(localized: "\(Int(round(viewModel.averageInterval)))日")
                            : "—",
                        accent: Theme.accent)
            summaryTile(label: "総レビュー",
                        value: "\(viewModel.totalReviews)",
                        accent: Theme.Count.learning)
        }
    }

    private func summaryTile(label: LocalizedStringKey, value: String, accent: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(accent).frame(height: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    // MARK: - States

    private var statesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("カードの状態")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            stateRow("合計", viewModel.totalCards, color: Theme.textSecondary)
            stateRow("新規", viewModel.newCards, color: Theme.Count.new)
            stateRow("学習中 (若い)", viewModel.youngCards, color: Theme.Count.learning)
            stateRow("習得済み", viewModel.matureCards, color: Theme.Count.review)
            if viewModel.suspendedCards > 0 {
                stateRow("停止中", viewModel.suspendedCards, color: Theme.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private func stateRow(_ title: LocalizedStringKey, _ value: Int, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(value)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: - Reviews chart

    private var reviewsChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("直近30日のレビュー")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Chart(viewModel.dailyReviews) { day in
                BarMark(
                    x: .value("日", day.dayOffset),
                    y: .value("正解", day.pass)
                )
                .foregroundStyle(Theme.Count.review)
                BarMark(
                    x: .value("日", day.dayOffset),
                    y: .value("不正解", day.fail)
                )
                .foregroundStyle(Theme.Answer.again)
            }
            .frame(height: 140)
            .chartXAxis {
                AxisMarks(values: [-29, -20, -10, 0]) { value in
                    AxisValueLabel {
                        if let n = value.as(Int.self) {
                            Text(n == 0 ? String(localized: "今日") : String(localized: "\(n)日"))
                                .font(.caption2)
                        }
                    }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    // MARK: - Forecast chart

    private var forecastChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今後30日の復習予測")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Chart(viewModel.dueForecast) { day in
                BarMark(
                    x: .value("日後", day.dayOffset),
                    y: .value("件数", day.reviews)
                )
                .foregroundStyle(Theme.accent)
            }
            .frame(height: 140)
            .chartXAxis {
                AxisMarks(values: [0, 7, 14, 21, 29]) { value in
                    AxisValueLabel {
                        if let n = value.as(Int.self) {
                            Text(n == 0 ? String(localized: "今日") : "+\(n)")
                                .font(.caption2)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    // MARK: - Interval distribution

    private var intervalDistributionChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("インターバル分布")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Chart(viewModel.intervalBuckets) { bucket in
                BarMark(
                    x: .value("バケツ", bucket.label),
                    y: .value("件数", bucket.count)
                )
                .foregroundStyle(Theme.Count.review)
            }
            .frame(height: 140)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}
