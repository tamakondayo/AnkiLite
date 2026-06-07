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
