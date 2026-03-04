import Foundation

final class LocalTranscriber: TranscriptionProvider {
    let providerType: TranscriptionProviderType = .local

    func transcribe(audio: RecordedAudio) async throws -> TranscriptionResult {
        let manager = LocalModelManager.shared

        switch manager.modelState {
        case .notDownloaded:
            throw TranscriptionError.modelNotReady("No local model set up. Open Settings to set one up.")
        case .downloading:
            throw TranscriptionError.modelNotReady("Model is still being set up. Please wait.")
        case .compiling:
            throw TranscriptionError.modelNotReady("Model is compiling for your hardware. Please wait.")
        case .error(let message):
            throw TranscriptionError.modelNotReady(message)
        case .warming, .ready:
            // warming = preload in progress, ensurePipelineLoaded will wait for it
            break
        }

        let text = try await manager.transcribe(
            audioData: audio.data,
            filename: audio.filename
        )

        return TranscriptionResult(text: text, wordsUsed: nil, wordsRemaining: nil)
    }
}
