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
                            Text("\(settings.newCardsPerDay)")
                                .foregroundStyle(Theme.textSecondary)
                                .monospacedDigit()
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
