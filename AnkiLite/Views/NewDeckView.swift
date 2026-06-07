import SwiftUI
import GRDB

/// Create a brand-new (empty) deck.
///
/// Names use `::` for hierarchy, e.g. "言語::英語::TOEIC".
struct NewDeckView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    @State private var name: String = ""
    @State private var parent: Deck?
    @State private var existingDecks: [Deck] = []
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("デッキ名") {
                    TextField("例: 英単語", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !existingDecks.isEmpty {
                    Section {
                        Picker("親デッキ", selection: $parent) {
                            Text("なし（最上位）").tag(Optional<Deck>.none)
                            ForEach(existingDecks, id: \.id) { deck in
                                Text(deck.name).tag(Optional(deck))
                            }
                        }
                    } header: {
                        Text("階層")
                    } footer: {
                        Text("親デッキを選ぶと「親::子」の形でネストされます。")
                            .font(.caption)
                    }
                }

                if !fullName.isBlank {
                    Section {
                        HStack {
                            Text("作成される名前")
                            Spacer()
                            Text(fullName)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("デッキを作成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }.tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("作成") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .tint(Theme.accent)
                }
            }
            .onAppear(perform: loadDecks)
            .alert("作成に失敗", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var fullName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let parent = parent { return "\(parent.name)::\(trimmed)" }
        return trimmed
    }

    private func loadDecks() {
        existingDecks = (try? DatabaseManager.shared.allDecks()) ?? []
    }

    private func save() {
        let finalName = fullName
        guard !finalName.isEmpty else { return }

        // Reject duplicates.
        if existingDecks.contains(where: { $0.name == finalName }) {
            saveError = "同じ名前のデッキが既にあります。"
            return
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let deck = Deck(id: nowMs, name: finalName, mod: nowMs / 1000)

        do {
            try DatabaseManager.shared.dbQueue.write { db in
                try deck.insert(db)
            }
            Haptics.success(enabled: settings.haptics)
            dismiss()
        } catch {
            Haptics.error(enabled: settings.haptics)
            saveError = error.localizedDescription
        }
    }
}
