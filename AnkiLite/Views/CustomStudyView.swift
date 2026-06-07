import SwiftUI
import GRDB

/// "Custom Study": one-off study session over a filtered subset of cards
/// (by tag, flag, overdue-only, or specific state).
struct CustomStudyView: View {
    let deck: Deck
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var includeNew = true
    @State private var includeReview = true
    @State private var includeLearning = true
    @State private var onlyOverdue = false
    @State private var selectedFlag: CardFlag? = nil
    @State private var selectedTags: Set<String> = []
    @State private var availableTags: [String] = []
    @State private var maxCards: Int = 50
    @State private var session: StudySession?

    var body: some View {
        Form {
            Section("対象カード") {
                Toggle("新規", isOn: $includeNew)
                Toggle("学習中", isOn: $includeLearning)
                Toggle("復習", isOn: $includeReview)
            }

            Section("条件") {
                Toggle("期限超過のみ", isOn: $onlyOverdue)
                    .disabled(!includeReview)
                NavigationLink {
                    FlagPickerView(selection: $selectedFlag)
                } label: {
                    HStack {
                        Text("フラグ")
                        Spacer()
                        if let f = selectedFlag {
                            HStack(spacing: 4) {
                                Image(systemName: f == .none ? "flag.slash" : "flag.fill")
                                    .foregroundStyle(Color(hex: f.hex))
                                Text(f.label).foregroundStyle(Theme.textSecondary)
                            }
                        } else {
                            Text("すべて").foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                if !availableTags.isEmpty {
                    NavigationLink {
                        TagPickerView(selection: $selectedTags, allTags: availableTags)
                    } label: {
                        HStack {
                            Text("タグ")
                            Spacer()
                            Text(selectedTags.isEmpty ? "指定なし" : "\(selectedTags.count)個")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }

            Section {
                Stepper(value: $maxCards, in: 5...500, step: 5) {
                    HStack {
                        Text("最大カード数")
                        Spacer()
                        Text("\(maxCards)")
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                }
            }

            Section {
                NavigationLink {
                    if let session = session {
                        StudyView(session: session)
                    } else {
                        Text("カードがありません")
                            .foregroundStyle(Theme.textSecondary)
                    }
                } label: {
                    Text("学習を開始")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(Theme.accent)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    buildSession()
                })
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("カスタム学習")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadTags)
    }

    private func loadTags() {
        let allDecks = (try? DatabaseManager.shared.allDecks()) ?? []
        let prefix = deck.name + "::"
        let deckIds = allDecks.filter { $0.id == deck.id || $0.name.hasPrefix(prefix) }.map(\.id)
        guard !deckIds.isEmpty else { return }
        let placeholders = databaseQuestionMarks(count: deckIds.count)
        let args = StatementArguments(deckIds)
        let rawTags: [String] = (try? DatabaseManager.shared.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT tags FROM note
                WHERE id IN (SELECT nid FROM card WHERE did IN (\(placeholders)))
                """, arguments: args)
        }) ?? []
        var unique = Set<String>()
        for line in rawTags {
            for tag in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                unique.insert(String(tag))
            }
        }
        availableTags = unique.sorted()
    }

    private func buildSession() {
        let filter = CustomStudyFilter(
            includeNew: includeNew,
            includeLearning: includeLearning,
            includeReview: includeReview,
            onlyOverdue: onlyOverdue,
            flag: selectedFlag,
            tags: selectedTags,
            maxCards: maxCards
        )
        session = try? StudySession(
            deck: deck,
            scheduler: settings.makeScheduler(),
            newCardLimit: settings.newCardsPerDay,
            reviewLimit: settings.reviewsPerDay,
            customFilter: filter
        )
    }
}

struct FlagPickerView: View {
    @Binding var selection: CardFlag?

    var body: some View {
        List {
            Button {
                selection = nil
            } label: {
                HStack {
                    Text("すべて")
                    Spacer()
                    if selection == nil { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                }
            }
            ForEach(CardFlag.allCases, id: \.rawValue) { flag in
                Button {
                    selection = flag
                } label: {
                    HStack {
                        Image(systemName: flag == .none ? "flag.slash" : "flag.fill")
                            .foregroundStyle(Color(hex: flag.hex))
                        Text(flag.label)
                        Spacer()
                        if selection == flag {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("フラグ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TagPickerView: View {
    @Binding var selection: Set<String>
    let allTags: [String]

    var body: some View {
        List {
            ForEach(allTags, id: \.self) { tag in
                Button {
                    if selection.contains(tag) { selection.remove(tag) }
                    else { selection.insert(tag) }
                } label: {
                    HStack {
                        Text(tag)
                        Spacer()
                        if selection.contains(tag) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("タグ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("解除") { selection.removeAll() }
                    .disabled(selection.isEmpty)
            }
        }
    }
}
