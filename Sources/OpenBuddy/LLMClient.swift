import Foundation

struct ChatTurn {
    enum Role: String { case user, assistant }
    let role: Role
    let text: String
}

enum LLMError: LocalizedError {
    case missingKey(LLMProvider)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "Add your \(p.displayName) API key in Settings."
        case .http(let code, let body): return "API error \(code): \(body.prefix(300))"
        }
    }
}

/// Streams a reply from Anthropic or OpenAI. Screenshots are attached only to
/// the newest user turn; earlier turns are sent as plain text history.
struct LLMClient {
    let provider: LLMProvider
    let apiKey: String
    let model: String

    func stream(
        system: String,
        history: [ChatTurn],
        prompt: String,
        screens: [CapturedScreen]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw LLMError.missingKey(provider) }
                    let request = try makeRequest(system: system, history: history, prompt: prompt, screens: screens)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.http(status, body)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let delta = parseDelta(payload) { continuation.yield(delta) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(system: String, history: [ChatTurn], prompt: String, screens: [CapturedScreen]) throws -> URLRequest {
        var req: URLRequest
        var body: [String: Any]

        switch provider {
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var content: [[String: Any]] = screens.flatMap { s -> [[String: Any]] in
                [
                    ["type": "text", "text": screenCaption(s)],
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": s.jpegBase64]],
                ]
            }
            content.append(["type": "text", "text": prompt])
            var messages: [[String: Any]] = history.map { ["role": $0.role.rawValue, "content": $0.text] }
            messages.append(["role": "user", "content": content])
            body = ["model": model, "max_tokens": 1024, "system": system, "stream": true, "messages": messages]

        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            var content: [[String: Any]] = screens.flatMap { s -> [[String: Any]] in
                [
                    ["type": "text", "text": screenCaption(s)],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(s.jpegBase64)", "detail": "high"]],
                ]
            }
            content.append(["type": "text", "text": prompt])
            var messages: [[String: Any]] = [["role": "system", "content": system]]
            messages += history.map { ["role": $0.role.rawValue, "content": $0.text] }
            messages.append(["role": "user", "content": content])
            body = ["model": model, "stream": true, "messages": messages]
        }

        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120
        return req
    }

    private func screenCaption(_ s: CapturedScreen) -> String {
        let where_ = s.containsCursor ? " (the user's cursor is on this screen)" : ""
        return "screen\(s.index): \(Int(s.imageSize.width))x\(Int(s.imageSize.height)) pixels\(where_)"
    }

    private func parseDelta(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch provider {
        case .anthropic:
            guard obj["type"] as? String == "content_block_delta",
                  let delta = obj["delta"] as? [String: Any] else { return nil }
            return delta["text"] as? String
        case .openai:
            guard let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { return nil }
            return delta["content"] as? String
        }
    }
}
