import SwiftUI

/// Edit the raw field values and tags of an Anki note.
/// Saves through DatabaseManager and notifies the caller on dismiss.
struct NoteEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    let initialNote: Note
    let noteType: NoteType
    let onSaved: () -> Void

    @State private var fieldValues: [String]
    @State private var tagsText: String
    @State private var hasChanges = false

    init(initialNote: Note, noteType: NoteType, onSaved: @escaping () -> Void) {
        self.initialNote = initialNote
        self.noteType = noteType
        self.onSaved = onSaved
        let values = initialNote.fieldValues
        let names = noteType.orderedFieldNames
        // Pad to match the number of fields.
        var padded = values
        while padded.count < names.count { padded.append("") }
        _fieldValues = State(initialValue: padded)
        _tagsText = State(initialValue: initialNote.tagList.joined(separator: " "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("フィールド") {
                    ForEach(Array(noteType.orderedFieldNames.enumerated()), id: \.offset) { index, name in
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

                Section("タグ") {
                    TextField("スペース区切り", text: $tagsText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: tagsText) { _, _ in hasChanges = true }
                }

                Section {
                    HStack {
                        Text("ノートタイプ")
                        Spacer()
                        Text(noteType.name)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    HStack {
                        Text("ID")
                        Spacer()
                        Text("\(initialNote.id)")
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                } header: {
                    Text("情報")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("ノートを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                        .tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(!hasChanges)
                        .tint(Theme.accent)
                }
            }
        }
    }

    private func binding(forFieldAt index: Int) -> Binding<String> {
        Binding(
            get: { fieldValues[index] },
            set: { newValue in
                fieldValues[index] = newValue
                hasChanges = true
            }
        )
    }

    private func save() {
        var updated = initialNote
        updated.flds = fieldValues.joined(separator: ankiFieldSeparator)
        updated.sfld = fieldValues.first ?? ""
        updated.tags = tagsText
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
            .joined(separator: " ")
        updated.mod = Int64(Date().timeIntervalSince1970)

        try? DatabaseManager.shared.dbQueue.write { db in
            try updated.update(db)
        }
        Haptics.success(enabled: settings.haptics)
        onSaved()
        dismiss()
    }
}
