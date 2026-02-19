import Foundation

// MARK: - Types

struct GmailMessageSummary {
    let id: String
    let threadId: String
    let from: String
    let subject: String
    let snippet: String
    let date: String
    let isUnread: Bool
}

struct GmailMessage {
    let id: String
    let threadId: String
    let from: String
    let to: String
    let subject: String
    let body: String
    let date: String
    let isUnread: Bool
}

// MARK: - API Client

enum GmailAPIClient {
    private static let baseURL = "https://gmail.googleapis.com/gmail/v1/users/me"

    // MARK: - List Messages

    /// Lists recent messages, optionally filtered by query (e.g. "is:unread", "from:sarah").
    static func listMessages(query: String? = nil, maxResults: Int = 10) async throws -> [GmailMessageSummary] {
        let token = try await GmailAuthManager.shared.getAccessToken()

        var urlString = "\(baseURL)/messages?maxResults=\(maxResults)"
        if let query, !query.isEmpty {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            urlString += "&q=\(encoded)"
        }

        guard let url = URL(string: urlString) else { throw GmailAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageRefs = json["messages"] as? [[String: Any]] else {
            return [] // No messages
        }

        // Fetch summaries for each message (metadata only)
        var summaries: [GmailMessageSummary] = []
        for ref in messageRefs {
            guard let id = ref["id"] as? String else { continue }
            if let summary = try? await fetchMessageSummary(id: id, token: token) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    private static func fetchMessageSummary(id: String, token: String) async throws -> GmailMessageSummary {
        guard let url = URL(string: "\(baseURL)/messages/\(id)?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date") else {
            throw GmailAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailAPIError.invalidResponse
        }

        let headers = extractHeaders(from: json)
        let labelIds = json["labelIds"] as? [String] ?? []

        return GmailMessageSummary(
            id: id,
            threadId: json["threadId"] as? String ?? "",
            from: headers["From"] ?? "",
            subject: headers["Subject"] ?? "(no subject)",
            snippet: json["snippet"] as? String ?? "",
            date: headers["Date"] ?? "",
            isUnread: labelIds.contains("UNREAD")
        )
    }

    // MARK: - Get Message

    /// Fetches the full content of a single message.
    static func getMessage(id: String) async throws -> GmailMessage {
        let token = try await GmailAuthManager.shared.getAccessToken()

        guard let url = URL(string: "\(baseURL)/messages/\(id)?format=full") else {
            throw GmailAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GmailAPIError.invalidResponse
        }

        let headers = extractHeaders(from: json)
        let labelIds = json["labelIds"] as? [String] ?? []
        let body = extractBody(from: json)

        return GmailMessage(
            id: id,
            threadId: json["threadId"] as? String ?? "",
            from: headers["From"] ?? "",
            to: headers["To"] ?? "",
            subject: headers["Subject"] ?? "(no subject)",
            body: body,
            date: headers["Date"] ?? "",
            isUnread: labelIds.contains("UNREAD")
        )
    }

    // MARK: - Send Message

    /// Sends a new email. Returns the sent message ID.
    static func sendMessage(to: String, subject: String, body: String) async throws -> String {
        let token = try await GmailAuthManager.shared.getAccessToken()
        let email = await GmailAuthManager.shared.connectedEmail ?? "me"

        let rfc2822 = buildRFC2822(from: email, to: to, subject: subject, body: body)
        return try await postMessage(raw: rfc2822, token: token)
    }

    // MARK: - Reply to Message

    /// Replies to an existing message. Returns the sent message ID.
    static func replyToMessage(messageId: String, body: String) async throws -> String {
        let token = try await GmailAuthManager.shared.getAccessToken()
        let email = await GmailAuthManager.shared.connectedEmail ?? "me"

        // Fetch original message to get reply headers
        let original = try await getMessage(id: messageId)

        let subject = original.subject.hasPrefix("Re: ") ? original.subject : "Re: \(original.subject)"
        let replyTo = original.from

        let rfc2822 = buildRFC2822(
            from: email, to: replyTo, subject: subject, body: body,
            inReplyTo: messageId, threadId: original.threadId
        )

        return try await postMessage(raw: rfc2822, token: token, threadId: original.threadId)
    }

    // MARK: - Helpers

    private static func postMessage(raw: String, token: String, threadId: String? = nil) async throws -> String {
        guard let url = URL(string: "\(baseURL)/messages/send") else {
            throw GmailAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let base64Raw = Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var payload: [String: Any] = ["raw": base64Raw]
        if let threadId {
            payload["threadId"] = threadId
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTPResponse(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sentId = json["id"] as? String else {
            throw GmailAPIError.invalidResponse
        }

        return sentId
    }

    private static func buildRFC2822(from: String, to: String, subject: String, body: String,
                                     inReplyTo: String? = nil, threadId: String? = nil) -> String {
        var message = "From: \(from)\r\n"
        message += "To: \(to)\r\n"
        message += "Subject: \(subject)\r\n"
        message += "MIME-Version: 1.0\r\n"
        message += "Content-Type: text/plain; charset=utf-8\r\n"
        if let inReplyTo {
            message += "In-Reply-To: \(inReplyTo)\r\n"
            message += "References: \(inReplyTo)\r\n"
        }
        message += "\r\n"
        message += body
        return message
    }

    private static func extractHeaders(from json: [String: Any]) -> [String: String] {
        var result: [String: String] = [:]
        guard let payload = json["payload"] as? [String: Any],
              let headers = payload["headers"] as? [[String: Any]] else {
            return result
        }
        for header in headers {
            if let name = header["name"] as? String, let value = header["value"] as? String {
                result[name] = value
            }
        }
        return result
    }

    private static func extractBody(from json: [String: Any]) -> String {
        guard let payload = json["payload"] as? [String: Any] else { return "" }

        // Try direct body first (simple messages)
        if let body = payload["body"] as? [String: Any],
           let data = body["data"] as? String,
           let decoded = decodeBase64URL(data) {
            return stripHTML(decoded)
        }

        // Try multipart — look for text/plain first, then text/html
        if let parts = payload["parts"] as? [[String: Any]] {
            // First pass: look for text/plain
            for part in parts {
                if let mimeType = part["mimeType"] as? String, mimeType == "text/plain",
                   let body = part["body"] as? [String: Any],
                   let data = body["data"] as? String,
                   let decoded = decodeBase64URL(data) {
                    return decoded
                }
            }

            // Second pass: look for text/html and strip tags
            for part in parts {
                if let mimeType = part["mimeType"] as? String, mimeType == "text/html",
                   let body = part["body"] as? [String: Any],
                   let data = body["data"] as? String,
                   let decoded = decodeBase64URL(data) {
                    return stripHTML(decoded)
                }
            }

            // Recursive: check nested multipart
            for part in parts {
                if let nestedParts = part["parts"] as? [[String: Any]] {
                    let nestedPayload: [String: Any] = ["payload": ["parts": nestedParts]]
                    let body = extractBody(from: nestedPayload)
                    if !body.isEmpty { return body }
                }
            }
        }

        // Fallback to snippet
        return json["snippet"] as? String ?? ""
    }

    private static func decodeBase64URL(_ string: String) -> String? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad to multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func stripHTML(_ html: String) -> String {
        // Remove HTML tags
        var text = html.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<p[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "</p>", with: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // Decode common HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse multiple newlines
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func checkHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailAPIError.httpError(statusCode: httpResponse.statusCode, body: String(body.prefix(500)))
        }
    }
}

// MARK: - Errors

enum GmailAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Gmail API URL"
        case .invalidResponse: return "Invalid response from Gmail API"
        case .httpError(let code, let body): return "Gmail API error (\(code)): \(body)"
        }
    }
}
