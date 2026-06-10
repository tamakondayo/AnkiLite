import SwiftUI

/// Edit an existing deck: change its display name and/or move it under a
/// different parent ("category"). Sub-decks follow automatically.
struct DeckEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    let deck: Deck

    @State private var displayName: String = ""
    @State private var parent: Deck?            // nil = top level
    @State private var allDecks: [Deck] = []
    @State private var saveError: String?

    // Per-deck daily limits (nil = inherit the global setting).
    @State private var overrideNewLimit = false
    @State private var newPerDay = 20
    @State private var overrideReviewLimit = false
    @State private var reviewsPerDay = 200

    init(deck: Deck) {
        self.deck = deck
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("表示名") {
                    TextField("デッキ名", text: $displayName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Picker("カテゴリ（親デッキ）", selection: $parent) {
                        Text("なし（最上位）").tag(Optional<Deck>.none)
                        ForEach(parentCandidates, id: \.id) { d in
                            Text(d.name).tag(Optional(d))
                        }
                    }
                } header: {
                    Text("カテゴリ")
                } footer: {
                    Text("親を変更すると、サブデッキも一緒に新しい場所に移動します。")
                        .font(.caption)
                }

                if !newFullName.isEmpty && newFullName != deck.name {
                    Section {
                        HStack {
                            Text("変更後の名前")
                            Spacer()
                            Text(newFullName)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section {
                    Toggle("新規カード上限を個別設定", isOn: $overrideNewLimit)
                        .tint(Theme.accent)
                    if overrideNewLimit {
                        Stepper(value: $newPerDay, in: 0...999, step: 5) {
                            HStack {
                                Text("1日の新規カード上限")
                                Spacer()
                                Text(newPerDay == 0 ? String(localized: "無制限") : "\(newPerDay)")
                                    .foregroundStyle(Theme.textSecondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    Toggle("復習上限を個別設定", isOn: $overrideReviewLimit)
                        .tint(Theme.accent)
                    if overrideReviewLimit {
                        Stepper(value: $reviewsPerDay, in: 0...9999, step: 25) {
                            HStack {
                                Text("1日の復習上限")
                                Spacer()
                                Text(reviewsPerDay == 0 ? String(localized: "無制限") : "\(reviewsPerDay)")
                                    .foregroundStyle(Theme.textSecondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                } header: {
                    Text("このデッキの上限")
                } footer: {
                    Text("オフのときは設定画面の全体共通の値が使われます。サブデッキも親と一緒に学習する場合は親デッキの設定が適用されます。")
                        .font(.caption)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("デッキを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }.tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(!hasValidChange)
                        .tint(Theme.accent)
                }
            }
            .onAppear(perform: load)
            .alert("保存に失敗", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    /// All decks that aren't the deck-being-edited or one of its descendants
    /// (those would create a cycle).
    private var parentCandidates: [Deck] {
        let selfPrefix = deck.name + "::"
        return allDecks
            .filter { $0.id != deck.id && !$0.name.hasPrefix(selfPrefix) }
            .sorted { $0.name < $1.name }
    }

    private var newFullName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let parent = parent { return "\(parent.name)::\(trimmed)" }
        return trimmed
    }

    private var editedNewPerDay: Int? { overrideNewLimit ? newPerDay : nil }
    private var editedReviewsPerDay: Int? { overrideReviewLimit ? reviewsPerDay : nil }

    private var limitsChanged: Bool {
        editedNewPerDay != deck.newPerDay || editedReviewsPerDay != deck.reviewsPerDay
    }

    private var hasValidChange: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return newFullName != deck.name || limitsChanged
    }

    private func load() {
        allDecks = (try? DatabaseManager.shared.allDecks()) ?? []
        // Pre-fill from the existing name's last component and its parent.
        displayName = deck.displayName
        if let parentName = deck.parentName {
            parent = allDecks.first { $0.name == parentName }
        } else {
            parent = nil
        }
        if let limit = deck.newPerDay {
            overrideNewLimit = true
            newPerDay = limit
        }
        if let limit = deck.reviewsPerDay {
            overrideReviewLimit = true
            reviewsPerDay = limit
        }
    }

    private func save() {
        let final = newFullName
        guard !final.isEmpty else { return }
        do {
            if final != deck.name {
                try DatabaseManager.shared.renameDeck(deck, to: final)
            }
            if limitsChanged {
                try DatabaseManager.shared.setDeckLimits(deckId: deck.id,
                                                         newPerDay: editedNewPerDay,
                                                         reviewsPerDay: editedReviewsPerDay)
            }
            Haptics.success(enabled: settings.haptics)
            dismiss()
        } catch {
            Haptics.error(enabled: settings.haptics)
            saveError = error.localizedDescription
        }
    }
}
