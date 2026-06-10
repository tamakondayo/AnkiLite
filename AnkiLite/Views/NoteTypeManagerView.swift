import SwiftUI
import GRDB

/// Lists all note types, with creation presets and per-type editing.
struct NoteTypeListView: View {
    @EnvironmentObject private var settings: AppSettings

    @State private var noteTypes: [NoteType] = []
    @State private var noteCounts: [Int64: Int] = [:]
    @State private var deleteError: String?

    var body: some View {
        List {
            ForEach(noteTypes, id: \.id) { nt in
                NavigationLink {
                    NoteTypeEditView(noteType: nt, onSaved: load)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(nt.name)
                                .font(.body)
                                .foregroundStyle(Theme.textPrimary)
                            Text(nt.isCloze
                                 ? String(localized: "穴埋め・フィールド\(nt.fields.count)個")
                                 : String(localized: "テンプレート\(nt.templates.count)枚・フィールド\(nt.fields.count)個"))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text(String(localized: "\(noteCounts[nt.id] ?? 0)ノート"))
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .monospacedDigit()
                    }
                }
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(Theme.separator)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(nt)
                    } label: { Label("削除", systemImage: "trash") }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("ノートタイプ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        create(preset: .basic)
                    } label: { Label("基本", systemImage: "rectangle") }
                    Button {
                        create(preset: .basicReversed)
                    } label: { Label("基本（逆向きカード付き）", systemImage: "rectangle.2.swap") }
                    Button {
                        create(preset: .cloze)
                    } label: { Label("穴埋め", systemImage: "rectangle.dashed") }
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear(perform: load)
        .alert("削除できません", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    private func load() {
        let db = DatabaseManager.shared
        noteTypes = (try? db.dbQueue.read { db in
            try NoteType.order(NoteType.Columns.name).fetchAll(db)
        }) ?? []
        noteCounts = (try? db.dbQueue.read { db in
            var counts: [Int64: Int] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT mid, COUNT(*) AS n FROM note GROUP BY mid")
            for row in rows { counts[row["mid"]] = row["n"] }
            return counts
        }) ?? [:]
    }

    private func delete(_ nt: NoteType) {
        let used = noteCounts[nt.id] ?? 0
        guard used == 0 else {
            deleteError = String(localized: "このノートタイプは\(used)個のノートで使われています。先にノートを削除するか、別のタイプに移してください。")
            Haptics.error(enabled: settings.haptics)
            return
        }
        try? DatabaseManager.shared.dbQueue.write { db in
            _ = try nt.delete(db)
        }
        Haptics.success(enabled: settings.haptics)
        load()
    }

    // MARK: - Presets

    private enum Preset { case basic, basicReversed, cloze }

    private static let defaultCSS = """
        .card {
          font-family: -apple-system, sans-serif;
          font-size: 20px;
          text-align: center;
          color: black;
          background-color: white;
        }
        """

    private func create(preset: Preset) {
        let front = String(localized: "表面")
        let back = String(localized: "裏面")
        let text = String(localized: "テキスト")
        let extra = String(localized: "裏面追加")

        let nt: NoteType
        switch preset {
        case .basic:
            nt = NoteType(
                id: 0,
                name: uniqueName(String(localized: "基本")),
                fields: [NoteField(name: front, ord: 0), NoteField(name: back, ord: 1)],
                templates: [CardTemplate(name: String(localized: "カード1"), ord: 0,
                                         qfmt: "{{\(front)}}",
                                         afmt: "{{FrontSide}}<hr id=answer>{{\(back)}}")],
                css: Self.defaultCSS, type: 0)
        case .basicReversed:
            nt = NoteType(
                id: 0,
                name: uniqueName(String(localized: "基本（逆向きカード付き）")),
                fields: [NoteField(name: front, ord: 0), NoteField(name: back, ord: 1)],
                templates: [
                    CardTemplate(name: String(localized: "カード1"), ord: 0,
                                 qfmt: "{{\(front)}}",
                                 afmt: "{{FrontSide}}<hr id=answer>{{\(back)}}"),
                    CardTemplate(name: String(localized: "カード2"), ord: 1,
                                 qfmt: "{{\(back)}}",
                                 afmt: "{{FrontSide}}<hr id=answer>{{\(front)}}")
                ],
                css: Self.defaultCSS, type: 0)
        case .cloze:
            nt = NoteType(
                id: 0,
                name: uniqueName(String(localized: "穴埋め")),
                fields: [NoteField(name: text, ord: 0), NoteField(name: extra, ord: 1)],
                templates: [CardTemplate(name: String(localized: "穴埋め"), ord: 0,
                                         qfmt: "{{cloze:\(text)}}",
                                         afmt: "{{cloze:\(text)}}<br>{{\(extra)}}")],
                css: Self.defaultCSS + "\n.cloze { font-weight: bold; color: blue; }",
                type: 1)
        }

        try? DatabaseManager.shared.dbQueue.write { db in
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let maxId = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM \(NoteType.databaseTableName)") ?? 0
            var created = nt
            created.id = max(nowMs, maxId + 1)
            try created.insert(db)
        }
        Haptics.success(enabled: settings.haptics)
        load()
    }

    private func uniqueName(_ base: String) -> String {
        let existing = Set(noteTypes.map(\.name))
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// Edits one note type: name, fields, templates and CSS.
///
/// Saving migrates existing notes/cards so the data stays consistent:
/// - field add/remove/reorder rewrites each note's `flds` by mapping the
///   original positions to the new ones (new fields become empty)
/// - field renames update `{{Field}}` references in all templates
/// - template removal deletes that ord's cards (and re-numbers the rest);
///   template addition generates a new card for every existing note
struct NoteTypeEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    let noteType: NoteType
    let onSaved: () -> Void

    struct EditableField: Identifiable {
        let id = UUID()
        /// Position in the ORIGINAL ordered field list (nil for new fields).
        var originalIndex: Int?
        var name: String
    }

    struct EditableTemplate: Identifiable {
        let id = UUID()
        /// ord in the ORIGINAL template list (nil for new templates).
        var originalOrd: Int?
        var name: String
        var qfmt: String
        var afmt: String
    }

    @State private var name: String
    @State private var fields: [EditableField]
    @State private var templates: [EditableTemplate]
    @State private var css: String
    @State private var saveError: String?

    init(noteType: NoteType, onSaved: @escaping () -> Void) {
        self.noteType = noteType
        self.onSaved = onSaved
        _name = State(initialValue: noteType.name)
        _css = State(initialValue: noteType.css)

        let orderedFields = noteType.fields.sorted { $0.ord < $1.ord }
        _fields = State(initialValue: orderedFields.enumerated().map {
            EditableField(originalIndex: $0.offset, name: $0.element.name)
        })
        let orderedTemplates = noteType.templates.sorted { $0.ord < $1.ord }
        _templates = State(initialValue: orderedTemplates.map {
            EditableTemplate(originalOrd: $0.ord, name: $0.name, qfmt: $0.qfmt, afmt: $0.afmt)
        })
    }

    var body: some View {
        Form {
            Section("名前") {
                TextField("ノートタイプ名", text: $name)
            }

            Section {
                ForEach($fields) { $field in
                    TextField("フィールド名", text: $field.name)
                }
                .onDelete { offsets in
                    guard fields.count - offsets.count >= 1 else { return }
                    fields.remove(atOffsets: offsets)
                }
                .onMove { from, to in
                    fields.move(fromOffsets: from, toOffset: to)
                }
                Button {
                    fields.append(EditableField(originalIndex: nil,
                                                name: newFieldName()))
                } label: {
                    Label("フィールドを追加", systemImage: "plus")
                        .foregroundStyle(Theme.accent)
                }
            } header: {
                Text("フィールド")
            } footer: {
                Text("フィールドを削除すると、そのフィールドに入っていた内容もすべてのノートから削除されます。")
                    .font(.caption)
            }

            if noteType.isCloze {
                templateSection(index: 0)
            } else {
                ForEach(templates.indices, id: \.self) { index in
                    templateSection(index: index)
                }
                Section {
                    Button {
                        addTemplate()
                    } label: {
                        Label("テンプレートを追加", systemImage: "plus")
                            .foregroundStyle(Theme.accent)
                    }
                } footer: {
                    Text("テンプレートを追加すると、このタイプの既存ノート全部に新しいカードが作られます。")
                        .font(.caption)
                }
            }

            Section("スタイル (CSS)") {
                TextEditor(text: $css)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(Theme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("ノートタイプを編集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("保存") { save() }
                    .disabled(!isValid)
                    .tint(Theme.accent)
            }
        }
        .alert("保存に失敗", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder
    private func templateSection(index: Int) -> some View {
        if templates.indices.contains(index) {
            Section {
                TextField("テンプレート名", text: $templates[index].name)
                VStack(alignment: .leading, spacing: 6) {
                    Text("表面 (質問)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    TextEditor(text: $templates[index].qfmt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .background(Theme.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("裏面 (答え)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    TextEditor(text: $templates[index].afmt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 70)
                        .scrollContentBackground(.hidden)
                        .background(Theme.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if !noteType.isCloze && templates.count > 1 {
                    Button(role: .destructive) {
                        templates.remove(at: index)
                    } label: {
                        Label("このテンプレートを削除", systemImage: "trash")
                    }
                }
            } header: {
                Text(templates[index].name.isEmpty
                     ? String(localized: "テンプレート\(index + 1)")
                     : templates[index].name)
            }
        }
    }

    private var isValid: Bool {
        guard !name.isBlank, !fields.isEmpty, !templates.isEmpty else { return false }
        let names = fields.map { $0.name.trimmingCharacters(in: .whitespaces) }
        return !names.contains(where: \.isEmpty) && Set(names).count == names.count
    }

    private func newFieldName() -> String {
        let base = String(localized: "フィールド")
        let existing = Set(fields.map(\.name))
        var n = fields.count + 1
        while existing.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    private func addTemplate() {
        let frontField = fields.first?.name ?? ""
        let backField = fields.count > 1 ? fields[1].name : frontField
        templates.append(EditableTemplate(
            originalOrd: nil,
            name: String(localized: "カード\(templates.count + 1)"),
            qfmt: "{{\(frontField)}}",
            afmt: "{{FrontSide}}<hr id=answer>{{\(backField)}}"
        ))
    }

    // MARK: - Save (with data migration)

    private func save() {
        do {
            try persist()
            Haptics.success(enabled: settings.haptics)
            onSaved()
            dismiss()
        } catch {
            Haptics.error(enabled: settings.haptics)
            saveError = error.localizedDescription
        }
    }

    private func persist() throws {
        let originalOrderedFields = noteType.fields.sorted { $0.ord < $1.ord }

        // Templates with renamed-field references updated.
        var newTemplates: [CardTemplate] = []
        for (i, t) in templates.enumerated() {
            var qfmt = t.qfmt
            var afmt = t.afmt
            for field in fields {
                guard let idx = field.originalIndex,
                      idx < originalOrderedFields.count else { continue }
                let oldName = originalOrderedFields[idx].name
                let newName = field.name.trimmingCharacters(in: .whitespaces)
                guard oldName != newName else { continue }
                qfmt = Self.renameFieldReferences(in: qfmt, from: oldName, to: newName)
                afmt = Self.renameFieldReferences(in: afmt, from: oldName, to: newName)
            }
            newTemplates.append(CardTemplate(name: t.name, ord: i, qfmt: qfmt, afmt: afmt))
        }

        let newFields = fields.enumerated().map { i, f in
            NoteField(name: f.name.trimmingCharacters(in: .whitespaces), ord: i)
        }

        var updated = noteType
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.fields = newFields
        updated.templates = newTemplates
        updated.css = css

        let fieldMapping = fields.map(\.originalIndex)  // new index → old index?
        let fieldsChanged = fieldMapping != Array(0..<originalOrderedFields.count).map { Optional($0) }
            || fields.count != originalOrderedFields.count

        let originalOrds = noteType.templates.sorted { $0.ord < $1.ord }.map(\.ord)
        let keptOrds = templates.compactMap(\.originalOrd)
        let removedOrds = originalOrds.filter { !keptOrds.contains($0) }
        let nowSec = Int64(Date().timeIntervalSince1970)

        try DatabaseManager.shared.dbQueue.write { db in
            try updated.update(db)

            let notes = try Note.fetchAll(db, sql: "SELECT * FROM note WHERE mid = ?",
                                          arguments: [noteType.id])

            // 1. Rewrite note fields if the layout changed.
            if fieldsChanged {
                for var note in notes {
                    var values = note.fieldValues
                    while values.count < originalOrderedFields.count { values.append("") }
                    let newValues = fieldMapping.map { old in
                        old.flatMap { $0 < values.count ? values[$0] : "" } ?? ""
                    }
                    note.flds = newValues.joined(separator: ankiFieldSeparator)
                    note.sfld = newValues.first ?? ""
                    note.mod = nowSec
                    try note.update(db)
                }
            }

            if !noteType.isCloze {
                // 2. Delete cards of removed templates.
                if !removedOrds.isEmpty {
                    let list = removedOrds.map(String.init).joined(separator: ",")
                    try db.execute(sql: """
                        DELETE FROM \(Card.databaseTableName)
                        WHERE ord IN (\(list))
                          AND nid IN (SELECT id FROM note WHERE mid = ?)
                        """, arguments: [noteType.id])
                }

                // 3. Re-number surviving cards to the new template ords.
                //    Two passes (negative staging) so renumbering can't collide.
                for (newOrd, t) in templates.enumerated() {
                    guard let oldOrd = t.originalOrd, oldOrd != newOrd else { continue }
                    try db.execute(sql: """
                        UPDATE \(Card.databaseTableName) SET ord = ?
                        WHERE ord = ? AND nid IN (SELECT id FROM note WHERE mid = ?)
                        """, arguments: [-(newOrd + 1), oldOrd, noteType.id])
                }
                try db.execute(sql: """
                    UPDATE \(Card.databaseTableName) SET ord = -ord - 1
                    WHERE ord < 0 AND nid IN (SELECT id FROM note WHERE mid = ?)
                    """, arguments: [noteType.id])

                // 4. Generate cards for added templates.
                let addedOrds = templates.enumerated()
                    .filter { $0.element.originalOrd == nil }
                    .map(\.offset)
                if !addedOrds.isEmpty {
                    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                    let maxCardId = try Int64.fetchOne(db,
                        sql: "SELECT MAX(id) FROM \(Card.databaseTableName)") ?? 0
                    var cardId = max(nowMs, maxCardId + 1)
                    for note in notes {
                        // Keep the new card in the same deck as the note's
                        // existing cards (fall back to the first deck).
                        let did = try Int64.fetchOne(db, sql: """
                            SELECT did FROM \(Card.databaseTableName) WHERE nid = ? LIMIT 1
                            """, arguments: [note.id])
                            ?? (try Int64.fetchOne(db, sql: "SELECT id FROM \(Deck.databaseTableName) LIMIT 1") ?? 1)
                        for ord in addedOrds {
                            let card = Card(id: cardId, nid: note.id, did: did, ord: ord,
                                            mod: nowSec,
                                            type: CardType.new.rawValue,
                                            queue: CardQueue.new.rawValue,
                                            due: cardId)
                            try card.insert(db)
                            cardId += 1
                        }
                    }
                }
            }
        }
    }

    /// Replaces `{{Old}}`, `{{#Old}}`, `{{/Old}}`, `{{^Old}}` and
    /// `{{modifier:Old}}` references with the new field name.
    static func renameFieldReferences(in template: String,
                                      from oldName: String,
                                      to newName: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: oldName)
        let pattern = "(\\{\\{[#/^]?(?:[A-Za-z]+:)*)\\s*\(escaped)\\s*(\\}\\})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        return regex.stringByReplacingMatches(
            in: template, range: range,
            withTemplate: "$1\(NSRegularExpression.escapedTemplate(for: newName))$2")
    }
}
