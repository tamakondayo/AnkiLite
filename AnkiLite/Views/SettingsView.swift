import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("外観") {
                    Picker("テーマ", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }

                Section("学習") {
                    Stepper(value: $settings.rolloverHour, in: 0...23) {
                        HStack {
                            Text("日付の区切り")
                            Spacer()
                            Text("\(settings.rolloverHour):00")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Stepper(value: $settings.newCardsPerDay, in: 0...999, step: 5) {
                        HStack {
                            Text("1日の新規カード上限")
                            Spacer()
                            Text("\(settings.newCardsPerDay)")
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
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
