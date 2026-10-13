import AppKit

/// The brain: hotkey down → listen, hotkey up → look at the screen, ask the
/// model, show and speak the answer, and point at things it mentions.
@MainActor
final class Companion {
    static let shared = Companion()

    private let state = BuddyState.shared
    private let store = ConversationStore.shared
    private let speech = SpeechRecognizer()
    private let speaker = Speaker()
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
            // Talking while a helper's chat is open sends the words straight to that helper.
            if NSApp.isActive, let slug = HomeRouter.shared.selectedAgent, HomeRouter.shared.settings == nil {
                state.phase = .idle
                state.bubbleText = ""
                AgentManager.shared.launch(slug: slug, prompt: transcript)
                return
            }
            await ask(transcript)
        }
    }

    // MARK: Asking

    func askTyped(_ text: String, inNotch: Bool = false) {
        interrupt()
        currentTask = Task { await ask(text, inNotch: inNotch) }
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
        store.newConversation()
    }

    /// Show and speak a line without asking the model (e.g. "Shippy: your site is ready").
    func announce(_ text: String) {
        guard state.phase == .idle else { return }
        state.bubbleText = text
        currentTask = Task {
            await speaker.speak(text)
            scheduleBubbleHide(after: 4)
        }
    }

    private func ask(_ question: String, inNotch: Bool = false) async {
        let settings = AppSettings.shared
        let notch = NotchModel.shared
        if inNotch { notch.showResponse(question: question) }
        state.phase = .thinking
        state.bubbleText = ""
        let conversationID = store.activeConversationID()
        let history = store.history(for: conversationID)
        store.append(Message(role: .user, text: question), to: conversationID)
        store.streamingText = ""
        defer { store.streamingText = nil }

        var screens: [CapturedScreen] = []
        if ScreenCapture.hasPermission() {
            screens = (try? await ScreenCapture.captureAll()) ?? []
        }

        let client = LLMClient(provider: settings.provider, apiKey: settings.activeKey, model: settings.activeModel)
        var full = ""
        do {
            let stream = client.stream(
                system: Prompts.system(name: settings.buddyName, screenCount: screens.count) + Handoff.rosterNote(),
                history: history,
                prompt: question,
                screens: screens
            )
            for try await chunk in stream {
                if Task.isCancelled { return }
                full += chunk
                state.phase = .responding
                let visible = Handoff.strip(Pointing.stripTags(full))
                if inNotch {
                    if notch.responseText.isEmpty { NSSound(named: "Tink")?.play() }
                    notch.responseText = visible
                } else {
                    state.bubbleText = visible
                }
                store.streamingText = visible
            }
        } catch {
            if !Task.isCancelled {
                if inNotch { notch.responseText = "⚠️ " + error.localizedDescription; notch.responseFinished = true }
                show(error: error.localizedDescription)
                store.append(Message(role: .error, text: error.localizedDescription), to: conversationID)
            }
            return
        }

        let spoken = Handoff.strip(Pointing.stripTags(full))
        store.append(Message(role: .assistant, text: spoken), to: conversationID)

        if let handoff = Handoff.parse(full) {
            let cursorScreen = screens.first { $0.containsCursor } ?? screens.first
            Handoff.perform(handoff, screenshot: cursorScreen)
        }

        if let target = Pointing.firstTarget(in: full), let screen = screens.first(where: { $0.index == target.screen }) {
            state.point(at: screen.globalPoint(fromImagePoint: target.point), label: target.label)
        }

        if inNotch {
            notch.responseFinished = true
            state.phase = .idle
            return
        }
        await speaker.speak(spoken)
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

/// Lets the buddy pass bigger jobs to a background helper by ending its reply
/// with [AGENT:slug:task] or [NEW_AGENT:Name|Role:task].
@MainActor
enum Handoff {
    enum Kind {
        case existing(slug: String, task: String)
        case new(name: String, role: String, task: String)
    }

    static func rosterNote() -> String {
        let manager = AgentManager.shared
        let agents = AgentRoster.shared.agents.filter { !$0.archived }
        let lines = agents.map { a -> String in
            let status = manager.running.contains(a.id) ? "working now" : "idle"
            let last = manager.lastTurn(a.id)?.summary.map { " - last result: \($0)" } ?? ""
            return "- \(a.name) (slug: \(a.id)) - \(a.role): \(a.oneLiner) [\(status)]\(last)"
        }.joined(separator: "\n")
        return """


        Helpers: you have background helpers who can do real multi-step work on this Mac (build websites and apps, \
        research the web and write reports, make documents, use the user's connected apps, work with files). \
        Hand a job to a helper when it needs more than a quick spoken answer. Keep your spoken reply to one short \
        sentence like "Shippy's on it", then end your reply with exactly one tag:
        [AGENT:slug:a complete, self-contained description of the task]
        or, if no helper fits, create one:
        [NEW_AGENT:Name|Role:the task]
        Include in the task anything from the screen or conversation the helper will need. Questions about what a \
        helper did can be answered from the list below. Never mention the tags.
        Current helpers:
        \(lines.isEmpty ? "(none yet)" : lines)
        """
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"\[(AGENT|NEW_AGENT):([^:\]]+):([^\]]+)\]"#, options: [.dotMatchesLineSeparators])

    static func parse(_ text: String) -> Kind? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let kindR = Range(m.range(at: 1), in: text), let aR = Range(m.range(at: 2), in: text),
              let taskR = Range(m.range(at: 3), in: text) else { return nil }
        let a = text[aR].trimmingCharacters(in: .whitespaces)
        let task = text[taskR].trimmingCharacters(in: .whitespacesAndNewlines)
        if text[kindR] == "AGENT" { return .existing(slug: a.lowercased(), task: task) }
        let parts = a.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return .new(name: parts.first ?? "Helper", role: parts.count > 1 ? parts[1] : "Helper", task: task)
    }

    static func strip(_ text: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func perform(_ kind: Kind, screenshot: CapturedScreen?) {
        let roster = AgentRoster.shared
        switch kind {
        case .existing(let slug, let task):
            let agent = roster.agent(slug) ?? roster.agents.first { $0.name.lowercased() == slug }
            guard let agent else {
                perform(.new(name: slug.capitalized, role: "Helper", task: task), screenshot: screenshot)
                return
            }
            AgentManager.shared.launch(slug: agent.id, prompt: task, screenshot: screenshot)
        case .new(let name, let role, let task):
            guard let agent = try? roster.create(name: name, role: role, oneLiner: "Helps with: \(role.lowercased()).") else { return }
            AgentManager.shared.registerNewAgent(agent)
            AgentManager.shared.launch(slug: agent.id, prompt: task, screenshot: screenshot)
        }
    }
}
