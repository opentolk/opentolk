import Foundation
import WhisperKit

enum LocalModelState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case compiling
    case warming
    case ready
    case error(String)
}

struct LocalModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let sizeDescription: String
}

@Observable
final class LocalModelManager {
    static let shared = LocalModelManager()

    var modelState: LocalModelState = .notDownloaded
    var downloadProgress: Double = 0

    static let availableModels: [LocalModel] = [
        LocalModel(id: "tiny", displayName: "Tiny", sizeDescription: "~30 MB  -  Fastest, lower accuracy"),
        LocalModel(id: "base", displayName: "Base", sizeDescription: "~140 MB  -  Fast, decent accuracy"),
        LocalModel(id: "small", displayName: "Small", sizeDescription: "~460 MB  -  Good balance"),
        LocalModel(id: "large-v3_turbo", displayName: "Large V3 Turbo (Recommended)", sizeDescription: "~1 GB  -  Best speed/accuracy ratio"),
        LocalModel(id: "large-v3", displayName: "Large V3", sizeDescription: "~3 GB  -  Best accuracy"),
    ]

    private var whisperPipeline: WhisperKit?
    private var loadedModelName: String?
    private var downloadTask: Task<Void, Never>?

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenTolk/Models", isDirectory: true)
    }

    private func modelPath(for modelName: String) -> URL {
        modelsDirectory.appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(modelName)")
    }

    private var preloadTask: Task<Void, Never>?

    private init() {
        checkExistingModel()
    }

    // MARK: - Public API

    func checkExistingModel() {
        if whisperPipeline != nil {
            modelState = .ready
            return
        }
        let modelName = Config.shared.localModel
        let modelDir = modelPath(for: modelName)
        if FileManager.default.fileExists(atPath: modelDir.path) {
            modelState = .ready
        } else {
            modelState = .notDownloaded
        }
    }

    /// Call on app launch — silently loads the pipeline in the background
    /// so it's ready by the time the user wants to dictate.
    func preloadIfNeeded() {
        guard Config.shared.selectedProvider == .local else { return }
        let modelName = Config.shared.localModel
        guard whisperPipeline == nil || loadedModelName != modelName else { return }
        let modelDir = modelPath(for: modelName)
        guard FileManager.default.fileExists(atPath: modelDir.path) else { return }

        preloadTask?.cancel()
        preloadTask = Task {
            await MainActor.run { modelState = .warming }
            do {
                let pipeline = try await WhisperKit(
                    WhisperKitConfig(
                        modelFolder: modelDir.path,
                        verbose: false,
                        load: true,
                        download: false
                    )
                )
                self.whisperPipeline = pipeline
                self.loadedModelName = modelName
                await MainActor.run { modelState = .ready }
            } catch {
                if Task.isCancelled { return }
                // Preload failed silently — will retry on first transcription
                await MainActor.run { modelState = .ready }
            }
        }
    }

    /// One-click: download (if needed) → compile → load → ready
    func setupModel() {
        let modelName = Config.shared.localModel
        downloadTask?.cancel()

        downloadTask = Task { @MainActor in
            let modelDir = modelPath(for: modelName)
            let alreadyDownloaded = FileManager.default.fileExists(atPath: modelDir.path)

            // Step 1: Download if needed
            if !alreadyDownloaded {
                modelState = .downloading(progress: 0)
                downloadProgress = 0

                do {
                    try FileManager.default.createDirectory(
                        at: modelsDirectory,
                        withIntermediateDirectories: true
                    )

                    let _ = try await WhisperKit.download(
                        variant: modelName,
                        downloadBase: modelsDirectory,
                        useBackgroundSession: false
                    ) { progress in
                        Task { @MainActor in
                            self.downloadProgress = progress.fractionCompleted
                            self.modelState = .downloading(progress: progress.fractionCompleted)
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                    modelState = .error("Download failed: \(error.localizedDescription)")
                    return
                }
            }

            if Task.isCancelled { return }

            // Step 2: Compile & load
            modelState = .compiling

            do {
                let pipeline = try await WhisperKit(
                    WhisperKitConfig(
                        modelFolder: modelDir.path,
                        verbose: false,
                        load: true,
                        download: false
                    )
                )
                self.whisperPipeline = pipeline
                self.loadedModelName = modelName
                modelState = .ready
            } catch {
                if Task.isCancelled { return }
                modelState = .error("Failed to load model: \(error.localizedDescription)")
            }
        }
    }

    func cancelSetup() {
        downloadTask?.cancel()
        downloadTask = nil
        whisperPipeline = nil
        loadedModelName = nil
        let modelDir = modelPath(for: Config.shared.localModel)
        if FileManager.default.fileExists(atPath: modelDir.path) {
            // Files downloaded but compile cancelled — stay at notDownloaded so user can retry full setup
        }
        modelState = .notDownloaded
    }

    func ensurePipelineLoaded() async throws {
        let modelName = Config.shared.localModel
        if whisperPipeline != nil && loadedModelName == modelName {
            return
        }
        // If not loaded, trigger setup and wait
        let modelDir = modelPath(for: modelName)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw TranscriptionError.modelNotReady("No local model set up. Open Settings to set one up.")
        }
        await MainActor.run { modelState = .compiling }
        let pipeline = try await WhisperKit(
            WhisperKitConfig(
                modelFolder: modelDir.path,
                verbose: false,
                load: true,
                download: false
            )
        )
        self.whisperPipeline = pipeline
        self.loadedModelName = modelName
        await MainActor.run { modelState = .ready }
    }

    func transcribe(audioData: Data, filename: String) async throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + "-" + filename)
        try audioData.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try await ensurePipelineLoaded()

        guard let pipeline = whisperPipeline else {
            throw TranscriptionError.notAvailable
        }

        let language = Config.shared.effectiveLanguage
        let options = DecodingOptions(
            language: language,
            wordTimestamps: false
        )

        let results = try await pipeline.transcribe(
            audioPath: tempFile.path,
            decodeOptions: options
        )

        let text = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    func deleteModel() {
        whisperPipeline = nil
        loadedModelName = nil

        let modelName = Config.shared.localModel
        let modelDir = modelPath(for: modelName)
        try? FileManager.default.removeItem(at: modelDir)

        modelState = .notDownloaded
    }

    func modelSelectionChanged() {
        whisperPipeline = nil
        loadedModelName = nil
        checkExistingModel()
    }
}
