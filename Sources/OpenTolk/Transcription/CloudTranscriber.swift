import Foundation

final class CloudTranscriber: TranscriptionProvider {
    let providerType: TranscriptionProviderType = .cloud
    private static let baseURL = Config.apiBaseURL

    func transcribe(audio: RecordedAudio) async throws -> TranscriptionResult {
        guard AuthManager.shared.isSignedIn else {
            throw TranscriptionError.signInRequired
        }

        let url = URL(string: "\(Self.baseURL)/transcribe")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fields: [(name: String, value: String)] = [
            ("model", Config.shared.groqModel),
            ("language", Config.shared.effectiveLanguage),
        ]

        let body = Data.buildMultipartBody(
            boundary: boundary,
            audioData: audio.data,
            fields: fields,
            filename: audio.filename,
            contentType: audio.contentType
        )
        request.httpBody = body

        let (data, response) = try await AuthManager.shared.authenticatedRequest(request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.noData
        }

        if response.statusCode == 429 {
            let wordsUsed = json["words_used"] as? Int ?? 0
            throw TranscriptionError.freeTierLimitReached(wordsUsed: wordsUsed)
        }

        if response.statusCode != 200 {
            let message = json["error"] as? String ?? "Unknown error"
            throw TranscriptionError.apiError(statusCode: response.statusCode, message: message)
        }

        let text = json["text"] as? String ?? ""
        let wordsUsed = json["words_used"] as? Int
        let wordsRemaining = json["words_remaining"] as? Int

        return TranscriptionResult(
            text: text,
            wordsUsed: wordsUsed,
            wordsRemaining: wordsRemaining
        )
    }

}
