import SwiftUI
import Combine
import GRDB

/// Persisted set of collapsed deck ids (re-stored across app launches).
final class DeckCollapseStore {
    static let shared = DeckCollapseStore()
    private let key = "collapsedDeckIds"
    private var ids: Set<Int64> = []

    init() {
        let raw = (UserDefaults.standard.array(forKey: key) as? [NSNumber]) ?? []
        ids = Set(raw.map { $0.int64Value })
    }

    func isCollapsed(_ id: Int64) -> Bool { ids.contains(id) }

    func toggle(_ id: Int64) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(ids.map { NSNumber(value: $0) }, forKey: key)
    }
}

/// Loads decks and their due counts for the deck list.
@MainActor
final class DeckListViewModel: ObservableObject {
    struct Row: Identifiable {
        var deck: Deck
        var counts: DeckCounts        // own counts (this deck only)
        var aggregatedCounts: DeckCounts // including descendants
        var hasChildren: Bool
        var isCollapsed: Bool
        var id: Int64 { deck.id }
        var depth: Int { deck.depth }
    }

    @Published var rows: [Row] = []
    @Published var isEmpty = false

    private let database: DatabaseManager
    private let settings: AppSettings
    private let collapseStore: DeckCollapseStore

    init(database: DatabaseManager = .shared,
         settings: AppSettings,
         collapseStore: DeckCollapseStore = .shared) {
        self.database = database
        self.settings = settings
        self.collapseStore = collapseStore
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
        var hasChildrenMap: [Int64: Bool] = [:]
        for parent in visible {
            let prefix = parent.name + "::"
            var sum = ownCounts[parent.id] ?? DeckCounts()
            var hasChild = false
            for child in visible where child.id != parent.id && child.name.hasPrefix(prefix) {
                sum = sum + (ownCounts[child.id] ?? DeckCounts())
                hasChild = true
            }
            aggregated[parent.id] = sum
            hasChildrenMap[parent.id] = hasChild
        }

        // Sort by name (== hierarchical), then hide rows whose ancestor is collapsed.
        // localizedStandardCompare gives Finder-style ordering (numeric-aware,
        // case-insensitive), which reads better for "Lesson 2" vs "Lesson 10".
        let sorted = visible.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let collapsedNames: Set<String> = Set(sorted
            .filter { collapseStore.isCollapsed($0.id) }
            .map(\.name))
        let filtered = sorted.filter { deck in
            // Hide if any strict ancestor's name is in collapsedNames.
            for ancestor in collapsedNames {
                if deck.name.hasPrefix(ancestor + "::") { return false }
            }
            return true
        }

        rows = filtered.map { d in
            Row(deck: d,
                counts: ownCounts[d.id] ?? DeckCounts(),
                aggregatedCounts: aggregated[d.id] ?? DeckCounts(),
                hasChildren: hasChildrenMap[d.id] ?? false,
                isCollapsed: collapseStore.isCollapsed(d.id))
        }
        isEmpty = visible.isEmpty
    }

    func delete(_ deck: Deck) {
        try? database.deleteDeck(deck)
        reload()
    }

    func toggleCollapse(_ deck: Deck) {
        collapseStore.toggle(deck.id)
        reload()
    }
}

/// Pushed screens reachable from a deck row's context menu / swipe actions.
/// (`NavigationLink` does nothing inside `contextMenu`/`swipeActions`, so
/// those entry points drive navigation through this state instead.)
enum DeckDestination: Hashable {
    case browser(Deck)
    case stats(Deck)
    case customStudy(Deck)
}

struct DeckListView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var importBus: IncomingImportBus
    @StateObject private var viewModel: DeckListViewModel
    @State private var showImport = false
    @State private var showSettings = false
    @State private var deckToDelete: Deck?
    @State private var shareItem: ShareItem?
    @State private var exportError: String?
    @State private var newCardDeck: Deck?
    @State private var deckToEdit: Deck?
    @State private var showNewDeck = false
    @State private var showNewCardPicker = false
    @State private var destination: DeckDestination?

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
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("デッキ")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Haptics.tap(enabled: settings.haptics)
                            showNewDeck = true
                        } label: {
                            Label("デッキを作成", systemImage: "folder.badge.plus")
                        }
                        Button {
                            Haptics.tap(enabled: settings.haptics)
                            showNewCardPicker = true
                        } label: {
                            Label("カードを追加", systemImage: "plus.rectangle.on.rectangle")
                        }
                        .disabled(viewModel.rows.isEmpty)
                        Divider()
                        Button {
                            Haptics.tap(enabled: settings.haptics)
                            showImport = true
                        } label: {
                            Label("ファイルから読み込み", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.body)
                            .foregroundStyle(Theme.accent)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $showImport, onDismiss: { viewModel.reload() }) {
                ImportView(incomingURL: importBus.pendingURL)
                    .onDisappear { importBus.pendingURL = nil }
            }
            .onReceive(importBus.$pendingURL) { url in
                if url != nil { showImport = true }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .sheet(item: $newCardDeck, onDismiss: { viewModel.reload() }) { deck in
                NewNoteView(initialDeck: deck)
            }
            .sheet(isPresented: $showNewDeck, onDismiss: { viewModel.reload() }) {
                NewDeckView()
            }
            .sheet(item: $deckToEdit, onDismiss: { viewModel.reload() }) { deck in
                DeckEditView(deck: deck)
            }
            .navigationDestination(item: $destination) { dest in
                switch dest {
                case .browser(let deck): CardBrowserView(deck: deck)
                case .stats(let deck): DeckStatsView(deck: deck)
                case .customStudy(let deck): CustomStudyView(deck: deck)
                }
            }
            .sheet(isPresented: $showNewCardPicker, onDismiss: { viewModel.reload() }) {
                if let first = viewModel.rows.first?.deck {
                    NewNoteView(initialDeck: first)
                }
            }
            .alert("書き出しに失敗", isPresented: Binding(get: { exportError != nil },
                                                  set: { if !$0 { exportError = nil } })) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
            .confirmationDialog(
                deckToDelete.map { "「\($0.displayName)」を削除しますか？" } ?? "",
                isPresented: Binding(get: { deckToDelete != nil },
                                     set: { if !$0 { deckToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    if let d = deckToDelete {
                        Haptics.error(enabled: settings.haptics)
                        viewModel.delete(d)
                    }
                    deckToDelete = nil
                }
                Button("キャンセル", role: .cancel) { deckToDelete = nil }
            } message: {
                Text("このデッキのカードと学習履歴がすべて削除されます。元に戻せません。")
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
                    DeckRowView(row: row, onToggleCollapse: {
                        Haptics.tap(enabled: settings.haptics)
                        viewModel.toggleCollapse(row.deck)
                    })
                }
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(Theme.separator)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        deckToDelete = row.deck
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        deckToEdit = row.deck
                    } label: {
                        Label("編集", systemImage: "pencil")
                    }
                    .tint(Theme.accent)
                    Button {
                        destination = .browser(row.deck)
                    } label: {
                        Label("ブラウザ", systemImage: "list.bullet.rectangle")
                    }
                    .tint(Theme.Count.review)
                }
                .contextMenu {
                    Button {
                        deckToEdit = row.deck
                    } label: { Label("名前・カテゴリを編集", systemImage: "pencil") }
                    Button {
                        destination = .browser(row.deck)
                    } label: { Label("ブラウザ", systemImage: "list.bullet.rectangle") }
                    Button {
                        destination = .stats(row.deck)
                    } label: { Label("統計", systemImage: "chart.bar") }
                    Button {
                        destination = .customStudy(row.deck)
                    } label: { Label("カスタム学習", systemImage: "slider.horizontal.3") }
                    Button {
                        newCardDeck = row.deck
                    } label: { Label("カードを追加", systemImage: "plus.rectangle.on.rectangle") }
                    Button {
                        exportDeck(row.deck)
                    } label: { Label("apkg を書き出す", systemImage: "square.and.arrow.up") }
                    Divider()
                    Button(role: .destructive) {
                        deckToDelete = row.deck
                    } label: { Label("削除", systemImage: "trash") }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .refreshable {
            viewModel.reload()
        }
    }

    private func exportDeck(_ deck: Deck) {
        Haptics.tap(enabled: settings.haptics)
        do {
            let exporter = ApkgExporter()
            let outURL = try exporter.export(deck: deck,
                                             to: FileManager.default.temporaryDirectory)
            shareItem = ShareItem(url: outURL)
            Haptics.success(enabled: settings.haptics)
        } catch {
            exportError = error.localizedDescription
            Haptics.error(enabled: settings.haptics)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "rectangle.stack")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            VStack(spacing: 6) {
                Text("デッキがありません")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("新しいデッキを作るか、\n.apkg ファイルを読み込んでください。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button {
                    Haptics.tap(enabled: settings.haptics)
                    showNewDeck = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                        Text("デッキを作成")
                    }
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
                Button {
                    Haptics.tap(enabled: settings.haptics)
                    showImport = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("ファイルから読み込む")
                    }
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.surfaceRaised)
                    .foregroundStyle(Theme.textPrimary)
                    .clipShape(Capsule())
                }
                .buttonStyle(ScaleButtonStyle())
            }
            .frame(maxWidth: 280)
            Spacer()
        }
        .padding(40)
    }
}

private struct DeckRowView: View {
    let row: DeckListViewModel.Row
    let onToggleCollapse: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Indentation lines for hierarchy.
            if row.depth > 0 {
                HStack(spacing: 0) {
                    ForEach(0..<row.depth, id: \.self) { _ in
                        Rectangle()
                            .fill(Theme.separator)
                            .frame(width: 1)
                            .padding(.horizontal, 6)
                    }
                }
            }
            // Disclosure chevron — present only on parents.
            Group {
                if row.hasChildren {
                    Button(action: onToggleCollapse) {
                        Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 22, height: 22)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.deck.displayName)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            Spacer(minLength: 8)
            countBadges
        }
        .padding(.vertical, 6)
    }

    private var countBadges: some View {
        let c = row.aggregatedCounts
        return HStack(spacing: 12) {
            countText(c.new, color: Theme.Count.new)
            countText(c.learning, color: Theme.Count.learning)
            countText(c.review, color: Theme.Count.review)
        }
        .font(.subheadline.monospacedDigit())
    }

    private func countText(_ value: Int, color: Color) -> some View {
        Text("\(value)")
            .foregroundStyle(value > 0 ? color : Theme.textTertiary)
            .frame(minWidth: 22, alignment: .trailing)
    }
}
