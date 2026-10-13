import AppKit

/// The brain: hotkey down → listen, hotkey up → look at the screen, ask the
/// model, show and speak the answer, and point at things it mentions.
@MainActor
final class Companion {
    private let state = BuddyState.shared
    private let speech = SpeechRecognizer()
    private let speaker = Speaker()
    private var history: [ChatTurn] = []
    private var currentTask: Task<Void, Never>?
    private var hideBubbleWork: DispatchWorkItem?

    init() {
        speech.onLevel = { [weak self] level in self?.state.audioLevel = level }
        speech.onPartial = { [weak self] text in
            guard let self, self.state.phase == .listening else { return }
            self.state.bubbleText = text
        }
    }

    // MARK: Voice

    func beginListening() {
        interrupt()
        do {
            try speech.start()
            state.phase = .listening
            state.bubbleText = ""
        } catch {
            show(error: "Microphone unavailable: \(error.localizedDescription)")
        }
    }

    func endListening() {
        guard state.phase == .listening else { return }
        currentTask = Task {
            let transcript = await speech.stop()
            guard !transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
                state.phase = .idle
                state.bubbleText = ""
                return
            }
            await ask(transcript)
        }
    }

    // MARK: Asking

    func askTyped(_ text: String) {
        interrupt()
        currentTask = Task { await ask(text) }
    }

    func interrupt() {
        currentTask?.cancel()
        currentTask = nil
        speech.cancel()
        speaker.stop()
        hideBubbleWork?.cancel()
        state.phase = .idle
    }

    func resetConversation() {
        history.removeAll()
    }

    private func ask(_ question: String) async {
        let settings = AppSettings.shared
        state.phase = .thinking
        state.bubbleText = ""

        var screens: [CapturedScreen] = []
        if ScreenCapture.hasPermission() {
            screens = (try? await ScreenCapture.captureAll()) ?? []
        }

        let client = LLMClient(provider: settings.provider, apiKey: settings.activeKey, model: settings.activeModel)
        var full = ""
        do {
            let stream = client.stream(
                system: Prompts.system(name: settings.buddyName, screenCount: screens.count),
                history: history,
                prompt: question,
                screens: screens
            )
            for try await chunk in stream {
                if Task.isCancelled { return }
                full += chunk
                state.phase = .responding
                state.bubbleText = Pointing.stripTags(full)
            }
        } catch {
            if !Task.isCancelled { show(error: error.localizedDescription) }
            return
        }

        history.append(ChatTurn(role: .user, text: question))
        history.append(ChatTurn(role: .assistant, text: full))
        if history.count > 20 { history.removeFirst(history.count - 20) }

        if let target = Pointing.firstTarget(in: full), let screen = screens.first(where: { $0.index == target.screen }) {
            state.point(at: screen.globalPoint(fromImagePoint: target.point), label: target.label)
        }

        await speaker.speak(Pointing.stripTags(full))
        if Task.isCancelled { return }
        state.phase = .idle
        scheduleBubbleHide(after: 6)
    }

    private func show(error message: String) {
        state.phase = .error(message)
        state.bubbleText = "⚠️ " + message
        scheduleBubbleHide(after: 8)
    }

    private func scheduleBubbleHide(after seconds: TimeInterval) {
        hideBubbleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.state.phase == .idle || { if case .error = self.state.phase { return true } else { return false } }() {
                self.state.bubbleText = ""
                self.state.phase = .idle
            }
        }
        hideBubbleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

enum Prompts {
    static func system(name: String, screenCount: Int) -> String {
        """
        You are \(name), a friendly AI buddy that lives next to the user's mouse cursor on their Mac. \
        You can see their screen\(screenCount > 1 ? "s" : "") in the attached screenshots and they usually talk to you by voice. \
        Your reply is shown in a small speech bubble and read aloud, so:
        - Keep it short and conversational: one to three sentences unless they ask for detail.
        - No markdown, bullet lists, headings or code fences. Plain spoken English.
        - Be concrete about what is on their screen. If you can't see something, say so.

        Pointing: when it helps to show the user where something is (a button, menu, field, icon), \
        add exactly one tag at the very end of your reply in this format:
        [POINT:x,y:screenN:short label]
        where x,y are pixel coordinates of the element's centre in that screenshot (origin at the top-left), \
        N is the screen number, and the label is 1-3 words. Only point at things you can actually see. \
        Never mention the tag or coordinates in your sentences.
        """
    }
}

enum Pointing {
    struct Target {
        let point: CGPoint
        let screen: Int
        let label: String?
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"\[POINT:\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*(?::\s*screen\s*(\d+))?\s*(?::\s*([^\]]*))?\]"#,
        options: [.caseInsensitive]
    )

    static func firstTarget(in text: String) -> Target? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range),
              let x = Double(text[Range(m.range(at: 1), in: text)!]),
              let y = Double(text[Range(m.range(at: 2), in: text)!]) else { return nil }
        let screen = Range(m.range(at: 3), in: text).flatMap { Int(text[$0]) } ?? 1
        let label = Range(m.range(at: 4), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        return Target(point: CGPoint(x: x, y: y), screen: screen, label: label?.isEmpty == true ? nil : label)
    }

    /// Removes complete tags, and hides a partially streamed tag at the end.
    static func stripTags(_ text: String) -> String {
        var out = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        if let open = out.range(of: "[", options: .backwards), !out[open.lowerBound...].contains("]") {
            out = String(out[..<open.lowerBound])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
