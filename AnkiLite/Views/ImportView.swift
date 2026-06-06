import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Handles selecting and importing an `.apkg` file.
@MainActor
final class ImportViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case importing(progress: Double, message: String)
        case done
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var mode: ImportMode = .overwrite

    func importFile(at pickedURL: URL) {
        phase = .importing(progress: 0, message: "準備中…")

        Task.detached(priority: .userInitiated) { [mode] in
            do {
                let localURL = try FileHelper.copyToTemporary(pickedURL)

                // Basic storage check: require ~3× the package size free.
                let size = FileHelper.fileSize(at: localURL)
                if FileHelper.availableStorage() < size * 3 {
                    await MainActor.run { self.phase = .failed(ImportError.insufficientStorage.localizedDescription) }
                    return
                }

                let importer = ApkgImporter()
                try importer.importPackage(from: localURL, mode: mode) { progress in
                    Task { @MainActor in
                        self.phase = .importing(progress: progress.fraction, message: progress.message)
                    }
                }
                await MainActor.run { self.phase = .done }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }
}

struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ImportViewModel()
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("インポート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                        .tint(Theme.textSecondary)
                }
            }
            .fileImporter(isPresented: $showFilePicker,
                          allowedContentTypes: Self.allowedTypes,
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first { viewModel.importFile(at: url) }
                case .failure(let error):
                    viewModel.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private static var allowedTypes: [UTType] {
        // .apkg is a zip; allow both a custom type and generic data/zip.
        var types: [UTType] = []
        if let apkg = UTType(filenameExtension: "apkg") { types.append(apkg) }
        types.append(contentsOf: [.zip, .data])
        return types
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .idle:
            idleContent
        case .importing(let progress, let message):
            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .tint(Theme.accent)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .done:
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.Count.review)
                Text("インポートが完了しました")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Button("完了") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.Answer.again)
                Text("インポートに失敗しました")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("やり直す") { viewModel.phase = .idle }
                    .tint(Theme.accent)
            }
        }
    }

    private var idleContent: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                Text(".apkg ファイルを読み込む")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text("Anki で書き出したデッキファイルを選択してください。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Picker("再インポート時", selection: $viewModel.mode) {
                Text("上書き").tag(ImportMode.overwrite)
                Text("マージ").tag(ImportMode.merge)
            }
            .pickerStyle(.segmented)

            Button {
                showFilePicker = true
            } label: {
                Text("ファイルを選択")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }
}
