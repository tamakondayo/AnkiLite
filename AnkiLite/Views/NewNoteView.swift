import SwiftUI
import GRDB

/// Create a brand-new note (and its derived cards) for an existing note type.
///
/// For Basic note types we generate one card per template (the standard rule).
/// For Cloze note types we scan the field text for `{{cN::...}}` markers and
/// create one card per distinct cloze number, mirroring Anki's behaviour.
struct NewNoteView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    let initialDeck: Deck

    @State private var deck: Deck
    @State private var availableDecks: [Deck] = []
    @State private var noteType: NoteType?
    @State private var availableNoteTypes: [NoteType] = []
    @State private var fieldValues: [String] = []
    @State private var tagsText: String = ""
    @State private var saveError: String?

    init(initialDeck: Deck) {
        self.initialDeck = initialDeck
        _deck = State(initialValue: initialDeck)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("デッキ") {
                    Picker("デッキ", selection: $deck) {
                        ForEach(availableDecks, id: \.id) { d in
                            Text(d.name).tag(d)
                        }
                    }
                }

                Section("ノートタイプ") {
                    Picker("ノートタイプ", selection: Binding(
                        get: { noteType ?? availableNoteTypes.first },
                        set: { newValue in
                            if newValue?.id != noteType?.id {
                                noteType = newValue
                                resetFields()
                            }
                        }
                    )) {
                        ForEach(availableNoteTypes, id: \.id) { nt in
                            Text(nt.name).tag(Optional(nt))
                        }
                    }
                }

                if let nt = noteType {
                    Section("フィールド") {
                        ForEach(Array(nt.orderedFieldNames.enumerated()), id: \.offset) { index, name in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.textSecondary)
                                TextEditor(text: binding(forFieldAt: index))
                                    .font(.body)
                                    .frame(minHeight: 80)
                                    .scrollContentBackground(.hidden)
                                    .background(Theme.surfaceRaised)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    if nt.isCloze {
                        Section {
                            Text("Cloze ヒント: `Hello {{c1::world}}` のように囲むとそこが穴埋めになります。")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    Section("タグ") {
                        TextField("スペース区切り", text: $tagsText, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("カードを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }.tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("追加") { save() }
                        .disabled(noteType == nil || fieldValues.allSatisfy { $0.isBlank })
                        .tint(Theme.accent)
                }
            }
            .onAppear(perform: loadOptions)
            .alert("保存に失敗", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func binding(forFieldAt index: Int) -> Binding<String> {
        Binding(
            get: { index < fieldValues.count ? fieldValues[index] : "" },
            set: { newValue in
                while fieldValues.count <= index { fieldValues.append("") }
                fieldValues[index] = newValue
            }
        )
    }

    private func loadOptions() {
        availableDecks = (try? DatabaseManager.shared.allDecks()) ?? []
        availableNoteTypes = (try? DatabaseManager.shared.dbQueue.read { db in
            try NoteType.order(NoteType.Columns.name).fetchAll(db)
        }) ?? []
        if noteType == nil { noteType = availableNoteTypes.first }
        resetFields()
    }

    private func resetFields() {
        let count = noteType?.orderedFieldNames.count ?? 0
        fieldValues = Array(repeating: "", count: count)
    }

    private func save() {
        guard let nt = noteType else { return }
        do {
            try addNote(noteType: nt, deck: deck, fields: fieldValues, tags: tagsText)
            Haptics.success(enabled: settings.haptics)
            dismiss()
        } catch {
            Haptics.error(enabled: settings.haptics)
            saveError = error.localizedDescription
        }
    }

    private func addNote(noteType: NoteType, deck: Deck, fields: [String], tags: String) throws {
        let flds = fields.joined(separator: ankiFieldSeparator)
        let sfld = fields.first ?? ""
        let normalizedTags = tags
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
            .joined(separator: " ")
        let nowSec = Int64(Date().timeIntervalSince1970)

        // Determine the ords for the cards to generate.
        let ords: [Int]
        if noteType.isCloze {
            let numbers = clozeNumbers(in: flds)
            ords = numbers.isEmpty ? [0] : numbers.sorted().map { $0 - 1 }
        } else {
            ords = noteType.templates.map(\.ord).sorted()
        }

        try DatabaseManager.shared.dbQueue.write { db in
            // Allocate ids that are guaranteed not to collide with existing ones,
            // even when the user taps "Add" multiple times within the same ms.
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let maxNoteId = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM \(Note.databaseTableName)") ?? 0
            let maxCardId = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM \(Card.databaseTableName)") ?? 0
            let noteId = max(nowMs, maxNoteId + 1)
            var cardId = max(nowMs, maxCardId + 1)

            let note = Note(
                id: noteId,
                guid: UUID().uuidString,
                mid: noteType.id,
                mod: nowSec,
                tags: normalizedTags,
                flds: flds,
                sfld: sfld
            )
            try note.insert(db)

            for ord in ords {
                let card = Card(
                    id: cardId,
                    nid: note.id,
                    did: deck.id,
                    ord: ord,
                    mod: nowSec,
                    type: CardType.new.rawValue,
                    queue: CardQueue.new.rawValue,
                    due: Int64(nowMs),
                    ivl: 0,
                    factor: 2500
                )
                try card.insert(db)
                cardId += 1
            }
        }
    }

    /// All distinct cloze numbers (1-based) in the given fields text.
    private func clozeNumbers(in text: String) -> Set<Int> {
        guard let regex = try? NSRegularExpression(pattern: "\\{\\{c(\\d+)::") else { return [] }
        let ns = text as NSString
        var numbers = Set<Int>()
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let n = Int(ns.substring(with: m.range(at: 1))) { numbers.insert(n) }
        }
        return numbers
    }
}
