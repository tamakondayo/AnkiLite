import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var manualBackupMessage: String?
    @State private var shareItem: ShareItem?

    private var lastBackupLabel: String {
        guard let date = BackupManager.shared.lastBackupDate else {
            return String(localized: "未実行")
        }
        let f = RelativeDateTimeFormatter()
        f.locale = settings.locale
        return f.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("外観") {
                    Picker("言語", selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    Picker("テーマ", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    HStack {
                        Text("カードの文字サイズ")
                        Spacer()
                        Text("\(settings.cardFontSize)pt")
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { Double(settings.cardFontSize) },
                        set: { settings.cardFontSize = Int($0) }
                    ), in: 14...36, step: 1) {
                        Text("文字サイズ")
                    } minimumValueLabel: {
                        Text("A").font(.caption)
                    } maximumValueLabel: {
                        Text("A").font(.title3)
                    }
                    .tint(Theme.accent)
                    HStack {
                        Text("プレビュー")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("見本テキスト Aa あ")
                            .font(.system(size: CGFloat(settings.cardFontSize)))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                }

                Section("操作") {
                    Toggle(isOn: $settings.haptics) {
                        Text("触覚フィードバック")
                    }
                    .tint(Theme.accent)
                }

                Section("カード") {
                    NavigationLink {
                        NoteTypeListView()
                    } label: {
                        Label("ノートタイプを管理", systemImage: "square.text.square")
                    }
                }

                Section {
                    Picker("スケジューラ", selection: $settings.schedulerKind) {
                        ForEach(SchedulerKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    Text(settings.schedulerKind.subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if settings.schedulerKind == .fsrs {
                        HStack {
                            Text("目標保持率")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.desiredRetention * 100))
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.desiredRetention, in: 0.70...0.97, step: 0.01)
                            .tint(Theme.accent)
                    }
                } header: {
                    Text("学習アルゴリズム")
                } footer: {
                    Text("既存カードはそのままで、次のレビューから選んだ方式が適用されます。FSRS は初回レビュー後にメモリ状態を蓄積するため、最初は SM-2 と挙動が似ます。")
                        .font(.caption)
                }

                Section("学習") {
                    Stepper(value: $settings.rolloverHour, in: 0...23) {
                        HStack {
                            Text("日付の区切り")
                            Spacer()
                            Text(String(format: "%02d:00", settings.rolloverHour))
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $settings.newCardsPerDay, in: 0...999, step: 5) {
                        HStack {
                            Text("1日の新規カード上限")
                            Spacer()
                            Text(settings.newCardsPerDay == 0 ? "無制限" : "\(settings.newCardsPerDay)")
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
                        }
                    }
                    Stepper(value: $settings.reviewsPerDay, in: 0...9999, step: 25) {
                        HStack {
                            Text("1日の復習上限")
                            Spacer()
                            Text(settings.reviewsPerDay == 0 ? "無制限" : "\(settings.reviewsPerDay)")
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
                        }
                    }
                }

                Section {
                    Toggle("iCloud Drive にバックアップ", isOn: $settings.iCloudBackup)
                        .tint(Theme.accent)
                    HStack {
                        Text("最終バックアップ")
                        Spacer()
                        Text(lastBackupLabel)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Button {
                        runManualBackup()
                    } label: {
                        Label("今すぐバックアップ", systemImage: "arrow.up.doc")
                            .foregroundStyle(Theme.accent)
                    }
                    NavigationLink {
                        BackupListView(shareItem: $shareItem)
                    } label: {
                        Label("バックアップ一覧", systemImage: "clock.arrow.circlepath")
                    }
                } header: {
                    Text("バックアップ")
                } footer: {
                    Text("毎日 1 回、コレクション (SQLite + メディア) を Documents/Backups にバックアップします。最大 7 世代を保持。iCloud は有効化された Apple Developer アカウントが必要です。")
                        .font(.caption)
                }

                Section("情報") {
                    HStack {
                        Text("アプリ名")
                        Spacer()
                        Text("AnkiLite")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    HStack {
                        Text("バージョン")
                        Spacer()
                        Text(Bundle.main.appVersionString)
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                        .tint(Theme.textSecondary)
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .alert("バックアップ", isPresented: Binding(
                get: { manualBackupMessage != nil },
                set: { if !$0 { manualBackupMessage = nil } }
            )) {
                Button("OK") { manualBackupMessage = nil }
            } message: {
                Text(manualBackupMessage ?? "")
            }
        }
    }

    private func runManualBackup() {
        Haptics.tap(enabled: settings.haptics)
        do {
            let url = try BackupManager.shared.performBackup(iCloudEnabled: settings.iCloudBackup)
            Haptics.success(enabled: settings.haptics)
            manualBackupMessage = "保存しました: \(url.lastPathComponent)"
        } catch {
            Haptics.error(enabled: settings.haptics)
            manualBackupMessage = "失敗: \(error.localizedDescription)"
        }
    }
}

struct BackupListView: View {
    @Binding var shareItem: ShareItem?
    @State private var entries: [BackupEntry] = []

    struct BackupEntry: Identifiable {
        let url: URL
        let createdAt: Date
        let size: Int64
        var id: String { url.path }
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Text("バックアップがありません")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .listRowBackground(Theme.surface)
            } else {
                ForEach(entries) { entry in
                    Button {
                        shareItem = ShareItem(url: entry.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.url.lastPathComponent)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                            HStack {
                                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .listRowBackground(Theme.surface)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            try? FileManager.default.removeItem(at: entry.url)
                            load()
                        } label: { Label("削除", systemImage: "trash") }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("バックアップ一覧")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        let fm = FileManager.default
        entries = BackupManager.shared.listBackups().map { url in
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let date = (attrs?[.creationDate] as? Date) ?? Date()
            let size = (attrs?[.size] as? Int64) ?? 0
            return BackupEntry(url: url, createdAt: date, size: size)
        }
    }
}

extension Bundle {
    var appVersionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
