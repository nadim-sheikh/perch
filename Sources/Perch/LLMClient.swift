import Foundation

struct ChatTurn {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
}

enum LLMError: LocalizedError {
    case missingKey
    case http(Int, String)
    case stream(String)
    /// The reply hit the output limit, so it is cut off.
    case truncated
    /// The connection ended before the model said it was done.
    case incomplete

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your \(AIProvider.current.title) key in Settings → AI Models."
        case .http(let code, let body): return "API error \(code): \(body.prefix(300))"
        case .stream(let message): return "API error: \(message.prefix(300))"
        case .truncated: return "The reply was too long and got cut off."
        case .incomplete: return "The connection dropped before the reply finished."
        }
    }
}

/// Streams a plain text reply (no tools) from Perch's model on the current provider. Screenshots are attached
/// only to the newest user turn; earlier turns are sent as plain text history.
/// The stream only finishes normally when the reply is complete: an error object, a cut-off
/// reply or a dropped connection all throw, so callers never act on partial text.
struct LLMClient {
    var apiKey = AppSettings.shared.activeKey
    var model = PerchModel.id
    var maxTokens = 4096
    /// Skip the model's hidden "thinking" pass. It was adding ~5s before the first word.
    var thinking = false

    func stream(
        system: String,
        history: [ChatTurn],
        prompt: String,
        screens: [CapturedScreen]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingKey }
                    let request = try makeRequest(system: system, history: history, prompt: prompt, screens: screens)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.http(status, body)
                    }
                    var complete = false
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { complete = true; break }
                        let event = try parseEvent(payload)
                        if let text = event.text { continuation.yield(text) }
                        if event.finished { complete = true }
                    }
                    guard complete else { throw LLMError.incomplete }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(system: String, history: [ChatTurn], prompt: String, screens: [CapturedScreen]) throws -> URLRequest {
        var content: [[String: Any]] = screens.flatMap { s -> [[String: Any]] in
            [
                ["type": "text", "text": screenCaption(s)],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(s.jpegBase64)"]],
            ]
        }
        content.append(["type": "text", "text": prompt])
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        messages += history.map { ["role": $0.role.rawValue, "content": $0.text] }
        messages.append(["role": "user", "content": content])
        return try AIProvider.current.chatRequest(key: apiKey, model: model, messages: messages,
                                                  maxTokens: maxTokens, quick: !thinking)
    }

    private func screenCaption(_ s: CapturedScreen) -> String {
        let where_ = s.containsCursor ? " (the user's cursor is on this screen)" : ""
        return "screen\(s.index): \(Int(s.imageSize.width))x\(Int(s.imageSize.height)) pixels\(where_)"
    }

    /// One SSE payload: its text, and whether the model finished cleanly. Throws on an error
    /// object, or on a finish reason that means the reply is broken or cut off.
    private func parseEvent(_ json: String) throws -> (text: String?, finished: Bool) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, false) }
        if let err = obj["error"] as? [String: Any] {
            throw LLMError.stream(err["message"] as? String ?? "\(err)")
        }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return (nil, false) }
        let text = (choice["delta"] as? [String: Any])?["content"] as? String
        switch choice["finish_reason"] as? String {
        case nil: return (text, false)
        case "length": throw LLMError.truncated
        case "error": throw LLMError.stream("The model stopped with an error.")
        default: return (text, true)
        }
    }
}
